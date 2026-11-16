// Persistence for ICS sources and their per-event mappings (spec/mcp.md 9.2).
// Every method is scoped to a userId; only dueSources (the cron's query) crosses users.
// Writes that follow a lease are conditional on that lease still being valid, so a run whose
// lease expired (and was taken over) can no longer touch rows. Success is detected with
// RETURNING rather than result metadata.
import { icsMapping, icsSource } from '@schema';
import { and, asc, eq, isNull, lte, ne, or, sql, type BatchItem } from 'void/db';
import { systemNow } from '../clock';
import type { AppDb } from '../sync/push';
import { IcsError, type IcsFilter } from './types';

export const LEASE_TTL_MS = 5 * 60 * 1000;
export const MAX_SOURCES_PER_USER = 10;
export const MIN_SYNC_INTERVAL_SEC = 300;
export const DEFAULT_SYNC_INTERVAL_SEC = 900;
/** Cron fires a little early or late; without slack a due source would slip a whole tick. */
const DUE_SLACK_MS = 15_000;

export type IcsMappingState = 'pending' | 'updating' | 'applied' | 'cancelled' | 'purged';

export interface IcsSource {
  id: number;
  userId: string;
  name: string;
  url: string;
  projectId: string;
  enabled: boolean;
  syncIntervalSec: number;
  filter: IcsFilter | null;
  /** IANA zone for floating times; null means DEFAULT_TIMEZONE. */
  timezone: string | null;
  /** Epoch ms. */
  lastSyncAt: number | null;
  lastStatus: string | null;
  lastStats: string | null;
  createdAt: number;
  updatedAt: number;
}

export interface IcsMapping {
  sourceId: number;
  icsUid: string;
  occurrenceId: string;
  taskId: string;
  projectId: string;
  fingerprint: string | null;
  sequence: number;
  dtstamp: string | null;
  state: IcsMappingState;
  seriesSignature: string | null;
  lastError: string | null;
  updatedAt: number;
}

export interface AddSourceInput {
  name: string;
  url: string;
  projectId: string;
  syncIntervalSec?: number;
  filter?: IcsFilter;
  timezone?: string;
}

export interface SourceSyncUpdate {
  lastSyncAt: number;
  lastStatus: string;
  lastStats: string;
}

export interface MappingKey {
  icsUid: string;
  occurrenceId: string;
}

/** A new event: the task id is decided here and stored before anything is written to the scope. */
export interface NewMapping extends MappingKey {
  taskId: string;
  projectId: string;
  sequence: number;
  dtstamp: string | null;
  seriesSignature: string | null;
}

export interface MappingStart extends MappingKey {
  taskId: string;
  sequence: number;
  dtstamp: string | null;
}

export interface MappingCommit extends MappingKey {
  taskId: string;
  fingerprint: string | null;
  sequence: number;
  dtstamp: string | null;
  state: Exclude<IcsMappingState, 'purged'>;
  seriesSignature: string | null;
  lastError: string | null;
}

export interface MappingPurge extends MappingKey {
  taskId: string;
  lastError?: string | null;
}

export class IcsLeaseLostError extends Error {
  constructor() {
    super('ICS source lease lost');
    this.name = 'IcsLeaseLostError';
  }
}

/** The mapping is missing, was reserved for another task id, or is already purged. */
export class IcsMappingConflictError extends Error {
  constructor() {
    super('ICS mapping changed or purged');
    this.name = 'IcsMappingConflictError';
  }
}

/**
 * Lease-guarded mapping writes take a lease token. Batch methods apply atomically with respect to
 * the lease (an invalid lease voids the whole batch, throwing IcsLeaseLostError). A taskId or purged
 * mismatch skips that item and throws IcsMappingConflictError after the others were applied.
 */
