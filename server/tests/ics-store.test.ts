import { beforeEach, describe, expect, it, vi } from 'vitest';
import {
  D1IcsStore,
  IcsLeaseLostError,
  IcsMappingConflictError,
  LEASE_TTL_MS,
  MAX_SOURCES_PER_USER,
  MemoryIcsStore,
  type IcsStore,
  type MappingCommit,
  type NewMapping,
} from '../src/ics/store';
import { IcsError } from '../src/ics/types';
import { createTestD1 } from './sqliteD1';

const A = 'user-a';
const B = 'user-b';
const T0 = 1_700_000_000_000;

interface Harness {
  store: IcsStore;
  clock: { t: number };
  /** D1 only: direct access for assertions the store API cannot make. */
  d1?: ReturnType<typeof createTestD1>;
}

const factories: Array<[string, () => Harness]> = [
  [
    'D1IcsStore',
    () => {
      const d1 = createTestD1();
      const clock = { t: T0 };
      return { store: new D1IcsStore(d1.db, { now: () => clock.t }), clock, d1 };
    },
  ],
  [
    'MemoryIcsStore',
    () => {
      const clock = { t: T0 };
      return { store: new MemoryIcsStore({ now: () => clock.t }), clock };
    },
  ],
];

const newMapping = (uid: string, taskId: string, occurrenceId = ''): NewMapping => ({
  icsUid: uid,
  occurrenceId,
  taskId,
  projectId: 'proj',
  sequence: 0,
  dtstamp: null,
  seriesSignature: null,
});

const commit = (uid: string, taskId: string, over: Partial<MappingCommit> = {}): MappingCommit => ({
  icsUid: uid,
  occurrenceId: '',
  taskId,
  fingerprint: 'fp',
  sequence: 1,
  dtstamp: '2026-01-01T00:00:00Z',
  state: 'applied',
  seriesSignature: null,
  lastError: null,
  ...over,
});

