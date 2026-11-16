// ICS feed -> DayDo task reconciliation (spec/mcp.md 9.3). Semantics follow REF engine.ts; writes go
// through the server writer. Task ids are reserved in the mapping before anything reaches the scope,
// so a lost response or a restart retries the same id. A mapping's fingerprint is committed only after
// the push response row shows every intended field applied.
import { scheduleToAPI, type Schedule } from '../domain/schedule';
import { before } from '../domain/sortKey';
import { uuidv7 } from '../domain/uuid';
import { loadSnapshot, type Snapshot } from '../serverops/snapshot';
import { assertHasData, pushIntents, type WriteIntent, type WriteOutcome } from '../serverops/writer';
import type { ServerHlcClock } from '../sync/hlc';
import type { AppDb, ScopeStub } from '../sync/push';
import { fetchIcs, type FetchIcsOptions } from './fetch';
import { applyFilter } from './filters';
import { eventToTaskDraft, parseIcs } from './parser';
import { IcsLeaseLostError, LEASE_TTL_MS, type IcsMapping, type IcsSource, type IcsStore, type MappingCommit } from './store';
import { FALLBACK_TIMEZONE, IcsError, type ParsedEvent, type SyncChange, type SyncStats, type TaskDraft } from './types';

export const ICS_MAX_WINDOW_DAYS = 3650;
const DAY_MS = 86_400_000;
const SCHEDULE_KEYS = ['startDay', 'startMinute', 'endDay', 'endMinute', 'timeZone'] as const;

export interface IcsEngineDeps {
  store: IcsStore;
  /** `createDb(env.DB, { session: 'first-primary' })`. */
  db: AppDb;
  getScopeStub: (scope: string) => ScopeStub;
  /** Defaults to the isolate-wide clock shared with /sync/push. */
  clock?: ServerHlcClock;
  fetchOptions?: FetchIcsOptions;
  /** `DEFAULT_TIMEZONE`, used when a source has no timezone. Defaults to Asia/Taipei. */
  defaultTimeZone?: string;
}

export interface SyncOptions {
  dryRun?: boolean;
  includeChanges?: boolean;
}

const zeroStats = (): SyncStats => ({ created: 0, updated: 0, skipped: 0, deleted: 0, errors: 0 });
const errMsg = (error: unknown) => (error instanceof Error ? error.message : String(error));
const identity = (uid: string, occurrenceId = '') => JSON.stringify([uid, occurrenceId]);
const isNil = (v: unknown) => v === undefined || v === null;
const sameValue = (a: unknown, b: unknown) =>
  JSON.stringify(isNil(a) ? null : a) === JSON.stringify(isNil(b) ? null : b);
const bump = (row: Record<string, unknown>, now: number) => Math.max(now, Number(row.updatedAt ?? 0) + 1);

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

function scheduleSet(s: Schedule): Record<string, unknown> {
  return Object.fromEntries(SCHEDULE_KEYS.map((k) => [k, s[k]]));
}

function rowSchedule(row: Record<string, unknown>): Schedule | null {
  if (typeof row.startDay !== 'string') return null;
  return {
    startDay: row.startDay,
    startMinute: typeof row.startMinute === 'number' ? row.startMinute : null,
    endDay: typeof row.endDay === 'string' ? row.endDay : null,
    endMinute: typeof row.endMinute === 'number' ? row.endMinute : null,
    timeZone: typeof row.timeZone === 'string' ? row.timeZone : null,
  };
}

/** The ICS-owned fields that differ from the row, plus a reopen when the source itself changed. */
function ownedDelta(row: Record<string, unknown>, draft: TaskDraft, reopen: boolean): Record<string, unknown> {
  const delta: Record<string, unknown> = {};
  if (!sameValue(row.title, draft.title)) delta.title = draft.title;
  if (!sameValue(row.content, draft.content)) delta.content = draft.content;
  const schedule = scheduleSet(draft.schedule);
  // The schedule is one LWW group: send all five when any differs.
  if (SCHEDULE_KEYS.some((k) => !sameValue(row[k], schedule[k]))) Object.assign(delta, schedule);
  if (reopen && row.status === 2) {
    delta.status = 0;
    delta.completedAt = null;
  }
  return delta;
}