export interface IcsStore {
  addSource(userId: string, input: AddSourceInput): Promise<IcsSource>;
  listSources(userId: string): Promise<IcsSource[]>;
  getSource(userId: string, id: number): Promise<IcsSource | null>;
  /** Deletes the source and its mappings (not the synced tasks). False when it did not exist. */
  removeSource(userId: string, id: number): Promise<boolean>;
  setSourceSync(userId: string, id: number, update: SourceSyncUpdate, lease?: string): Promise<void>;
  acquireLease(userId: string, id: number, token: string, nowMs: number, ttlMs: number): Promise<boolean>;
  renewLease(userId: string, id: number, token: string, nowMs: number, ttlMs: number): Promise<boolean>;
  releaseLease(userId: string, id: number, token: string): Promise<void>;
  /** Enabled sources whose next sync is due, least recently synced first. Crosses users. */
  dueSources(nowMs: number, limit: number): Promise<IcsSource[]>;
  getMapping(userId: string, sourceId: number, key: MappingKey): Promise<IcsMapping | null>;
  listMappings(userId: string, sourceId: number): Promise<IcsMapping[]>;
  countMappings(userId: string, sourceId: number): Promise<number>;
  /** Inserts missing mappings as `pending` (existing rows win) and returns the stored rows in order. */
  reserveMappings(userId: string, sourceId: number, lease: string, items: NewMapping[]): Promise<IcsMapping[]>;
  /** Records sequence and dtstamp and marks the mappings `updating`, before the task write. */
  markUpdating(userId: string, sourceId: number, lease: string, items: MappingStart[]): Promise<void>;
  /** Stores the fingerprint and final state after the task write was confirmed. */
  commitMappings(userId: string, sourceId: number, lease: string, items: MappingCommit[]): Promise<void>;
  /** Terminal state: nothing is written to the task again. Idempotent. */
  markPurged(userId: string, sourceId: number, lease: string, items: MappingPurge[]): Promise<void>;
  deleteMapping(userId: string, sourceId: number, lease: string, key: MappingKey): Promise<void>;
}

function checkInterval(sec: number | undefined): number {
  const value = sec ?? DEFAULT_SYNC_INTERVAL_SEC;
  if (!Number.isInteger(value) || value < MIN_SYNC_INTERVAL_SEC) {
    throw new IcsError(`sync_interval_sec must be an integer of at least ${MIN_SYNC_INTERVAL_SEC}`);
  }
  return value;
}

/** Code-unit order, like SQLite's default collation. */
const compareText = (a: string, b: string) => (a < b ? -1 : a > b ? 1 : 0);

const sourceLimitError = () => new IcsError(`At most ${MAX_SOURCES_PER_USER} ICS sources per user`);

function mappingKeyOf(sourceId: number, key: MappingKey): string {
  return JSON.stringify([sourceId, key.icsUid, key.occurrenceId]);
}

// ---------------------------------------------------------------------------
// D1
// ---------------------------------------------------------------------------

type SourceRow = typeof icsSource.$inferSelect;
type MappingRow = typeof icsMapping.$inferSelect;

function toSource(r: SourceRow): IcsSource {
  return {
    id: r.id,
    userId: r.userId,
    name: r.name,
    url: r.url,
    projectId: r.projectId,
    enabled: r.enabled !== 0,
    syncIntervalSec: r.syncIntervalSec,
    filter: r.filterJson ? (JSON.parse(r.filterJson) as IcsFilter) : null,
    timezone: r.timezone,
    lastSyncAt: r.lastSyncAt,
    lastStatus: r.lastStatus,
    lastStats: r.lastStats,
    createdAt: r.createdAt,
    updatedAt: r.updatedAt,
  };
}

function toMapping(r: MappingRow): IcsMapping {
  return {
    sourceId: r.sourceId,
    icsUid: r.icsUid,
    occurrenceId: r.occurrenceId,
    taskId: r.taskId,
    projectId: r.projectId,
    fingerprint: r.fingerprint,
    sequence: r.sequence ?? 0,
    dtstamp: r.dtstamp,
    state: r.state as IcsMappingState,
    seriesSignature: r.seriesSignature,
    lastError: r.lastError,
    updatedAt: r.updatedAt,
  };
}