describe.each(factories)('%s', (_name, make) => {
  let h: Harness;
  let store: IcsStore;
  beforeEach(() => {
    h = make();
    store = h.store;
  });

  const source = (userId = A, name = 'Cal') =>
    store.addSource(userId, { name, url: `https://cal.example.com/${name}.ics`, projectId: 'proj' });

  /** A source with a live lease held by `token`. */
  async function leased(userId = A, token = 'lease-1') {
    const s = await source(userId);
    expect(await store.acquireLease(userId, s.id, token, h.clock.t, LEASE_TTL_MS)).toBe(true);
    return s;
  }

  /** Lets `token` expire and another run take the source over. */
  async function takeOver(userId: string, id: number, takerToken = 'lease-2') {
    h.clock.t += LEASE_TTL_MS + 1;
    expect(await store.acquireLease(userId, id, takerToken, h.clock.t, LEASE_TTL_MS)).toBe(true);
  }

  describe('sources', () => {
    it('adds with defaults and round-trips filter and timezone', async () => {
      const plain = await source();
      expect(plain).toMatchObject({
        userId: A,
        enabled: true,
        syncIntervalSec: 900,
        filter: null,
        timezone: null,
        lastSyncAt: null,
        lastStatus: null,
        lastStats: null,
        createdAt: T0,
        updatedAt: T0,
      });
      const filter = { futureDays: 30, pastDays: 7, excludeKeywords: ['lunch'] };
      const rich = await store.addSource(A, {
        name: 'Rich',
        url: 'https://x.example.com/r.ics',
        projectId: 'p2',
        syncIntervalSec: 600,
        filter,
        timezone: 'Europe/Berlin',
      });
      expect(rich.id).toBeGreaterThan(plain.id);
      expect(rich).toMatchObject({ syncIntervalSec: 600, filter, timezone: 'Europe/Berlin', projectId: 'p2' });
      expect(await store.getSource(A, rich.id)).toEqual(rich);
      expect((await store.listSources(A)).map((s) => s.id)).toEqual([plain.id, rich.id]);
    });

    it('rejects an interval under 300 seconds and accepts exactly 300', async () => {
      const input = { name: 'n', url: 'https://x.example.com/a.ics', projectId: 'p' };
      for (const syncIntervalSec of [299, 0, -5, 300.5]) {
        await expect(store.addSource(A, { ...input, syncIntervalSec })).rejects.toThrow(IcsError);
      }
      expect((await store.addSource(A, { ...input, syncIntervalSec: 300 })).syncIntervalSec).toBe(300);
      expect(await store.listSources(A)).toHaveLength(1);
    });

    it('allows 10 sources per user, the 11th is rejected, other users are unaffected', async () => {
      expect(MAX_SOURCES_PER_USER).toBe(10);
      const ids: number[] = [];
      for (let i = 0; i < 10; i++) ids.push((await source(A, `s${i}`)).id);
      await expect(source(A, 's10')).rejects.toThrow(/At most 10/);
      expect(await store.listSources(A)).toHaveLength(10);
      expect((await source(B, 'other')).userId).toBe(B);
      await store.removeSource(A, ids[0]!);
      expect((await source(A, 's11')).userId).toBe(A);
    });

    it('removes the source and its mappings in one go', async () => {
      const s = await leased();
      await store.reserveMappings(A, s.id, 'lease-1', [newMapping('u1', 't1'), newMapping('u2', 't2')]);
      const keep = await leased(B, 'lease-b');
      await store.reserveMappings(B, keep.id, 'lease-b', [newMapping('u1', 'tb')]);
      expect(await store.removeSource(A, s.id)).toBe(true);
      expect(await store.getSource(A, s.id)).toBeNull();
      expect(await store.listMappings(A, s.id)).toEqual([]);
      expect(await store.countMappings(A, s.id)).toBe(0);
      expect(await store.removeSource(A, s.id)).toBe(false);
      expect(await store.countMappings(B, keep.id)).toBe(1);
    });

    it('removeSource uses one db.batch (D1)', async () => {
      if (!h.d1) return;
      const s = await leased();
      await store.reserveMappings(A, s.id, 'lease-1', [newMapping('u1', 't1')]);
      const batch = vi.spyOn(h.d1.db, 'batch');
      await store.removeSource(A, s.id);
      expect(batch).toHaveBeenCalledTimes(1);
      expect(h.d1.sqlite.prepare('SELECT count(*) AS n FROM icsMapping').get()).toEqual({ n: 0 });
    });

    it('setSourceSync records the run; with a lease it requires that lease', async () => {
      const s = await leased();
      await store.setSourceSync(
        A,
        s.id,
        { lastSyncAt: T0 + 5, lastStatus: 'success', lastStats: '{"created":1}' },
        'lease-1',
      );
      expect(await store.getSource(A, s.id)).toMatchObject({
        lastSyncAt: T0 + 5,
        lastStatus: 'success',
        lastStats: '{"created":1}',
      });
      await takeOver(A, s.id);
      await expect(
        store.setSourceSync(A, s.id, { lastSyncAt: T0 + 9, lastStatus: 'error', lastStats: '{}' }, 'lease-1'),
      ).rejects.toThrow(IcsLeaseLostError);
      expect((await store.getSource(A, s.id))?.lastSyncAt).toBe(T0 + 5);
      // Without a lease (the lease was never taken) the update still lands.
      const other = await source(A, 'other');
      await store.setSourceSync(A, other.id, { lastSyncAt: 1, lastStatus: 'error', lastStats: '{}' });
      expect((await store.getSource(A, other.id))?.lastStatus).toBe('error');
    });
  });

  describe('leases', () => {
    it('is exclusive until it expires, then another token takes over', async () => {
      const s = await source();
      expect(await store.acquireLease(A, s.id, 'one', T0, 100)).toBe(true);
      expect(await store.acquireLease(A, s.id, 'two', T0 + 50, 100)).toBe(false);
      expect(await store.acquireLease(A, s.id, 'two', T0 + 100, 100)).toBe(true);
      expect(await store.renewLease(A, s.id, 'one', T0 + 101, 100)).toBe(false);
      expect(await store.renewLease(A, s.id, 'two', T0 + 101, 100)).toBe(true);
    });

    it('cannot renew an expired lease or with the wrong token', async () => {
      const s = await source();
      await store.acquireLease(A, s.id, 'one', T0, 100);
      expect(await store.renewLease(A, s.id, 'wrong', T0 + 10, 100)).toBe(false);
      expect(await store.renewLease(A, s.id, 'one', T0 + 100, 100)).toBe(false);
    });

    it('is released only by its owner', async () => {
      const s = await source();
      await store.acquireLease(A, s.id, 'one', T0, 1000);
      await store.releaseLease(A, s.id, 'intruder');
      expect(await store.acquireLease(A, s.id, 'two', T0 + 1, 1000)).toBe(false);
      await store.releaseLease(A, s.id, 'one');
      expect(await store.acquireLease(A, s.id, 'two', T0 + 2, 1000)).toBe(true);
    });
  });

  describe('mappings', () => {
    it('reserveMappings inserts pending rows and returns existing ones unchanged', async () => {
      const s = await leased();
      const first = await store.reserveMappings(A, s.id, 'lease-1', [
        newMapping('u1', 'task-1'),
        newMapping('u2', 'task-2', 'slot'),
      ]);
      expect(first.map((m) => [m.icsUid, m.occurrenceId, m.taskId, m.state])).toEqual([
        ['u1', '', 'task-1', 'pending'],
        ['u2', 'slot', 'task-2', 'pending'],
      ]);
      expect(first[0]).toMatchObject({ fingerprint: null, lastError: null, projectId: 'proj', sequence: 0 });
      const again = await store.reserveMappings(A, s.id, 'lease-1', [
        newMapping('u2', 'other-id', 'slot'),
        newMapping('u3', 'task-3'),
        newMapping('u1', 'other-id-2'),
      ]);
      expect(again.map((m) => m.taskId)).toEqual(['task-2', 'task-3', 'task-1']);
      expect(await store.countMappings(A, s.id)).toBe(3);
      expect(await store.reserveMappings(A, s.id, 'lease-1', [])).toEqual([]);
    });

    it('reserveMappings voids the batch when the lease is gone', async () => {
      const s = await leased();
      await takeOver(A, s.id);
      await expect(store.reserveMappings(A, s.id, 'lease-1', [newMapping('u1', 't1')])).rejects.toThrow(
        IcsLeaseLostError,
      );
      await expect(store.reserveMappings(A, s.id, 'never', [newMapping('u1', 't1')])).rejects.toThrow(
        IcsLeaseLostError,
      );
      expect(await store.listMappings(A, s.id)).toEqual([]);
    });

    it('reserveMappings returns a purged row as it is', async () => {
      const s = await leased();
      await store.reserveMappings(A, s.id, 'lease-1', [newMapping('u1', 't1')]);
      await store.markPurged(A, s.id, 'lease-1', [{ icsUid: 'u1', occurrenceId: '', taskId: 't1' }]);
      const [again] = await store.reserveMappings(A, s.id, 'lease-1', [newMapping('u1', 'fresh')]);
      expect(again).toMatchObject({ taskId: 't1', state: 'purged' });
    });

    it('markUpdating sets sequence, dtstamp and state but keeps the old fingerprint', async () => {
      const s = await leased();
      await store.reserveMappings(A, s.id, 'lease-1', [newMapping('u1', 't1')]);
      await store.commitMappings(A, s.id, 'lease-1', [commit('u1', 't1')]);
      await store.markUpdating(A, s.id, 'lease-1', [
        { icsUid: 'u1', occurrenceId: '', taskId: 't1', sequence: 4, dtstamp: '2026-02-01T00:00:00Z' },
      ]);
      expect(await store.getMapping(A, s.id, { icsUid: 'u1', occurrenceId: '' })).toMatchObject({
        state: 'updating',
        sequence: 4,
        dtstamp: '2026-02-01T00:00:00Z',
        fingerprint: 'fp',
      });
    });

    it('commitMappings stores fingerprint, state and lastError', async () => {
      const s = await leased();
      await store.reserveMappings(A, s.id, 'lease-1', [newMapping('u1', 't1'), newMapping('u2', 't2')]);
      await store.commitMappings(A, s.id, 'lease-1', [
        commit('u1', 't1', { fingerprint: 'abc', sequence: 2, seriesSignature: '["RRULE:FREQ=DAILY"]' }),
        commit('u2', 't2', { state: 'cancelled', lastError: 'boom' }),
      ]);
      expect(await store.getMapping(A, s.id, { icsUid: 'u1', occurrenceId: '' })).toMatchObject({
        state: 'applied',
        fingerprint: 'abc',
        sequence: 2,
        seriesSignature: '["RRULE:FREQ=DAILY"]',
        lastError: null,
      });
      expect(await store.getMapping(A, s.id, { icsUid: 'u2', occurrenceId: '' })).toMatchObject({
        state: 'cancelled',
        lastError: 'boom',
      });
    });

    it('an expired lease voids every statement of the batch', async () => {
      const s = await leased();
      await store.reserveMappings(A, s.id, 'lease-1', [newMapping('u1', 't1'), newMapping('u2', 't2')]);
      await takeOver(A, s.id);
      await expect(
        store.markUpdating(A, s.id, 'lease-1', [
          { icsUid: 'u1', occurrenceId: '', taskId: 't1', sequence: 9, dtstamp: null },
          { icsUid: 'u2', occurrenceId: '', taskId: 't2', sequence: 9, dtstamp: null },
        ]),
      ).rejects.toThrow(IcsLeaseLostError);
      await expect(
        store.commitMappings(A, s.id, 'lease-1', [commit('u1', 't1'), commit('u2', 't2')]),
      ).rejects.toThrow(IcsLeaseLostError);
      await expect(
        store.markPurged(A, s.id, 'lease-1', [{ icsUid: 'u1', occurrenceId: '', taskId: 't1' }]),
      ).rejects.toThrow(IcsLeaseLostError);
      await expect(store.deleteMapping(A, s.id, 'lease-1', { icsUid: 'u1', occurrenceId: '' })).rejects.toThrow(
        IcsLeaseLostError,
      );
      for (const m of await store.listMappings(A, s.id)) {
        expect(m).toMatchObject({ state: 'pending', sequence: 0, fingerprint: null });
      }
      expect(await store.countMappings(A, s.id)).toBe(2);
    });

    it('rejects a write whose taskId differs from the reserved one', async () => {
      const s = await leased();
      await store.reserveMappings(A, s.id, 'lease-1', [newMapping('u1', 't1')]);
      await expect(store.commitMappings(A, s.id, 'lease-1', [commit('u1', 'other')])).rejects.toThrow(
        IcsMappingConflictError,
      );
      await expect(
        store.markUpdating(A, s.id, 'lease-1', [
          { icsUid: 'u1', occurrenceId: '', taskId: 'other', sequence: 3, dtstamp: null },
        ]),
      ).rejects.toThrow(IcsMappingConflictError);
      await expect(
        store.markPurged(A, s.id, 'lease-1', [{ icsUid: 'u1', occurrenceId: '', taskId: 'other' }]),
      ).rejects.toThrow(IcsMappingConflictError);
      expect(await store.getMapping(A, s.id, { icsUid: 'u1', occurrenceId: '' })).toMatchObject({
        taskId: 't1',
        state: 'pending',
        sequence: 0,
      });
    });

    it('rejects a write to a mapping that was never reserved', async () => {
      const s = await leased();
      await expect(store.commitMappings(A, s.id, 'lease-1', [commit('ghost', 't1')])).rejects.toThrow(
        IcsMappingConflictError,
      );
      expect(await store.listMappings(A, s.id)).toEqual([]);
    });

    it('applies matching items of a batch and reports the conflicting one', async () => {
      const s = await leased();
      await store.reserveMappings(A, s.id, 'lease-1', [newMapping('u1', 't1'), newMapping('u2', 't2')]);
      await expect(
        store.commitMappings(A, s.id, 'lease-1', [commit('u1', 't1'), commit('u2', 'wrong')]),
      ).rejects.toThrow(IcsMappingConflictError);
      expect((await store.getMapping(A, s.id, { icsUid: 'u1', occurrenceId: '' }))?.state).toBe('applied');
      expect((await store.getMapping(A, s.id, { icsUid: 'u2', occurrenceId: '' }))?.state).toBe('pending');
    });

    it('purged is terminal: no later update, commit or reservation changes it', async () => {
      const s = await leased();
      await store.reserveMappings(A, s.id, 'lease-1', [newMapping('u1', 't1')]);
      await store.markPurged(A, s.id, 'lease-1', [
        { icsUid: 'u1', occurrenceId: '', taskId: 't1', lastError: 'Project is purged' },
      ]);
      const key = { icsUid: 'u1', occurrenceId: '' };
      expect(await store.getMapping(A, s.id, key)).toMatchObject({ state: 'purged', lastError: 'Project is purged' });
      await expect(store.commitMappings(A, s.id, 'lease-1', [commit('u1', 't1')])).rejects.toThrow(
        IcsMappingConflictError,
      );
      await expect(
        store.markUpdating(A, s.id, 'lease-1', [
          { icsUid: 'u1', occurrenceId: '', taskId: 't1', sequence: 8, dtstamp: null },
        ]),
      ).rejects.toThrow(IcsMappingConflictError);
      expect(await store.getMapping(A, s.id, key)).toMatchObject({ state: 'purged', sequence: 0, fingerprint: null });
      // Idempotent, and keeps the recorded error when none is given.
      await store.markPurged(A, s.id, 'lease-1', [{ icsUid: 'u1', occurrenceId: '', taskId: 't1' }]);
      expect(await store.getMapping(A, s.id, key)).toMatchObject({ state: 'purged', lastError: 'Project is purged' });
    });

    it('deleteMapping removes one mapping while the lease holds', async () => {
      const s = await leased();
      await store.reserveMappings(A, s.id, 'lease-1', [newMapping('u1', 't1'), newMapping('u1', 't2', 'slot')]);
      await store.deleteMapping(A, s.id, 'lease-1', { icsUid: 'u1', occurrenceId: '' });
      expect((await store.listMappings(A, s.id)).map((m) => m.occurrenceId)).toEqual(['slot']);
    });

    it('deleteMapping of a mapping that is already gone is not an error while the lease holds', async () => {
      const s = await leased();
      await store.deleteMapping(A, s.id, 'lease-1', { icsUid: 'ghost', occurrenceId: '' });
      await takeOver(A, s.id);
      await expect(store.deleteMapping(A, s.id, 'lease-1', { icsUid: 'ghost', occurrenceId: '' })).rejects.toThrow(
        IcsLeaseLostError,
      );
    });

    it('keeps separate rows per occurrence of the same uid', async () => {
      const s = await leased();
      await store.reserveMappings(A, s.id, 'lease-1', [
        newMapping('series', 't1', 'slot-a'),
        newMapping('series', 't2', 'slot-b'),
      ]);
      expect((await store.listMappings(A, s.id)).map((m) => [m.occurrenceId, m.taskId])).toEqual([
        ['slot-a', 't1'],
        ['slot-b', 't2'],
      ]);
    });
  });

  describe('user isolation', () => {
    it("never reads or changes another user's source or mappings", async () => {
      const s = await leased(A, 'lease-a');
      await store.reserveMappings(A, s.id, 'lease-a', [newMapping('u1', 't1')]);
      await store.setSourceSync(A, s.id, { lastSyncAt: 1, lastStatus: 'success', lastStats: '{}' }, 'lease-a');
      const key = { icsUid: 'u1', occurrenceId: '' };
      const before = await store.getMapping(A, s.id, key);

      expect(await store.getSource(B, s.id)).toBeNull();
      expect(await store.listSources(B)).toEqual([]);
      expect(await store.getMapping(B, s.id, key)).toBeNull();
      expect(await store.listMappings(B, s.id)).toEqual([]);
      expect(await store.countMappings(B, s.id)).toBe(0);
      expect(await store.removeSource(B, s.id)).toBe(false);
      expect(await store.acquireLease(B, s.id, 'steal', h.clock.t + LEASE_TTL_MS + 1, LEASE_TTL_MS)).toBe(false);
      expect(await store.renewLease(B, s.id, 'lease-a', h.clock.t, LEASE_TTL_MS)).toBe(false);
      await store.releaseLease(B, s.id, 'lease-a');
      await expect(
        store.setSourceSync(B, s.id, { lastSyncAt: 2, lastStatus: 'error', lastStats: '{}' }, 'lease-a'),
      ).rejects.toThrow(IcsLeaseLostError);
      await expect(store.reserveMappings(B, s.id, 'lease-a', [newMapping('x', 'tx')])).rejects.toThrow(
        IcsLeaseLostError,
      );
      await expect(store.commitMappings(B, s.id, 'lease-a', [commit('u1', 't1', { state: 'cancelled' })])).rejects.toThrow(
        IcsLeaseLostError,
      );
      await expect(
        store.markUpdating(B, s.id, 'lease-a', [
          { icsUid: 'u1', occurrenceId: '', taskId: 't1', sequence: 7, dtstamp: null },
        ]),
      ).rejects.toThrow(IcsLeaseLostError);
      await expect(
        store.markPurged(B, s.id, 'lease-a', [{ icsUid: 'u1', occurrenceId: '', taskId: 't1' }]),
      ).rejects.toThrow(IcsLeaseLostError);
      await expect(store.deleteMapping(B, s.id, 'lease-a', key)).rejects.toThrow(IcsLeaseLostError);

      expect(await store.getMapping(A, s.id, key)).toEqual(before);
      expect(await store.getSource(A, s.id)).toMatchObject({ lastStatus: 'success', lastSyncAt: 1 });
      // A still holds its lease.
      expect(await store.renewLease(A, s.id, 'lease-a', h.clock.t, LEASE_TTL_MS)).toBe(true);
    });
  });

  describe('dueSources', () => {
    const sync = (userId: string, id: number, lastSyncAt: number) =>
      store.setSourceSync(userId, id, { lastSyncAt, lastStatus: 'success', lastStats: '{}' });

    it('crosses users, returns userId, and excludes sources that are not due yet', async () => {
      const fresh = await source(A, 'fresh');
      const stale = await store.addSource(B, { name: 's', url: 'https://x.example.com/s', projectId: 'p', syncIntervalSec: 3600 });
      await sync(B, stale.id, T0 - 2 * 3600 * 1000);
      const recent = await store.addSource(A, { name: 'r', url: 'https://x.example.com/r', projectId: 'p', syncIntervalSec: 3600 });
      await sync(A, recent.id, T0 - 60 * 1000);
      const due = await store.dueSources(T0, 10);
      expect(due.map((s) => [s.id, s.userId])).toEqual([
        [fresh.id, A],
        [stale.id, B],
      ]);
    });

    it('treats a source as due 15 seconds early and not 16', async () => {
      const s = await source();
      await sync(A, s.id, T0);
      const dueAt = T0 + 900 * 1000;
      expect((await store.dueSources(dueAt - 15_000, 10)).map((x) => x.id)).toEqual([s.id]);
      expect(await store.dueSources(dueAt - 15_001, 10)).toEqual([]);
    });

    it('orders never-synced first, then longest waiting, and honours the limit', async () => {
      const ids: number[] = [];
      for (let i = 0; i < 4; i++) ids.push((await source(A, `s${i}`)).id);
      // s0 synced most recently, s1 longest ago, s2 in between, s3 never.
      await sync(A, ids[0]!, T0 - 1_000_000);
      await sync(A, ids[1]!, T0 - 9_000_000);
      await sync(A, ids[2]!, T0 - 5_000_000);
      expect((await store.dueSources(T0, 10)).map((s) => s.id)).toEqual([ids[3], ids[1], ids[2], ids[0]]);
      expect((await store.dueSources(T0, 2)).map((s) => s.id)).toEqual([ids[3], ids[1]]);
    });

    it('does not starve later ids when the limit is smaller than the due set', async () => {
      const ids: number[] = [];
      for (let i = 0; i < 6; i++) ids.push((await source(A, `s${i}`)).id);
      const firstTick = await store.dueSources(T0, 5);
      expect(firstTick.map((s) => s.id)).toEqual(ids.slice(0, 5));
      for (const s of firstTick) await sync(A, s.id, T0);
      // Five minutes on, the sixth (never synced) goes before the five that are due again.
      const secondTick = await store.dueSources(T0 + 900_000, 5);
      expect(secondTick[0]!.id).toBe(ids[5]);
    });
  });
});

