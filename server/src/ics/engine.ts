// ICS feed -> DayDo task reconciliation (spec/mcp.md 9.3). Semantics follow REF engine.ts; writes go
// through the server writer. Task ids are reserved in the mapping before anything reaches the scope,
// so a lost response or a restart retries the same id. A mapping's fingerprint is committed only after
// the push response row shows every intended field applied; a removed event's mapping is deleted only
// after its task is confirmed in the trash.
import type { GetNow } from '../clock';
import { scheduleToAPI } from '../domain/schedule';
import { before } from '../domain/sortKey';
import { uuidv7 } from '../domain/uuid';
import { loadSnapshot } from '../serverops/snapshot';
import {
  createTaskIntent,
  firstTaskSortKey,
  patchTaskIntent,
  taskListDenial,
  trashTaskIntent,
} from '../serverops/taskWrites';
import { isNil, rowSchedule, sameValue, scheduleColumns } from '../serverops/values';
import { assertHasData, pushIntents, type WriteIntent, type WriteOutcome } from '../serverops/writer';
import type { ServerHlcClock } from '../sync/hlc';
import type { AppDb } from '../appDb';
import { REJECT_REASON } from '../sync/rejectReason';
import type { ScopeStub } from '../scope/api';
import { fetchIcs, type FetchIcsOptions } from './fetch';
import { applyFilter } from './filters';
import { eventToTaskDraft, parseIcs, seriesSignatures } from './parser';
import {
  IcsLeaseLostError,
  LEASE_TTL_MS,
  type IcsMapping,
  type IcsSource,
  type IcsStore,
  type MappingCommit,
  type MappingPurge,
} from './store';
import { FALLBACK_TIMEZONE, IcsError, type ParsedEvent, type SyncChange, type SyncStats, type TaskDraft } from './types';

export const ICS_MAX_WINDOW_DAYS = 3650;
/** Sources synced per cron run (spec/mcp.md 9.5): bounds subrequests and run time. */
export const ICS_SOURCES_PER_RUN = 5;
const DAY_MS = 86_400_000;
const CANCELLED_PREFIX = '[已取消] ';
/** Abort a run that would remove most of the imported set (e.g. an empty or truncated-but-valid feed). */
const MASS_DELETE_RATIO = 0.5;
const MASS_DELETE_MIN = 5;
const PROJECT_PURGED = REJECT_REASON.PROJECT_PURGED;
const SINGLE_TO_SERIES = 'A single event became a recurring series; review before writing (original task preserved)';
const SERIES_REDEFINED = 'Recurring series definition changed; review correspondence before writing';

export interface IcsEngineDeps {
  store: IcsStore;
  /** `AppDeps.db` (first-primary D1 session). */
  db: AppDb;
  getScopeStub: (scope: string) => ScopeStub;
  /** Defaults to the isolate-wide clock shared with /sync/push. */
  clock?: ServerHlcClock;
  fetchOptions?: FetchIcsOptions;
  /** `DEFAULT_TIMEZONE`, used when a source has no timezone. Defaults to Asia/Taipei. */
  defaultTimeZone?: string;
  /** Only the cron entry reads it, to compute a run's `now`. The engine's leases and timings always read the wall clock. */
  getNow?: GetNow;
}

export interface SyncOptions {
  dryRun?: boolean;
  includeChanges?: boolean;
  /** Lets a manual run pass the mass-delete guard. Cron never sets it. */
  allowMassDelete?: boolean;
}

const zeroStats = (): SyncStats => ({ created: 0, updated: 0, skipped: 0, deleted: 0, errors: 0 });
const errMsg = (error: unknown) => (error instanceof Error ? error.message : String(error));
const identity = (uid: string, occurrenceId = '') => JSON.stringify([uid, occurrenceId]);