/** The source belongs to the user. icsMapping has no userId, so ownership is checked through it. */
const owns = (userId: string, sourceId: number) =>
  sql`EXISTS (SELECT 1 FROM icsSource WHERE id = ${sourceId} AND userId = ${userId})`;

/** The caller still holds an unexpired lease on its own source. */
const leased = (userId: string, sourceId: number, token: string, nowMs: number) =>
  sql`EXISTS (SELECT 1 FROM icsSource WHERE id = ${sourceId} AND userId = ${userId} AND leaseToken = ${token} AND leaseUntilMs > ${nowMs})`;

export class D1IcsStore implements IcsStore {
  private readonly now: () => number;

  constructor(
    private readonly db: AppDb,
    options: { now?: () => number } = {},
  ) {
    this.now = options.now ?? systemNow;
  }

  async addSource(userId: string, input: AddSourceInput): Promise<IcsSource> {
    const interval = checkInterval(input.syncIntervalSec);
    const now = this.now();
    const filterJson = input.filter ? JSON.stringify(input.filter) : null;
    // One statement, so concurrent adds cannot both pass the count check. Values follow the
    // column order of icsSource.
    const rows = await this.db
      .insert(icsSource)
      .select(
        sql`SELECT NULL, ${userId}, ${input.name}, ${input.url}, ${input.projectId}, 1, ${interval}, ${filterJson}, ${input.timezone ?? null}, NULL, NULL, NULL, NULL, NULL, ${now}, ${now} WHERE (SELECT count(*) FROM icsSource WHERE userId = ${userId}) < ${MAX_SOURCES_PER_USER}`,
      )
      .returning();
    const row = rows[0];
    if (!row) throw sourceLimitError();
    return toSource(row);
  }

  async listSources(userId: string): Promise<IcsSource[]> {
    const rows = await this.db
      .select()
      .from(icsSource)
      .where(eq(icsSource.userId, userId))
      .orderBy(asc(icsSource.id));
    return rows.map(toSource);
  }

  async getSource(userId: string, id: number): Promise<IcsSource | null> {
    const row = await this.db
      .select()
      .from(icsSource)
      .where(and(eq(icsSource.id, id), eq(icsSource.userId, userId)))
      .get();
    return row ? toSource(row) : null;
  }

  async removeSource(userId: string, id: number): Promise<boolean> {
    // Mappings first: their ownership check reads the source row.
    const [, removed] = await this.db.batch([
      this.db.delete(icsMapping).where(and(eq(icsMapping.sourceId, id), owns(userId, id))),
      this.db
        .delete(icsSource)
        .where(and(eq(icsSource.id, id), eq(icsSource.userId, userId)))
        .returning({ id: icsSource.id }),
    ]);
    return removed.length > 0;
  }

  async setSourceSync(userId: string, id: number, update: SourceSyncUpdate, lease?: string): Promise<void> {
    const now = this.now();
    const rows = await this.db
      .update(icsSource)
      .set({
        lastSyncAt: update.lastSyncAt,
        lastStatus: update.lastStatus,
        lastStats: update.lastStats,
        updatedAt: now,
      })
      .where(
        and(
          eq(icsSource.id, id),
          eq(icsSource.userId, userId),
          lease === undefined ? undefined : leased(userId, id, lease, now),
        ),
      )
      .returning({ id: icsSource.id });
    if (lease !== undefined && rows.length === 0) throw new IcsLeaseLostError();
  }

  async acquireLease(userId: string, id: number, token: string, nowMs: number, ttlMs: number): Promise<boolean> {
    const rows = await this.db
      .update(icsSource)
      .set({ leaseToken: token, leaseUntilMs: nowMs + ttlMs })
      .where(
        and(
          eq(icsSource.id, id),
          eq(icsSource.userId, userId),
          eq(icsSource.enabled, 1),
          or(isNull(icsSource.leaseToken), lte(icsSource.leaseUntilMs, nowMs)),
        ),
      )
      .returning({ id: icsSource.id });
    return rows.length === 1;
  }