describe('D1IcsStore specifics', () => {
  it('does not acquire or list a disabled source as due', async () => {
    const d1 = createTestD1();
    const store = new D1IcsStore(d1.db, { now: () => T0 });
    const s = await store.addSource(A, { name: 'n', url: 'https://x.example.com/a', projectId: 'p' });
    d1.sqlite.prepare('UPDATE icsSource SET enabled = 0 WHERE id = ?').run(s.id);
    expect(await store.acquireLease(A, s.id, 'one', T0, 1000)).toBe(false);
    expect(await store.dueSources(T0, 10)).toEqual([]);
    expect((await store.getSource(A, s.id))?.enabled).toBe(false);
  });

  it('markUpdating and commitMappings each use one db.batch with a statement per mapping', async () => {
    const d1 = createTestD1();
    const store = new D1IcsStore(d1.db, { now: () => T0 });
    const s = await store.addSource(A, { name: 'n', url: 'https://x.example.com/a', projectId: 'p' });
    await store.acquireLease(A, s.id, 'one', T0, LEASE_TTL_MS);
    await store.reserveMappings(A, s.id, 'one', [newMapping('u1', 't1'), newMapping('u2', 't2'), newMapping('u3', 't3')]);

    const batch = vi.spyOn(d1.db, 'batch');
    await store.markUpdating(A, s.id, 'one', [
      { icsUid: 'u1', occurrenceId: '', taskId: 't1', sequence: 1, dtstamp: null },
      { icsUid: 'u2', occurrenceId: '', taskId: 't2', sequence: 1, dtstamp: null },
      { icsUid: 'u3', occurrenceId: '', taskId: 't3', sequence: 1, dtstamp: null },
    ]);
    expect(batch).toHaveBeenCalledTimes(1);
    expect(batch.mock.calls[0]![0]).toHaveLength(3);
    await store.commitMappings(A, s.id, 'one', [commit('u1', 't1'), commit('u2', 't2'), commit('u3', 't3')]);
    expect(batch).toHaveBeenCalledTimes(2);
    expect(batch.mock.calls[1]![0]).toHaveLength(3);
  });

  it('reserveMappings uses one db.batch and the stored rows follow the icsMapping columns', async () => {
    const d1 = createTestD1();
    const store = new D1IcsStore(d1.db, { now: () => T0 });
    const s = await store.addSource(A, { name: 'n', url: 'https://x.example.com/a', projectId: 'p' });
    await store.acquireLease(A, s.id, 'one', T0, LEASE_TTL_MS);
    const batch = vi.spyOn(d1.db, 'batch');
    await store.reserveMappings(A, s.id, 'one', [
      { icsUid: 'u1', occurrenceId: 'occ', taskId: 't1', projectId: 'proj', sequence: 3, dtstamp: 'd', seriesSignature: 'sig' },
      newMapping('u2', 't2'),
    ]);
    expect(batch).toHaveBeenCalledTimes(1);
    expect(d1.sqlite.prepare("SELECT * FROM icsMapping WHERE icsUid = 'u1'").get()).toEqual({
      sourceId: s.id,
      icsUid: 'u1',
      occurrenceId: 'occ',
      taskId: 't1',
      projectId: 'proj',
      fingerprint: null,
      sequence: 3,
      dtstamp: 'd',
      state: 'pending',
      seriesSignature: 'sig',
      lastError: null,
      updatedAt: T0,
    });
  });
});