/** Hash only source-owned semantic values, never DTSTAMP or SEQUENCE (REF eventFingerprint). */
export async function eventFingerprint(event: ParsedEvent): Promise<string> {
  const normalize = (date?: string) => (!date || event.allDay ? (date ?? null) : Date.parse(date));
  const bytes = new TextEncoder().encode(
    JSON.stringify([
      event.summary,
      event.description ?? '',
      event.location ?? '',
      normalize(event.start),
      normalize(event.end),
      event.allDay,
      !!event.cancelled,
    ]),
  );
  return [...new Uint8Array(await crypto.subtle.digest('SHA-256', bytes))]
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('');
}

/** Series signature with the end (UNTIL/COUNT) stripped from each RRULE (REF seriesCore). */
function seriesCore(signature: string): string {
  return JSON.stringify(
    (JSON.parse(signature) as string[])
      .map((line) =>
        line.startsWith('RRULE:')
          ? `RRULE:${line
              .slice(6)
              .split(';')
              .filter((part) => !/^(UNTIL|COUNT)=/i.test(part))
              .join(';')}`
          : line,
      )
      .sort(),
  );
}

/**
 * UTC instant of a slot's original start, from its occurrenceId (`UTC:`, `DATE:` or `FLOAT:`).
 * Date and floating slots are read as UTC; callers allow a day of slack. NaN when unrecognised.
 */
function slotInstant(occurrenceId: string): number {
  const [kind, value] = [occurrenceId.slice(0, occurrenceId.indexOf(':')), occurrenceId.slice(occurrenceId.indexOf(':') + 1)];
  if (kind === 'UTC') return Date.parse(value);
  if (kind === 'DATE') return Date.parse(`${value}T00:00:00Z`);
  if (kind === 'FLOAT') return Date.parse(`${value}Z`);
  return NaN;
}

/** The feed carries an earlier revision than the one already recorded. */
function older(event: ParsedEvent, mapping: IcsMapping): boolean {
  const seq = event.sequence ?? 0;
  if (seq !== mapping.sequence) return seq < mapping.sequence;
  return !!event.dtstamp && !!mapping.dtstamp && Date.parse(event.dtstamp) < Date.parse(mapping.dtstamp);
}

/**
 * `n` distinct keys, ascending, all before `first` (the list's smallest key). A shared prefix keeps
 * them short; chaining before() would add a character every few keys.
 */
function sortKeysBefore(first: string | null, n: number): string[] {
  const prefix = before(first);
  const width = Math.max(1, Math.ceil(Math.log(n + 1) / Math.log(36)));
  // A fixed-width counter plus a non-zero last digit: ascending, and valid generated keys.
  return Array.from({ length: n }, (_, i) => `${prefix}${i.toString(36).padStart(width, '0')}i`);
}

/**
 * The ICS-owned fields that differ from the row, plus a reopen when the source changed and the row
 * does not show it yet. A row already matching the draft means the write landed earlier (lost
 * response), so a completion there came after it and stays.
 */
function ownedDelta(row: Record<string, unknown>, draft: TaskDraft, reopen: boolean): Record<string, unknown> {
  const delta: Record<string, unknown> = {};
  if (!sameValue(row.title, draft.title)) delta.title = draft.title;
  if (!sameValue(row.content, draft.content)) delta.content = draft.content;
  const schedule = scheduleColumns(draft.schedule);
  // The schedule is one LWW group: send all five when any differs.
  if (Object.entries(schedule).some(([k, v]) => !sameValue(row[k], v))) Object.assign(delta, schedule);
  if (reopen && row.status === 2 && Object.keys(delta).length > 0) {
    delta.status = 0;
    delta.completedAt = null;
  }
  return delta;
}

/**
 * A cancelled event: prefix the task's current title (the user's edit included), complete it and
 * clear reminders. Computed against the row, so a write that already landed yields an empty delta.
 * A completion the user made earlier keeps its completedAt. Content and schedule stay as they are.
 */
function cancelDelta(row: Record<string, unknown>, now: number): Record<string, unknown> {
  const delta: Record<string, unknown> = {};
  const title = typeof row.title === 'string' ? row.title : '';
  if (!title.startsWith(CANCELLED_PREFIX)) delta.title = `${CANCELLED_PREFIX}${title}`;
  if (row.status !== 2) {
    delta.status = 2;
    delta.completedAt = now;
  }
  if (Array.isArray(row.reminders) && row.reminders.length > 0) delta.reminders = [];
  return delta;
}