  async renewLease(userId: string, id: number, token: string, nowMs: number, ttlMs: number): Promise<boolean> {
    const rows = await this.db
      .update(icsSource)
      .set({ leaseUntilMs: nowMs + ttlMs })
      .where(and(eq(icsSource.id, id), eq(icsSource.enabled, 1), leased(userId, id, token, nowMs)))
      .returning({ id: icsSource.id });
    return rows.length === 1;
  }

  async releaseLease(userId: string, id: number, token: string): Promise<void> {
    await this.db
      .update(icsSource)
      .set({ leaseToken: null, leaseUntilMs: null })
      .where(and(eq(icsSource.id, id), eq(icsSource.userId, userId), eq(icsSource.leaseToken, token)));
  }

  async dueSources(nowMs: number, limit: number): Promise<IcsSource[]> {
    const rows = await this.db
      .select()
      .from(icsSource)
      .where(
        and(
          eq(icsSource.enabled, 1),
          or(
            isNull(icsSource.lastSyncAt),
            sql`${icsSource.lastSyncAt} + ${icsSource.syncIntervalSec} * 1000 <= ${nowMs + DUE_SLACK_MS}`,
          ),
        ),
      )
      // Never synced first, then the longest wait: with a small per-tick limit, ids must not starve.
      .orderBy(sql`coalesce(${icsSource.lastSyncAt}, 0)`, asc(icsSource.id))
      .limit(limit);
    return rows.map(toSource);
  }

  async getMapping(userId: string, sourceId: number, key: MappingKey): Promise<IcsMapping | null> {
    const row = await this.db
      .select()
      .from(icsMapping)
      .where(
        and(
          eq(icsMapping.sourceId, sourceId),
          eq(icsMapping.icsUid, key.icsUid),
          eq(icsMapping.occurrenceId, key.occurrenceId),
          owns(userId, sourceId),
        ),
      )
      .get();
    return row ? toMapping(row) : null;
  }

  async listMappings(userId: string, sourceId: number): Promise<IcsMapping[]> {
    const rows = await this.db
      .select()
      .from(icsMapping)
      .where(and(eq(icsMapping.sourceId, sourceId), owns(userId, sourceId)))
      .orderBy(asc(icsMapping.icsUid), asc(icsMapping.occurrenceId));
    return rows.map(toMapping);
  }

  async countMappings(userId: string, sourceId: number): Promise<number> {
    const row = await this.db
      .select({ n: sql<number>`count(*)` })
      .from(icsMapping)
      .where(and(eq(icsMapping.sourceId, sourceId), owns(userId, sourceId)))
      .get();
    return Number(row?.n ?? 0);
  }

  async reserveMappings(
    userId: string,
    sourceId: number,
    lease: string,
    items: NewMapping[],
  ): Promise<IcsMapping[]> {
    if (items.length === 0) return [];
    const now = this.now();
    if (!(await this.renewLease(userId, sourceId, lease, now, LEASE_TTL_MS))) throw new IcsLeaseLostError();
    // Values follow the column order of icsMapping.
    const inserts: BatchItem<'sqlite'>[] = items.map((m) =>
      this.db
        .insert(icsMapping)
        .select(
          sql`SELECT ${sourceId}, ${m.icsUid}, ${m.occurrenceId}, ${m.taskId}, ${m.projectId}, NULL, ${m.sequence}, ${m.dtstamp}, 'pending', ${m.seriesSignature}, NULL, ${now} WHERE ${leased(userId, sourceId, lease, now)}`,
        )
        .onConflictDoNothing(),
    );
    await this.db.batch(inserts as [BatchItem<'sqlite'>, ...BatchItem<'sqlite'>[]]);
    const stored = new Map((await this.listMappings(userId, sourceId)).map((m) => [mappingKeyOf(sourceId, m), m]));
    return items.map((m) => {
      const row = stored.get(mappingKeyOf(sourceId, m));
      if (!row) throw new IcsLeaseLostError();
      return row;
    });
  }

