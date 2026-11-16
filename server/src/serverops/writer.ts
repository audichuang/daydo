// Server-side writer for MCP tools and ICS sync (spec/mcp.md 6.2): turns write intents into
// sync ops, pushes them through executeSyncPush and reports the server's answer per intent.
import { parseReminder } from '../domain/reminders';
import { MAX_INTERVAL, parseWritableRecurrence } from '../domain/recurrence';
import { isValidDay, isValidTimeZone } from '../domain/schedule';
import { isGeneratedKeyValid } from '../domain/sortKey';
import { uuidv7 } from '../domain/uuid';
import {
  SCHEDULE_FIELDS,
  SCHEDULE_FIELD_SET,
  hasAllRequiredFields,
  isTaskChildEntity,
  validateSyncOp,
  ENTITY_FIELDS,
} from '../sync/entities';
import {
  SERVER_HLC_DEVICE_ID,
  formatHlc,
  normalizeHlc,
  parseHlc,
  type Hlc,
  type ServerHlcClock,
} from '../sync/hlc';
import { executeSyncPush, type AppDb, type ScopeStub } from '../sync/push';
import { serverClock } from '../sync/serverClock';
import type { Snapshot } from './snapshot';

export const MAX_OPS_PER_PUSH = 200;
export const NO_DATA_MESSAGE = '請先在 DayDo App 登入並同步一次';

export type WritableEntity = 'project' | 'task' | 'checklistItem' | 'tag';

export interface WriteIntent {
  entity: WritableEntity;
  /** Entity key (`name` for tags). New ids are UUIDv7 chosen by the caller. */
  entityId: string;
  /** Values to write. A new row needs every non-nullable field; an existing row gets only this delta. */
  set: Record<string, unknown>;
  /** Fields copied as-is from an existing row (e.g. a completed copy's sortKey); skipped by value checks. */
  verbatim?: readonly string[];
}

export interface WriterDeps {
  /** `createDb(env.DB, { session: 'first-primary' })`. */
  db: AppDb;
  userId: string;
  deviceId: 'mcp' | 'ics';
  getScopeStub: (scope: string) => ScopeStub;
  /** Defaults to the isolate-wide clock shared with /sync/push. */
  clock?: ServerHlcClock;
}

/**
 * applied: every written field is in the server row.
 * purged: the server holds a tombstone for this id (the row carries purgedAt).
 * unapplied: some fields lost LWW to a newer device edit; nothing is resent.
 * rejected: the server refused the op (reason passed through, e.g. Forbidden).
 * skipped: not sent because an earlier chunk failed (writeOrThrow only).
 * writeOrThrow treats purged, unapplied and rejected as failures.
 */
export type WriteStatus = 'applied' | 'purged' | 'unapplied' | 'rejected' | 'skipped';

export interface WriteOutcome {
  entity: WritableEntity;
  entityId: string;
  status: WriteStatus;
  /** Server row from the push response (never the value we meant to write). */
  row: Record<string, unknown> | null;
  clocks: Record<string, string>;
  reason?: string;
  unappliedFields?: string[];
}

/** A bad value caught before anything was pushed. */
export class WriteValidationError extends Error {
  readonly field: string;
  constructor(field: string, message: string) {
    super(message);
    this.name = 'WriteValidationError';
    this.field = field;
  }
}

/** A rejected or partly unapplied op, carrying the server's row. */
export class WriteError extends Error {
  readonly outcome: WriteOutcome;
  constructor(outcome: WriteOutcome) {
    super(describeFailure(outcome));
    this.name = 'WriteError';
    this.outcome = outcome;
  }
}

function describeFailure(o: WriteOutcome): string {
  const target = `${o.entity} ${o.entityId}`;
  if (o.status === 'purged') {
    return `${target} was permanently deleted; nothing was written. Re-read and retry.`;
  }
  if (o.status === 'unapplied') {
    return (
      `${target}: fields not applied because a newer edit from another device won: ` +
      `${(o.unappliedFields ?? []).join(', ')}. Re-read and retry. Server row: ${JSON.stringify(o.row)}`
    );
  }
  return `${target} rejected: ${o.reason ?? 'unknown reason'}`;
}