function createIntent(id: string, projectId: string, draft: TaskDraft, source: IcsSource, sortKey: string): WriteIntent {
  const { title, content, priority, reminders } = draft;
  return createTaskIntent(
    id,
    { projectId, title, content, priority, reminders, tags: [], sortKey },
    { importNote: `ICS：${source.name}`, ...scheduleColumns(draft.schedule) },
  );
}

function describeOutcome(o: WriteOutcome): string {
  if (o.status === 'unapplied') {
    return `Task fields not applied because a newer device edit won: ${(o.unappliedFields ?? []).join(', ')}; will retry`;
  }
  if (o.status === 'purged') return 'Task was permanently deleted';
  return `Task write rejected: ${o.reason ?? 'unknown reason'}`;
}

/** One event that needs a scope write (create, update or cancel) or a write-free commit. */
interface Planned {
  event: ParsedEvent;
  fingerprint: string;
  mapping: IcsMapping | null;
  /** Absent for cancelled events: a cancel writes no draft fields. */
  draft?: TaskDraft;
  /** Snapshot row as read when the task exists (any state, trash included); the writer later swaps in the response row. */
  row: Record<string, unknown> | undefined;
  /** Fields to write on an existing row; empty means the row already matches. */
  delta: Record<string, unknown>;
}

const isPurgedOutcome = (o: WriteOutcome) =>
  o.status === 'purged' || (o.status === 'rejected' && o.reason === PROJECT_PURGED);

/** A mapping whose event left the source. Its task is trashed (when needed) before the mapping goes. */
interface Removal {
  mapping: IcsMapping;
  row: Record<string, unknown> | undefined;
  /** False when the task is not visible, already in the trash, or a tombstone: only the mapping goes. */
  write: boolean;
}