  markUpdating(userId: string, sourceId: number, lease: string, items: MappingStart[]): Promise<void> {
    return this.updateBatch(userId, sourceId, lease, items, false, (m, now) => ({
      sequence: m.sequence,
      dtstamp: m.dtstamp,
      state: 'updating',
      updatedAt: now,
    }));
  }

  commitMappings(userId: string, sourceId: number, lease: string, items: MappingCommit[]): Promise<void> {
    return this.updateBatch(userId, sourceId, lease, items, false, (m, now) => ({
      fingerprint: m.fingerprint,
      sequence: m.sequence,
      dtstamp: m.dtstamp,
      state: m.state,
      seriesSignature: m.seriesSignature,
      lastError: m.lastError,
      updatedAt: now,
    }));
  }

  markPurged(userId: string, sourceId: number, lease: string, items: MappingPurge[]): Promise<void> {
    return this.updateBatch(userId, sourceId, lease, items, true, (m, now) => ({
      state: 'purged',
      ...(m.lastError === undefined ? {} : { lastError: m.lastError }),
      updatedAt: now,
    }));
  }

  async deleteMapping(userId: string, sourceId: number, lease: string, key: MappingKey): Promise<void> {
    const now = this.now();
    const rows = await this.db
      .delete(icsMapping)
      .where(
        and(
          eq(icsMapping.sourceId, sourceId),
          eq(icsMapping.icsUid, key.icsUid),
          eq(icsMapping.occurrenceId, key.occurrenceId),
          leased(userId, sourceId, lease, now),
        ),
      )
      .returning({ icsUid: icsMapping.icsUid });
    // A mapping that is already gone is fine; a lost lease is not.
    if (rows.length === 0 && !(await this.holdsLease(userId, sourceId, lease, now))) throw new IcsLeaseLostError();
  }

  private async holdsLease(userId: string, sourceId: number, lease: string, now: number): Promise<boolean> {
    const holder = await this.db
      .select({ id: icsSource.id })
      .from(icsSource)
      .where(
        and(
          eq(icsSource.id, sourceId),
          eq(icsSource.userId, userId),
          eq(icsSource.leaseToken, lease),
          sql`${icsSource.leaseUntilMs} > ${now}`,
        ),
      )
      .get();
    return holder !== undefined;
  }

  /**
   * One db.batch of conditional UPDATEs. Each statement carries the mapping key, the reserved
   * taskId, the lease, and (unless `allowPurged`) `state <> 'purged'`.
   */
  private async updateBatch<T extends MappingKey & { taskId: string }>(
    userId: string,
    sourceId: number,
    lease: string,
    items: T[],
    allowPurged: boolean,
    set: (item: T, now: number) => Partial<typeof icsMapping.$inferInsert>,
  ): Promise<void> {
    if (items.length === 0) return;
    const now = this.now();
    const updates: BatchItem<'sqlite'>[] = items.map((m) =>
        this.db
          .update(icsMapping)
          .set(set(m, now))
          .where(
            and(
              eq(icsMapping.sourceId, sourceId),
              eq(icsMapping.icsUid, m.icsUid),
              eq(icsMapping.occurrenceId, m.occurrenceId),
              eq(icsMapping.taskId, m.taskId),
              allowPurged ? undefined : ne(icsMapping.state, 'purged'),
              leased(userId, sourceId, lease, now),
            ),
          )
          .returning({ icsUid: icsMapping.icsUid }),
    );
    const results = (await this.db.batch(
      updates as [BatchItem<'sqlite'>, ...BatchItem<'sqlite'>[]],
    )) as Array<unknown[]>;
    if (results.every((rows) => rows.length > 0)) return;
    // Tell a lost lease (which voided every statement) from a conflicting row.
    throw (await this.holdsLease(userId, sourceId, lease, now))
      ? new IcsMappingConflictError()
      : new IcsLeaseLostError();
  }
}

// ---------------------------------------------------------------------------
// In memory (engine tests)
// ---------------------------------------------------------------------------