function createSet(
  id: string,
  projectId: string,
  draft: TaskDraft,
  source: IcsSource,
  sortKey: string,
  now: number,
): Record<string, unknown> {
  return {
    id,
    projectId,
    title: draft.title,
    content: draft.content,
    priority: draft.priority,
    status: 0,
    reminders: draft.reminders,
    tags: [],
    sortKey,
    importNote: `ICS：${source.name}`,
    createdAt: now,
    updatedAt: now,
    ...scheduleSet(draft.schedule),
  };
}

function describeOutcome(o: WriteOutcome): string {
  if (o.status === 'unapplied') {
    return `Task fields not applied because a newer device edit won: ${(o.unappliedFields ?? []).join(', ')}; will retry`;
  }
  if (o.status === 'purged') return 'Task was permanently deleted';
  return `Task write rejected: ${o.reason ?? 'unknown reason'}`;
}

/** One event that needs a scope write (create or update) or a write-free commit. */
interface Planned {
  event: ParsedEvent;
  fingerprint: string;
  mapping: IcsMapping | null;
  draft: TaskDraft;
  /** Snapshot row as read when the task exists (any state, trash included); the writer later swaps in the response row. */
  row: Record<string, unknown> | undefined;
  /** Fields to write on an existing row; empty means the row already matches. */
  delta: Record<string, unknown>;
}