/** Accounts without a bound member or inbox have never synced from the App; the server does not create them. */
export function assertHasData(snapshot: Snapshot): void {
  if (snapshot.meMemberId === null || snapshot.inboxProjectId === null) {
    throw new Error(NO_DATA_MESSAGE);
  }
}

const WRITABLE = new Set<string>(['project', 'task', 'checklistItem', 'tag']);
const PRIORITIES = new Set([0, 1, 3, 5]);

interface PlannedOp {
  index: number;
  intent: WriteIntent;
  op: {
    opId: string;
    hlc: string;
    entity: WritableEntity;
    entityId: string;
    op: 'upsert';
    fields: string[];
    row: Record<string, unknown>;
  };
}

function keyField(entity: WritableEntity): string {
  return entity === 'tag' ? 'name' : 'id';
}

function isNil(v: unknown): boolean {
  return v === null || v === undefined;
}

function maxClockMs(clocks: Record<string, string>): number {
  let max = 0;
  for (const raw of Object.values(clocks)) {
    const h = parseHlc(raw);
    if (h && h.ms > max) max = h.ms;
  }
  return max;
}

function isMinute(v: unknown): boolean {
  return typeof v === 'number' && Number.isInteger(v) && v >= 0 && v <= 1439;
}

/** spec/mcp.md 6.2: the server push only checks types, so domain ranges are enforced here. */
function validateValues(
  intent: WriteIntent,
  current: Record<string, unknown> | undefined,
  snapshot: Snapshot,
): void {
  const { entity, set } = intent;
  const verbatim = new Set(intent.verbatim ?? []);
  const touched = Object.keys(set).filter((f) => !verbatim.has(f));
  const fail = (field: string, why: string): never => {
    throw new WriteValidationError(field, `Invalid ${entity}.${field}: ${why}`);
  };

  for (const field of touched) {
    const v = set[field];
    switch (field) {
      case 'priority':
        if (entity === 'task' && !PRIORITIES.has(v as number)) fail(field, 'must be 0, 1, 3 or 5');
        break;
      case 'status':
        if (entity === 'task' && v !== 0 && v !== 2) fail(field, 'must be 0 or 2');
        if (entity === 'checklistItem' && v !== 0 && v !== 1) fail(field, 'must be 0 or 1');
        break;
      case 'startDay':
      case 'endDay':
        if (!isNil(v) && !(typeof v === 'string' && isValidDay(v))) {
          fail(field, 'must be a real YYYY-MM-DD day');
        }
        break;
      case 'startMinute':
      case 'endMinute':
        if (!isNil(v) && !isMinute(v)) fail(field, 'must be an integer in 0-1439');
        break;
      case 'timeZone':
        if (!isNil(v) && !(typeof v === 'string' && isValidTimeZone(v))) {
          fail(field, 'must be an IANA time zone name');
        }
        break;
      case 'sortKey':
        if (!(typeof v === 'string' && isGeneratedKeyValid(v))) {
          fail(field, 'must match ^[0-9a-z]*[1-9a-z]$');
        }
        break;
      case 'reminders':
        if (
          entity === 'task' &&
          !(Array.isArray(v) && v.every((r) => typeof r === 'string' && parseReminder(r) !== null))
        ) {
          fail(field, 'every reminder must be a valid trigger');
        }
        break;
      case 'repeatRule':
        if (!isNil(v) && !(typeof v === 'string' && parseWritableRecurrence(v) !== null)) {
          fail(field, `unsupported RRULE or INTERVAL above ${MAX_INTERVAL}`);
        }
        break;
      case 'ownerId':
        if (entity === 'project' && v !== snapshot.meMemberId) fail(field, 'must be your member id');
        break;
      case 'isInbox':
        if (entity === 'project' && v !== false) fail(field, 'must be false');
        break;
      default:
        break;
    }
  }

  if (entity !== 'task') return;
  const all = Object.keys(set);
  const merged = { ...current, ...set };
  if (all.includes('status') || all.includes('completedAt')) {
    if ((merged.status === 2) !== !isNil(merged.completedAt)) {
      fail('completedAt', 'must be set exactly when status is 2');
    }
  }
  if (all.some((f) => SCHEDULE_FIELD_SET.has(f) || f === 'reminders' || f === 'repeatRule')) {
    if (isNil(merged.startDay)) {
      const reminders = merged.reminders;
      if (Array.isArray(reminders) && reminders.length > 0) {
        fail('reminders', 'must be empty without a schedule');
      }
      if (!isNil(merged.repeatRule)) fail('repeatRule', 'must be null without a schedule');
    }
  }
}