/** Pure in-memory store with the same contract as D1IcsStore. */
export class MemoryIcsStore implements IcsStore {
  private readonly now: () => number;
  private readonly sources = new Map<number, IcsSource>();
  private readonly leases = new Map<number, { token: string; until: number }>();
  private readonly mappings = new Map<string, IcsMapping>();
  private nextId = 1;

  constructor(options: { now?: () => number } = {}) {
    this.now = options.now ?? systemNow;
  }

  private owned(userId: string, id: number): IcsSource | undefined {
    const s = this.sources.get(id);
    return s && s.userId === userId ? s : undefined;
  }

  private holds(userId: string, id: number, token: string, nowMs: number): boolean {
    const lease = this.leases.get(id);
    return !!this.owned(userId, id) && lease?.token === token && lease.until > nowMs;
  }

  async addSource(userId: string, input: AddSourceInput): Promise<IcsSource> {
    const interval = checkInterval(input.syncIntervalSec);
    const count = [...this.sources.values()].filter((s) => s.userId === userId).length;
    if (count >= MAX_SOURCES_PER_USER) throw sourceLimitError();
    const now = this.now();
    const source: IcsSource = {
      id: this.nextId++,
      userId,
      name: input.name,
      url: input.url,
      projectId: input.projectId,
      enabled: true,
      syncIntervalSec: interval,
      filter: input.filter ? (JSON.parse(JSON.stringify(input.filter)) as IcsFilter) : null,
      timezone: input.timezone ?? null,
      lastSyncAt: null,
      lastStatus: null,
      lastStats: null,
      createdAt: now,
      updatedAt: now,
    };
    this.sources.set(source.id, source);
    return structuredClone(source);
  }

  async listSources(userId: string): Promise<IcsSource[]> {
    return [...this.sources.values()]
      .filter((s) => s.userId === userId)
      .sort((a, b) => a.id - b.id)
      .map((s) => structuredClone(s));
  }

  async getSource(userId: string, id: number): Promise<IcsSource | null> {
    const s = this.owned(userId, id);
    return s ? structuredClone(s) : null;
  }

  async removeSource(userId: string, id: number): Promise<boolean> {
    if (!this.owned(userId, id)) return false;
    for (const [key, m] of this.mappings) if (m.sourceId === id) this.mappings.delete(key);
    this.leases.delete(id);
    this.sources.delete(id);
    return true;
  }

  async setSourceSync(userId: string, id: number, update: SourceSyncUpdate, lease?: string): Promise<void> {
    const now = this.now();
    const s = this.owned(userId, id);
    if (lease !== undefined && !this.holds(userId, id, lease, now)) throw new IcsLeaseLostError();
    if (!s) return;
    s.lastSyncAt = update.lastSyncAt;
    s.lastStatus = update.lastStatus;
    s.lastStats = update.lastStats;
    s.updatedAt = now;
  }

  async acquireLease(userId: string, id: number, token: string, nowMs: number, ttlMs: number): Promise<boolean> {
    const s = this.owned(userId, id);
    const current = this.leases.get(id);
    if (!s || !s.enabled || (current && current.until > nowMs)) return false;
    this.leases.set(id, { token, until: nowMs + ttlMs });
    return true;
  }

  async renewLease(userId: string, id: number, token: string, nowMs: number, ttlMs: number): Promise<boolean> {
    if (!this.holds(userId, id, token, nowMs)) return false;
    this.leases.get(id)!.until = nowMs + ttlMs;
    return true;
  }

  async releaseLease(userId: string, id: number, token: string): Promise<void> {
    if (this.owned(userId, id) && this.leases.get(id)?.token === token) this.leases.delete(id);
  }

  async dueSources(nowMs: number, limit: number): Promise<IcsSource[]> {
    return [...this.sources.values()]
      .filter(
        (s) =>
          s.enabled &&
          (s.lastSyncAt === null || s.lastSyncAt + s.syncIntervalSec * 1000 <= nowMs + DUE_SLACK_MS),
      )
      .sort((a, b) => (a.lastSyncAt ?? 0) - (b.lastSyncAt ?? 0) || a.id - b.id)
      .slice(0, limit)
      .map((s) => structuredClone(s));
  }