export async function syncSource(
  deps: IcsEngineDeps,
  userId: string,
  sourceId: number,
  nowMs: number,
  options: SyncOptions = {},
): Promise<SyncStats> {
  const { store } = deps;
  const dryRun = options.dryRun === true;
  const source = await store.getSource(userId, sourceId);
  if (!source || (!source.enabled && !dryRun)) return zeroStats();
  const stats = zeroStats();
  if (dryRun) stats.dryRun = true;
  if (dryRun || options.includeChanges) stats.changes = [];

  // The store checks leases against its own clock, so lease calls use wall time, not nowMs.
  const token = crypto.randomUUID();
  if (!dryRun && !(await store.acquireLease(userId, sourceId, token, Date.now(), LEASE_TTL_MS))) {
    return { ...stats, busy: true };
  }
  let renewAfter = Date.now() + LEASE_TTL_MS / 2;
  /** Renews the lease when half spent, and always right before a scope write. */
  const guard = async (scopeWrite = false) => {
    if (dryRun || (!scopeWrite && Date.now() < renewAfter)) return;
    if (!(await store.renewLease(userId, sourceId, token, Date.now(), LEASE_TTL_MS))) throw new IcsLeaseLostError();
    renewAfter = Date.now() + LEASE_TTL_MS / 2;
  };
  /** start/end (and previous*) are rendered like the task API, in the task's zone. */
  const record = (
    item: { event: ParsedEvent; draft?: TaskDraft },
    action: SyncChange['action'],
    taskId?: string,
    prev?: Record<string, unknown>,
    reason?: string,
  ) => {
    if (!stats.changes) return;
    // A bare cancelled master (no DTSTART, hence no end) carries no real times.
    const next = item.draft
      ? scheduleToAPI(item.draft.schedule)
      : item.event.end === undefined
        ? { start: null, due: null }
        : { start: item.event.start, due: item.event.end };
    const previous = prev ? rowSchedule(prev) : null;
    const api = previous ? scheduleToAPI(previous) : null;
    const summary = item.event.summary || (typeof prev?.title === 'string' ? prev.title : undefined);
    stats.changes.push({
      uid: item.event.uid,
      occurrenceId: item.event.occurrenceId ?? '',
      taskId,
      action,
      summary,
      start: next.start ?? undefined,
      end: next.due ?? undefined,
      ...(api ? { previousStart: api.start ?? undefined, previousEnd: api.due ?? undefined } : {}),
      ...(reason ? { reason } : {}),
    });
  };
  const recordMapping = (m: IcsMapping, action: SyncChange['action'], row?: Record<string, unknown>, reason?: string) => {
    if (!stats.changes) return;
    const previous = row ? rowSchedule(row) : null;
    const api = previous ? scheduleToAPI(previous) : null;
    stats.changes.push({
      uid: m.icsUid,
      occurrenceId: m.occurrenceId,
      taskId: m.taskId,
      action,
      ...(typeof row?.title === 'string' ? { summary: row.title } : {}),
      ...(api ? { previousStart: api.start ?? undefined, previousEnd: api.due ?? undefined } : {}),
      ...(reason ? { reason } : {}),
    });
  };
  /** Mapping commits for this run (confirmed writes, revision bumps, error notes), one batch at the end. */
  const commits: MappingCommit[] = [];
  /** Mappings turning terminal; kept apart from commits (commitMappings refuses purged rows). */
  const purges: MappingPurge[] = [];
  const fail = (
    item: { event: ParsedEvent; draft?: TaskDraft },
    mapping: IcsMapping | null,
    reason: string,
    prev?: Record<string, unknown>,
  ) => {
    stats.errors++;
    stats.lastError = reason;
    record(item, 'error', mapping?.taskId, prev, reason);
    // Keep the fingerprint and state: the next run retries. Only the error note is stored.
    if (mapping && !dryRun && mapping.state !== 'purged') commits.push({ ...mapping, state: mapping.state, lastError: reason });
  };
  /** Terminal: the task is a tombstone or its list was purged. Nothing is written to it again. */
  const purge = (
    item: { event: ParsedEvent; draft?: TaskDraft },
    mapping: IcsMapping,
    reason: string,
    prev?: Record<string, unknown>,
  ) => {
    stats.skipped++;
    record(item, 'skip', mapping.taskId, prev, reason);
    if (!dryRun) purges.push({ icsUid: mapping.icsUid, occurrenceId: mapping.occurrenceId, taskId: mapping.taskId, lastError: reason });
  };

  try {
    const snapshot = await loadSnapshot(deps.db, userId, deps.getScopeStub);
    assertHasData(snapshot);
    // An archived list keeps syncing; a missing or read-only one does not.
    if (taskListDenial(snapshot, source.projectId, { allowArchived: true }) !== null) {
      throw new IcsError('The source list is missing or not writable for this account; nothing was written');
    }

    const futureDays = source.filter?.futureDays ?? 90;
    const pastDays = source.filter?.pastDays ?? 7;
    if (
      !Number.isFinite(futureDays) ||
      !Number.isFinite(pastDays) ||
      futureDays <= 0 ||
      futureDays > ICS_MAX_WINDOW_DAYS ||
      pastDays < 0 ||
      pastDays > ICS_MAX_WINDOW_DAYS
    ) {
      throw new IcsError('Invalid ICS sync date window');
    }
    const zone = source.timezone ?? deps.defaultTimeZone ?? FALLBACK_TIMEZONE;
    const mappings = await store.listMappings(userId, sourceId);
    const existing = new Map(mappings.map((m) => [identity(m.icsUid, m.occurrenceId), m]));
    const byUid = new Map<string, IcsMapping[]>();
    for (const m of mappings) byUid.set(m.icsUid, [...(byUid.get(m.icsUid) ?? []), m]);
    const text = await fetchIcs(source.url, deps.fetchOptions);
    const expandTo = nowMs + futureDays * DAY_MS;
    const parsed = parseIcs(
      text,
      { from: nowMs - pastDays * DAY_MS, to: expandTo, includeIdentities: new Set(existing.keys()) },
      zone,
    );
    const sourceIdentities = new Set(parsed.map((e) => identity(e.uid, e.occurrenceId)));
    // Read from each master, not from the slots parsed in the window.
    const series = seriesSignatures(text, zone);

    // Refuse, per UID, a single event turned recurring and a redefined rule (anything but the series
    // end): their slots cannot be matched safely. Nothing of a refused UID is written or removed;
    // the other events of the source still sync.
    const refused = new Map<string, string>();
    for (const [uid, signature] of series) {
      if (existing.has(identity(uid))) refused.set(uid, SINGLE_TO_SERIES);
      else if ((byUid.get(uid) ?? []).some((m) => m.seriesSignature && seriesCore(m.seriesSignature) !== seriesCore(signature))) {
        refused.set(uid, SERIES_REDEFINED);
      }
    }
    // An exception of a single event that is still mapped, with no recurring master in the feed.
    for (const e of parsed) {
      if (e.occurrenceId && !refused.has(e.uid) && existing.has(identity(e.uid))) refused.set(e.uid, SINGLE_TO_SERIES);
    }
    for (const [uid, reason] of refused) {
      stats.errors++;
      stats.lastError = `${reason} (UID ${uid})`;
      stats.changes?.push({ uid, occurrenceId: '', action: 'error', reason });
      for (const m of byUid.get(uid) ?? []) {
        if (!dryRun && m.state !== 'purged') commits.push({ ...m, state: m.state, lastError: reason });
      }
    }

    // The date window limits new imports (parseIcs); identities already imported still update when
    // moved outside it. Keyword exclusions apply to live events only: a cancellation always lands.
    const accepted = parsed.filter((e) => !refused.has(e.uid));
    const events = [
      ...applyFilter(
        accepted.filter((e) => !e.cancelled),
        { ...source.filter, futureDays: undefined, pastDays: undefined },
        nowMs,
      ),
      ...accepted.filter((e) => e.cancelled),
    ];
    // A bare cancelled UID cancels its mapped slots without inventing new tasks.
    const slotCancels = events
      .filter((e) => e.cancelled && !e.occurrenceId)
      .flatMap((e) =>
        (byUid.get(e.uid) ?? []).filter((m) => m.occurrenceId).map((m) => ({ ...e, occurrenceId: m.occurrenceId })),
      );
    const all = [...events, ...slotCancels];

    // A validated full snapshot controls existence as well as event fields. Keyword exclusions are
    // not source deletions. parseIcs visits every slot of a series that starts before expandTo, so a
    // mapped slot missing from there was dropped (an earlier UNTIL or COUNT, a removed RDATE). Slots
    // that may lie later stay; the day of slack covers floating slots read as UTC.
    // An older revision of a UID than the one already imported (a stale cache or mirror) says
    // nothing about which slots exist now, so none of that UID is removed this run. Read before the
    // keyword filter: an excluded slot still reveals the revision.
    const staleUids = new Set(
      [...accepted, ...slotCancels].filter((e) => {
        const m = existing.get(identity(e.uid, e.occurrenceId));
        return !!m && m.state !== 'purged' && older(e, m);
      }).map((e) => e.uid),
    );
    const eventKeys = new Set(all.map((e) => identity(e.uid, e.occurrenceId)));
    for (const [k, m] of existing) {
      if (staleUids.has(m.icsUid) && !refused.has(m.icsUid) && !eventKeys.has(k) && !sourceIdentities.has(k)) {
        stats.skipped++;
        recordMapping(m, 'skip', undefined, 'Older source revision; slot kept');
      }
    }
    const keepSlot = (m: IcsMapping) =>
      refused.has(m.icsUid) ||
      staleUids.has(m.icsUid) ||
      (!!m.occurrenceId && series.has(m.icsUid) && !(slotInstant(m.occurrenceId) < expandTo - DAY_MS));
    const removedMappings = [...existing]
      .filter(([k, m]) => !(eventKeys.has(k) || sourceIdentities.has(k) || keepSlot(m)))
      .map(([, m]) => m);
    if (
      removedMappings.length >= MASS_DELETE_MIN &&
      removedMappings.length > existing.size * MASS_DELETE_RATIO &&
      !options.allowMassDelete
    ) {
      for (const m of removedMappings) recordMapping(m, 'skip', undefined, 'mass-delete guard');
      throw new IcsError(
        `Source removed ${removedMappings.length} of ${existing.size} imported events; sync refused as a safety check (nothing written)`,
      );
    }
    const fingerprints = await Promise.all(all.map(eventFingerprint));

    const seen = new Set<string>();
    const creates: Planned[] = [];
    const updates: Planned[] = [];
    for (const [index, event] of all.entries()) {
      const key = identity(event.uid, event.occurrenceId);
      if (seen.has(key)) continue;
      seen.add(key);
      const fingerprint = fingerprints[index]!;
      const mapping = existing.get(key) ?? null;
      if (event.cancelled && !mapping) {
        stats.skipped++;
        record({ event }, 'skip', undefined, undefined, 'Cancelled before import');
        continue;
      }
      let draft: TaskDraft | undefined;
      if (!event.cancelled) {
        try {
          draft = eventToTaskDraft(event, zone);
        } catch (error) {
          // e.g. an all-day event whose DTEND equals its DTSTART: only this event fails.
          fail({ event }, mapping, errMsg(error));
          continue;
        }
      }
      if (!mapping) {
        creates.push({ event, fingerprint, mapping, draft, row: undefined, delta: {} });
        continue;
      }
      if (mapping.state === 'purged') {
        stats.skipped++;
        record({ event, draft }, 'skip', mapping.taskId, undefined, 'Task permanently deleted');
        continue;
      }
      if (older(event, mapping)) {
        stats.skipped++;
        record({ event, draft }, 'skip', mapping.taskId, undefined, 'Older source revision');
        if (mapping.state === 'pending' || mapping.state === 'updating') {
          stats.errors++;
          stats.lastError = 'Newer pending revision retained; waiting for current source snapshot';
        }
        continue;
      }
      // ICS is authoritative one way: an applied fingerprint needs no read or write. App-side edits
      // (completion included) stay until the source event itself changes.
      if (mapping.fingerprint === fingerprint && (mapping.state === 'applied' || mapping.state === 'cancelled')) {
        stats.skipped++;
        record({ event, draft }, 'skip', mapping.taskId);
        const seriesSignature = event.seriesSignature ?? mapping.seriesSignature;
        // A DTSTAMP-only change carries no revision (Outlook stamps the download time).
        if (!dryRun && ((event.sequence ?? 0) !== mapping.sequence || seriesSignature !== mapping.seriesSignature)) {
          commits.push({
            ...mapping,
            state: mapping.state,
            sequence: event.sequence ?? 0,
            dtstamp: event.dtstamp ?? null,
            seriesSignature,
          });
        }
        continue;
      }
      const row = snapshot.findRow('task', mapping.taskId)?.row;
      if (row && !isNil(row.purgedAt)) {
        purge({ event, draft }, mapping, 'Task permanently deleted', row);
        continue;
      }
      if (!row && mapping.state !== 'pending') {
        fail({ event, draft }, mapping, 'Mapped task missing or not visible; mapping preserved');
        continue;
      }
      if (!row) {
        // The reserved create never landed. A cancelled event stays unimported; the reservation is
        // kept, so a withdrawn cancellation still creates the task under the same id.
        if (event.cancelled) {
          stats.skipped++;
          record({ event }, 'skip', mapping.taskId, undefined, 'Cancelled before import');
          continue;
        }
        creates.push({ event, fingerprint, mapping, draft, row: undefined, delta: {} });
        continue;
      }
      // A source change reopens a completed task; an unchanged source keeps the completion.
      const delta = event.cancelled ? cancelDelta(row, nowMs) : ownedDelta(row, draft!, mapping.fingerprint !== fingerprint);
      updates.push({ event, fingerprint, mapping, draft, row, delta });
    }

    const removals: Removal[] = removedMappings.map((mapping) => {
      const row = snapshot.findRow('task', mapping.taskId)?.row;
      const write = mapping.state !== 'purged' && !!row && isNil(row.purgedAt) && isNil(row.deletedAt);
      return { mapping, row, write };
    });

    if (dryRun) {
      for (const p of creates) {
        stats.created++;
        record(p, 'create', p.mapping?.taskId);
      }
      for (const p of updates) {
        if (Object.keys(p.delta).length === 0) {
          stats.skipped++;
          record(p, 'skip', p.mapping!.taskId, p.row);
        } else if (p.event.cancelled) {
          stats.deleted++;
          record(p, 'cancel', p.mapping!.taskId, p.row);
        } else {
          stats.updated++;
          record(p, 'update', p.mapping!.taskId, p.row);
        }
      }
      for (const r of removals) {
        stats.deleted++;
        recordMapping(r.mapping, 'delete', r.row, 'Removed from ICS source');
      }
      return stats;
    }

    // Reserve every new id before any scope write.
    const fresh = creates.filter((p) => !p.mapping);
    if (fresh.length > 0) {
      await guard();
      const reserved = await store.reserveMappings(
        userId,
        sourceId,
        token,
        fresh.map((p) => ({
          icsUid: p.event.uid,
          occurrenceId: p.event.occurrenceId ?? '',
          taskId: uuidv7(nowMs),
          projectId: source.projectId,
          sequence: p.event.sequence ?? 0,
          dtstamp: p.event.dtstamp ?? null,
          seriesSignature: p.event.seriesSignature ?? null,
        })),
      );
      fresh.forEach((p, i) => {
        p.mapping = reserved[i]!;
      });
    }

    // Record the observed revision before writing, so a lost response followed by an older feed
    // cannot roll the task back. Pending mappings without a row stay pending (create is resent).
    const writes = updates.filter((p) => Object.keys(p.delta).length > 0);
    if (writes.length > 0) {
      await guard();
      await store.markUpdating(
        userId,
        sourceId,
        token,
        writes.map((p) => ({
          ...p.mapping!,
          sequence: p.event.sequence ?? 0,
          dtstamp: p.event.dtstamp ?? null,
        })),
      );
      for (const p of writes) {
        p.mapping = { ...p.mapping!, sequence: p.event.sequence ?? 0, dtstamp: p.event.dtstamp ?? null, state: 'updating' };
      }
    }

    const confirm = (p: Planned) => {
      const m = p.mapping!;
      commits.push({
        ...m,
        fingerprint: p.fingerprint,
        sequence: p.event.sequence ?? 0,
        dtstamp: p.event.dtstamp ?? null,
        state: p.event.cancelled ? 'cancelled' : 'applied',
        seriesSignature: p.event.seriesSignature ?? m.seriesSignature,
        lastError: null,
      });
    };

    // Rows that already match (a lost response that did land): the snapshot row is the readback.
    for (const p of updates) {
      if (Object.keys(p.delta).length > 0) continue;
      confirm(p);
      stats.skipped++;
      record(p, 'skip', p.mapping!.taskId, p.row);
    }

    const keys = sortKeysBefore(firstTaskSortKey(snapshot, source.projectId), creates.length);
    const planned: Planned[] = [...creates, ...writes];
    const trash = removals.filter((r) => r.write);
    const intents: WriteIntent[] = [
      ...creates.map((p, i) => createIntent(p.mapping!.taskId, p.mapping!.projectId, p.draft!, source, keys[i]!)),
      ...writes.map((p) => patchTaskIntent(p.mapping!.taskId, p.delta)),
      // Source deletion is the one case ICS writes deletedAt: a soft delete the user can restore.
      ...trash.map((r) => trashTaskIntent(r.mapping.taskId, nowMs)),
    ];

    /** Removals whose mapping may go: no write was needed, or the trash write was confirmed. */
    const settled = removals.filter((r) => !r.write);
    if (intents.length > 0) {
      await guard(true);
      let outcomes: WriteOutcome[] | null = null;
      let pushError = '';
      try {
        outcomes = await pushIntents(
          { db: deps.db, userId, deviceId: 'ics', getScopeStub: deps.getScopeStub, clock: deps.clock },
          snapshot,
          intents,
          { nowMs },
        );
      } catch (error) {
        // Unknown result: mappings keep their state and the next run reads what actually landed.
        pushError = `Task write could not be confirmed; retry keeps reserved task ID (${errMsg(error)})`;
      }
      planned.forEach((p, i) => {
        const outcome = outcomes?.[i];
        if (outcome && isPurgedOutcome(outcome)) {
          purge(p, p.mapping!, describeOutcome(outcome), p.row);
          return;
        }
        if (!outcome || outcome.status !== 'applied') {
          fail(p, p.mapping, outcome ? describeOutcome(outcome) : pushError, p.row);
          return;
        }
        confirm(p);
        if (!p.row) {
          stats.created++;
          record(p, 'create', p.mapping!.taskId);
        } else if (p.event.cancelled) {
          stats.deleted++;
          record(p, 'cancel', p.mapping!.taskId, p.row);
        } else {
          stats.updated++;
          record(p, 'update', p.mapping!.taskId, p.row);
        }
      });
      trash.forEach((r, j) => {
        const outcome = outcomes?.[planned.length + j];
        // A tombstone or a purged list is gone for good: the mapping can go as well.
        if (outcome && (outcome.status === 'applied' || isPurgedOutcome(outcome))) {
          settled.push(r);
          return;
        }
        const reason = `Source deletion not confirmed; mapping preserved for retry (${outcome ? describeOutcome(outcome) : pushError})`;
        stats.errors++;
        stats.lastError = reason;
        recordMapping(r.mapping, 'error', r.row, reason);
      });
    }

    if (commits.length > 0) {
      await guard();
      await store.commitMappings(userId, sourceId, token, commits);
    }
    if (purges.length > 0) {
      await guard();
      await store.markPurged(userId, sourceId, token, purges);
    }
    for (const r of settled) {
      try {
        await guard();
        await store.deleteMapping(userId, sourceId, token, r.mapping);
        stats.deleted++;
        recordMapping(r.mapping, 'delete', r.row, 'Removed from ICS source');
      } catch (error) {
        // The task is already in the trash (or gone); the next run deletes the mapping without a write.
        stats.errors++;
        stats.lastError = errMsg(error);
        recordMapping(r.mapping, 'error', r.row, stats.lastError);
      }
    }
    await guard(true);
    await store.setSourceSync(
      userId,
      sourceId,
      { lastSyncAt: nowMs, lastStatus: stats.errors ? 'partial' : 'success', lastStats: JSON.stringify(stats) },
      token,
    );
  } catch (error) {
    stats.errors++;
    stats.lastError = errMsg(error);
    if (!dryRun) {
      try {
        await store.setSourceSync(
          userId,
          sourceId,
          { lastSyncAt: nowMs, lastStatus: 'error', lastStats: JSON.stringify(stats) },
          token,
        );
      } catch {
        // Lease or database unavailable: the previous status stays.
      }
    }
  } finally {
    if (!dryRun) await store.releaseLease(userId, sourceId, token);
  }
  return stats;
}

export interface DueSourceResult {
  source: number;
  userId: string;
  stats: SyncStats;
  ms: number;
}

/**
 * Syncs due sources one at a time, at most `limit` per run. A failure that escapes syncSource is
 * recorded for that source and the others still run. Never passes allowMassDelete. Only the
 * dueSources query itself can throw (a run-level failure).
 */
export async function syncDueSources(
  deps: IcsEngineDeps,
  nowMs: number,
  limit: number = ICS_SOURCES_PER_RUN,
): Promise<DueSourceResult[]> {
  const out: DueSourceResult[] = [];
  for (const source of await deps.store.dueSources(nowMs, limit)) {
    const started = Date.now();
    let stats: SyncStats;
    try {
      stats = await syncSource(deps, source.userId, source.id, nowMs);
    } catch (error) {
      stats = { ...zeroStats(), errors: 1, lastError: errMsg(error) };
    }
    out.push({ source: source.id, userId: source.userId, stats, ms: Date.now() - started });
  }
  return out;
}