function planOps(
  snapshot: Snapshot,
  intents: readonly WriteIntent[],
  clock: ServerHlcClock,
): PlannedOp[] {
  const nowMs = Date.now();
  const lastHlc = new Map<string, Hlc>();
  const planned = intents.map((intent, index): PlannedOp => {
    const { entity, entityId } = intent;
    if (!WRITABLE.has(entity)) {
      throw new WriteValidationError('entity', `Writer does not handle ${String(entity)}`);
    }
    const key = keyField(entity);
    if (!isNil(intent.set[key]) && intent.set[key] !== entityId) {
      throw new WriteValidationError(key, `${entity}.${key} does not match ${entityId}`);
    }
    const current = snapshot.findRow(entity, entityId);

    let fields: string[];
    const row: Record<string, unknown> = {};
    if (current) {
      // Delta only: re-sending the key and every required field would make push treat
      // a row homed in another scope as a foreign create (id-in-other-scope).
      fields = Object.keys(intent.set).filter((f) => f !== key && f !== 'createdAt');
      for (const f of fields) row[f] = intent.set[f];
    } else {
      Object.assign(row, intent.set);
      fields = Object.keys(row).filter((f) => f !== key);
      if (!hasAllRequiredFields(entity, [key, ...fields])) {
        const missing = Object.entries(ENTITY_FIELDS[entity])
          .filter(([f, spec]) => !spec.nullable && f !== key && !fields.includes(f))
          .map(([f]) => f);
        throw new WriteValidationError(
          missing[0] ?? key,
          `New ${entity} ${entityId} is missing required fields: ${missing.join(', ')}`,
        );
      }
      fields.unshift(key);
    }
    row[key] = entityId;

    // mergeOp rewrites all five schedule fields from op.row when any is listed,
    // so the untouched ones carry the current values (absent = null).
    if (entity === 'task' && fields.some((f) => SCHEDULE_FIELD_SET.has(f))) {
      for (const sf of SCHEDULE_FIELDS) {
        if (fields.includes(sf)) continue;
        fields.push(sf);
        const cur = current?.row[sf];
        if (!isNil(cur)) row[sf] = cur;
      }
    }
    if (fields.length === 0) {
      throw new WriteValidationError(key, `Nothing to write for ${entity} ${entityId}`);
    }

    validateValues(intent, current?.row, snapshot);

    const rowKey = `${entity}:${entityId}`;
    const prev = lastHlc.get(rowKey);
    let hlc: Hlc;
    if (prev) {
      hlc = normalizeHlc({ ms: prev.ms, counter: prev.counter + 1, deviceId: SERVER_HLC_DEVICE_ID });
    } else if (current) {
      hlc = {
        ms: Math.max(nowMs, maxClockMs(current.clocks)) + 1,
        counter: 0,
        deviceId: SERVER_HLC_DEVICE_ID,
      };
    } else {
      hlc = parseHlc(clock.tick(nowMs))!;
    }
    lastHlc.set(rowKey, hlc);

    const op = {
      opId: uuidv7(nowMs),
      hlc: formatHlc(hlc),
      entity,
      entityId,
      op: 'upsert' as const,
      fields,
      row,
    };
    const checked = validateSyncOp(op);
    if (!checked.ok) {
      throw new WriteValidationError(key, `Invalid ${entity} ${entityId}: ${checked.reason}`);
    }
    return { index, intent, op };
  });

  // Stable: child rows go last so a child never precedes its task in a chunk or lands in an
  // earlier chunk; everything else keeps caller order (delete_project trashes tasks before the list).
  const rank = (e: WritableEntity) => (isTaskChildEntity(e) ? 1 : 0);
  return planned
    .map((p, order) => ({ p, order }))
    .sort((a, b) => rank(a.p.op.entity) - rank(b.p.op.entity) || a.order - b.order)
    .map(({ p }) => p);
}