  async getMapping(userId: string, sourceId: number, key: MappingKey): Promise<IcsMapping | null> {
    if (!this.owned(userId, sourceId)) return null;
    const m = this.mappings.get(mappingKeyOf(sourceId, key));
    return m ? { ...m } : null;
  }

  async listMappings(userId: string, sourceId: number): Promise<IcsMapping[]> {
    if (!this.owned(userId, sourceId)) return [];
    return [...this.mappings.values()]
      .filter((m) => m.sourceId === sourceId)
      .sort((a, b) => compareText(a.icsUid, b.icsUid) || compareText(a.occurrenceId, b.occurrenceId))
      .map((m) => ({ ...m }));
  }

  async countMappings(userId: string, sourceId: number): Promise<number> {
    return (await this.listMappings(userId, sourceId)).length;
  }

  async reserveMappings(
    userId: string,
    sourceId: number,
    lease: string,
    items: NewMapping[],
  ): Promise<IcsMapping[]> {
    if (items.length === 0) return [];
    const now = this.now();
    if (!(await this.renewLease(userId, sourceId, lease, now, LEASE_TTL_MS))) throw new IcsLeaseLostError();
    return items.map((m) => {
      const key = mappingKeyOf(sourceId, m);
      if (!this.mappings.has(key)) {
        this.mappings.set(key, {
          sourceId,
          icsUid: m.icsUid,
          occurrenceId: m.occurrenceId,
          taskId: m.taskId,
          projectId: m.projectId,
          fingerprint: null,
          sequence: m.sequence,
          dtstamp: m.dtstamp,
          state: 'pending',
          seriesSignature: m.seriesSignature,
          lastError: null,
          updatedAt: now,
        });
      }
      return { ...this.mappings.get(key)! };
    });
  }

  async markUpdating(userId: string, sourceId: number, lease: string, items: MappingStart[]): Promise<void> {
    this.update(userId, sourceId, lease, items, false, (m, now) => ({
      sequence: m.sequence,
      dtstamp: m.dtstamp,
      state: 'updating',
      updatedAt: now,
    }));
  }

  async commitMappings(userId: string, sourceId: number, lease: string, items: MappingCommit[]): Promise<void> {
    this.update(userId, sourceId, lease, items, false, (m, now) => ({
      fingerprint: m.fingerprint,
      sequence: m.sequence,
      dtstamp: m.dtstamp,
      state: m.state,
      seriesSignature: m.seriesSignature,
      lastError: m.lastError,
      updatedAt: now,
    }));
  }

  async markPurged(userId: string, sourceId: number, lease: string, items: MappingPurge[]): Promise<void> {
    this.update(userId, sourceId, lease, items, true, (m, now) => ({
      state: 'purged',
      ...(m.lastError === undefined ? {} : { lastError: m.lastError }),
      updatedAt: now,
    }));
  }

  async deleteMapping(userId: string, sourceId: number, lease: string, key: MappingKey): Promise<void> {
    if (!this.holds(userId, sourceId, lease, this.now())) throw new IcsLeaseLostError();
    this.mappings.delete(mappingKeyOf(sourceId, key));
  }

  private update<T extends MappingKey & { taskId: string }>(
    userId: string,
    sourceId: number,
    lease: string,
    items: T[],
    allowPurged: boolean,
    set: (item: T, now: number) => Partial<IcsMapping>,
  ): void {
    if (items.length === 0) return;
    const now = this.now();
    if (!this.holds(userId, sourceId, lease, now)) throw new IcsLeaseLostError();
    let conflict = false;
    for (const item of items) {
      const row = this.mappings.get(mappingKeyOf(sourceId, item));
      if (!row || row.taskId !== item.taskId || (!allowPurged && row.state === 'purged')) {
        conflict = true;
        continue;
      }
      Object.assign(row, set(item, now));
    }
    if (conflict) throw new IcsMappingConflictError();
  }
}