function listWritable(snapshot: Snapshot, projectId: string): boolean {
  const project = snapshot.findRow('project', projectId);
  return (
    !!project && isNil(project.row.deletedAt) && isNil(project.row.purgedAt) && snapshot.canWrite(projectId)
  );
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
    item: { event: ParsedEvent; draft: TaskDraft },
    action: SyncChange['action'],
    taskId?: string,
    prev?: Record<string, unknown>,
    reason?: string,
  ) => {
    if (!stats.changes) return;
    const next = scheduleToAPI(item.draft.schedule);
    const previous = prev ? rowSchedule(prev) : null;
    const api = previous ? scheduleToAPI(previous) : null;
    stats.changes.push({
      uid: item.event.uid,
      occurrenceId: item.event.occurrenceId ?? '',
      taskId,
      action,
      summary: item.event.summary,
      start: next.start ?? undefined,
      end: next.due ?? undefined,
      ...(api ? { previousStart: api.start ?? undefined, previousEnd: api.due ?? undefined } : {}),
      ...(reason ? { reason } : {}),
    });
  };
  /** Mapping commits for this run (confirmed writes, revision bumps, error notes), one batch at the end. */
  const commits: MappingCommit[] = [];
  const fail = (
    item: { event: ParsedEvent; draft: TaskDraft },
    mapping: IcsMapping | null,
    reason: string,
    prev?: Record<string, unknown>,
  ) => {
    stats.errors++;
    stats.lastError = reason;
    record(item, 'error', mapping?.taskId, prev, reason);
    // Keep the fingerprint and state: the next run retries. Only the error note is stored.
    if (mapping && !dryRun) commits.push({ ...mapping, state: mapping.state as MappingCommit['state'], lastError: reason });
  };

  try {
    const snapshot = await loadSnapshot(deps.db, userId, deps.getScopeStub);
    assertHasData(snapshot);
    if (!listWritable(snapshot, source.projectId)) {
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
    const existing = new Map(
      (await store.listMappings(userId, sourceId)).map((m) => [identity(m.icsUid, m.occurrenceId), m]),
    );
    const text = await fetchIcs(source.url, deps.fetchOptions);
    const parsed = parseIcs(
      text,
      { from: nowMs - pastDays * DAY_MS, to: nowMs + futureDays * DAY_MS, includeIdentities: new Set(existing.keys()) },
      zone,
    );
    // The date window limits new imports (parseIcs); identities already imported still update when
    // moved outside it. Keyword exclusions apply to both. Cancelled events are left alone here.
    const events = applyFilter(
      parsed.filter((e) => !e.cancelled),
      { ...source.filter, futureDays: undefined, pastDays: undefined },
      nowMs,
    );
    const fingerprints = await Promise.all(events.map(eventFingerprint));

    const seen = new Set<string>();
    const creates: Planned[] = [];
    const updates: Planned[] = [];
    for (const [index, event] of events.entries()) {
      const key = identity(event.uid, event.occurrenceId);
      if (seen.has(key)) continue;
      seen.add(key);
      const fingerprint = fingerprints[index]!;
      const mapping = existing.get(key) ?? null;
      const draft = eventToTaskDraft(event, zone);
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
        fail({ event, draft }, mapping, 'Task permanently deleted; nothing written', row);
        continue;
      }
      if (!row && mapping.state !== 'pending') {
        fail({ event, draft }, mapping, 'Mapped task missing or not visible; mapping preserved');
        continue;
      }
      // Pending without a row: the create never landed, so it is sent again with the reserved id.
      if (!row) {
        creates.push({ event, fingerprint, mapping, draft, row: undefined, delta: {} });
        continue;
      }
      // A source change reopens a completed task; an unchanged source keeps the completion.
      const reopen = mapping.fingerprint !== fingerprint;
      updates.push({ event, fingerprint, mapping, draft, row, delta: ownedDelta(row, draft, reopen) });
    }

    if (dryRun) {
      for (const p of creates) {
        stats.created++;
        record(p, 'create', p.mapping?.taskId);
      }
      for (const p of updates) {
        if (Object.keys(p.delta).length === 0) {
          stats.skipped++;
          record(p, 'skip', p.mapping!.taskId, p.row);
        } else {
          stats.updated++;
          record(p, 'update', p.mapping!.taskId, p.row);
        }
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
        state: 'applied',
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

    const first = snapshot
      .rows('task')
      .filter((t) => t.row.projectId === source.projectId && typeof t.row.sortKey === 'string' && t.row.sortKey !== '')
      .map((t) => String(t.row.sortKey))
      .reduce<string | null>((a, b) => (a === null || b < a ? b : a), null);
    const keys = sortKeysBefore(first, creates.length);
    const planned: Planned[] = [...creates, ...writes];
    const intents: WriteIntent[] = [
      ...creates.map((p, i): WriteIntent => {
        const m = p.mapping!;
        return { entity: 'task', entityId: m.taskId, set: createSet(m.taskId, m.projectId, p.draft, source, keys[i]!, nowMs) };
      }),
      ...writes.map((p): WriteIntent => ({
        entity: 'task',
        entityId: p.mapping!.taskId,
        set: { ...p.delta, updatedAt: bump(p.row!, nowMs) },
      })),
    ];

    if (intents.length > 0) {
      await guard(true);
      let outcomes: WriteOutcome[] | null = null;
      let pushError = '';
      try {
        outcomes = await pushIntents(
          { db: deps.db, userId, deviceId: 'ics', getScopeStub: deps.getScopeStub, clock: deps.clock },
          snapshot,
          intents,
        );
      } catch (error) {
        // Unknown result: mappings keep their state and the next run reads what actually landed.
        pushError = `Task write could not be confirmed; retry keeps reserved task ID (${errMsg(error)})`;
      }
      planned.forEach((p, i) => {
        const outcome = outcomes?.[i];
        if (!outcome || outcome.status !== 'applied') {
          fail(p, p.mapping, outcome ? describeOutcome(outcome) : pushError, p.row);
          return;
        }
        confirm(p);
        const created = !p.row;
        if (created) stats.created++;
        else stats.updated++;
        record(p, created ? 'create' : 'update', p.mapping!.taskId, p.row);
      });
    }

    if (commits.length > 0) {
      await guard();
      await store.commitMappings(userId, sourceId, token, commits);
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