function sameValue(a: unknown, b: unknown): boolean {
  const x = isNil(a) ? null : a;
  const y = isNil(b) ? null : b;
  if (Array.isArray(x) || Array.isArray(y)) return JSON.stringify(x) === JSON.stringify(y);
  return x === y;
}

function classify(
  p: PlannedOp,
  result: { status: string; reason?: string; row: Record<string, unknown> | null; clocks: Record<string, string> } | undefined,
): WriteOutcome {
  const base = { entity: p.op.entity, entityId: p.op.entityId };
  if (!result) {
    return { ...base, status: 'rejected', row: null, clocks: {}, reason: 'No result from server' };
  }
  const row = result.row;
  const clocks = result.clocks ?? {};
  if (result.status === 'rejected') {
    return { ...base, status: 'rejected', row, clocks, reason: result.reason ?? 'Rejected' };
  }
  if (!row) {
    return { ...base, status: 'rejected', row: null, clocks, reason: 'Row is no longer visible' };
  }
  if (!isNil(row.purgedAt)) {
    return { ...base, status: 'purged', row, clocks };
  }
  const key = keyField(p.op.entity);
  const lost = p.op.fields.filter((f) => f !== key && !sameValue(p.op.row[f], row[f]));
  if (lost.length > 0) {
    return { ...base, status: 'unapplied', row, clocks, unappliedFields: lost };
  }
  return { ...base, status: 'applied', row, clocks };
}

function isFailure(o: WriteOutcome): boolean {
  return o.status === 'rejected' || o.status === 'unapplied' || o.status === 'purged';
}

/**
 * Pushes the intents (validated up front, nothing sent on a bad value) and returns one outcome
 * per intent, in intent order. Existing snapshot rows are refreshed from the response.
 */
export async function pushIntents(
  deps: WriterDeps,
  snapshot: Snapshot,
  intents: readonly WriteIntent[],
  options: { stopOnFailure?: boolean } = {},
): Promise<WriteOutcome[]> {
  assertHasData(snapshot);
  const clock = deps.clock ?? serverClock;
  const plan = planOps(snapshot, intents, clock);
  const outcomes: WriteOutcome[] = intents.map((i) => ({
    entity: i.entity,
    entityId: i.entityId,
    status: 'skipped',
    row: null,
    clocks: {},
  }));

  for (let start = 0; start < plan.length; start += MAX_OPS_PER_PUSH) {
    const chunk = plan.slice(start, start + MAX_OPS_PER_PUSH);
    const res = await executeSyncPush(deps.db, {
      userId: deps.userId,
      deviceId: deps.deviceId,
      ops: chunk.map((p) => p.op),
      getScopeStub: deps.getScopeStub,
      clock,
    });
    let failed = false;
    chunk.forEach((p, j) => {
      const outcome = classify(p, res.results[j]);
      outcomes[p.index] = outcome;
      if (isFailure(outcome)) failed = true;
      if (outcome.row) {
        const cached = snapshot.findRow(p.op.entity, p.op.entityId);
        if (cached) {
          cached.row = outcome.row;
          cached.clocks = outcome.clocks;
        }
      }
    });
    if (failed && options.stopOnFailure) break;
  }
  return outcomes;
}

/**
 * Tool-layer variant: stops after the first chunk with a failure and throws a WriteError for the
 * first failing intent (callers that handle tombstones themselves use pushIntents).
 */
export async function writeOrThrow(
  deps: WriterDeps,
  snapshot: Snapshot,
  intents: readonly WriteIntent[],
): Promise<WriteOutcome[]> {
  const outcomes = await pushIntents(deps, snapshot, intents, { stopOnFailure: true });
  const failure = outcomes.find(isFailure);
  if (failure) throw new WriteError(failure);
  return outcomes;
}
