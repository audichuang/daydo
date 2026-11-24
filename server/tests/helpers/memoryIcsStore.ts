import { systemNow } from '../../src/clock';
import {
  checkInterval,
  DUE_SLACK_MS,
  IcsLeaseLostError,
  IcsMappingConflictError,
  LEASE_TTL_MS,
  mappingKeyOf,
  MAX_SOURCES_PER_USER,
  sourceLimitError,
  type AddSourceInput,
  type IcsMapping,
  type IcsSource,
  type IcsStore,
  type MappingCommit,
  type MappingKey,
  type MappingPurge,
  type MappingStart,
  type NewMapping,
  type SourceSyncUpdate,
} from '../../src/ics/store';
import type { IcsFilter } from '../../src/ics/types';

const compareText = (a: string, b: string) => (a < b ? -1 : a > b ? 1 : 0);

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
