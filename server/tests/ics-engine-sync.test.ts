// M15a: ICS engine create and update paths (spec/mcp.md 9.3), against a real ScopeObject and the
// in-memory ICS store. Scenarios follow REF engine.test, rewritten for DayDo rows.
import { drizzle } from 'drizzle-orm/d1';
import { eq } from 'drizzle-orm';
import { describe, expect, it, vi } from 'vitest';
import * as schema from '../db/schema';
import { acceptInvite, createInvite, updateProjectMemberRole } from '../src/sharing';
import { createServerHlcClock } from '../src/sync/hlc';
import { executeSyncPush, type ScopeStub } from '../src/sync/push';
import { executeSyncPull } from '../src/sync/pull';
import { LEASE_TTL_MS, MemoryIcsStore, type IcsMapping } from '../src/ics/store';
import { NO_DATA_MESSAGE } from '../src/serverops/writer';
import { isGeneratedKeyValid } from '../src/domain/sortKey';
import { createTestD1, createTestDoState } from './sqliteD1';

vi.mock('cloudflare:workers', () => ({
  DurableObject: class {
    ctx: unknown;
    env: unknown;
    constructor(ctx: unknown, env: unknown) {
      this.ctx = ctx;
      this.env = env;
    }
  },
}));

vi.mock('void/durable', () => ({
  defineDurableObject: (def: unknown) => def,
}));

vi.mock('void/db', async () => {
  const orm = await import('drizzle-orm');
  return {
    ...orm,
    createDb: (d1: D1Database) => drizzle(d1, { schema }),
  };
});

const { default: Scope, ScopeObject } = await import('../durable-objects/scope');
const { syncSource } = await import('../src/ics/engine');

const NOW = Date.parse('2026-10-01T00:00:00Z');
const NOW_ISH = 1_700_000_000_000;
const FEED_URL = 'https://calendar.example/feed.ics';

const event = (extra: string[] = [], uid = 'meeting-a') =>
  ['BEGIN:VEVENT', `UID:${uid}`, 'SUMMARY:Meeting', 'DTSTART:20261002T010000Z', 'DTEND:20261002T020000Z', ...extra, 'END:VEVENT'].join('\r\n');
const calendar = (...events: string[]) => ['BEGIN:VCALENDAR', 'VERSION:2.0', ...events, 'END:VCALENDAR'].join('\r\n');

interface PushCall {
  scope: string;
  deviceId: string;
  ops: Array<Record<string, unknown>>;
}

function createHarness(initialFeed = calendar(event())) {
  const { db } = createTestD1();
  const scopes = new Map<string, InstanceType<typeof ScopeObject>>();
  const calls: PushCall[] = [];
  // One-shot hooks around the next ICS push reaching a scope.
  const hooks: {
    beforeIcsPush?: () => Promise<unknown>;
    /** Throw before the scope sees the ops (nothing applied). */
    failBeforeIcsPush?: boolean;
    /** Apply the ops, then lose the response. */
    loseIcsResponse?: boolean;
  } = {};
  const clock = createServerHlcClock();
  const getScopeStub = (scope: string): ScopeStub => {
    let instance = scopes.get(scope);
    if (!instance) {
      const doState = createTestDoState();
      const ScopeClass = Scope.class as unknown as new (
        ctx: DurableObjectState,
        env: { SYNC_FAULT: 'none' },
      ) => InstanceType<typeof ScopeObject>;
      instance = new ScopeClass(doState.ctx, { SYNC_FAULT: 'none' });
      scopes.set(scope, instance);
    }
    const stub = instance as unknown as ScopeStub;
    return new Proxy(stub, {
      get(target, prop, receiver) {
        if (prop === 'push') {
          return async (input: Parameters<ScopeStub['push']>[0]) => {
            if (input.deviceId === 'ics') {
              if (hooks.beforeIcsPush) {
                const hook = hooks.beforeIcsPush;
                hooks.beforeIcsPush = undefined;
                await hook();
              }
              if (hooks.failBeforeIcsPush) {
                hooks.failBeforeIcsPush = false;
                throw new Error('network down');
              }
            }
            calls.push({ scope: input.scope, deviceId: input.deviceId, ops: input.ops as Array<Record<string, unknown>> });
            const res = await target.push(input);
            if (input.deviceId === 'ics' && hooks.loseIcsResponse) {
              hooks.loseIcsResponse = false;
              throw new Error('response lost');
            }
            return res;
          };
        }
        const v = Reflect.get(target, prop, receiver) as unknown;
        return typeof v === 'function' ? (v as (...a: unknown[]) => unknown).bind(target) : v;
      },
    });
  };

  let feed = initialFeed;
  let feedStatus = 200;
  const fakeFetch = (async (url: string | URL | Request) => {
    expect(String(url)).toBe(FEED_URL);
    return new Response(feed, { status: feedStatus });
  }) as typeof fetch;

  const store = new MemoryIcsStore();
  let seq = 0;
  const deviceHlc = (ms = Date.now() - 60_000) => `${ms}:${String(seq++ % 10000).padStart(4, '0')}:dev-a`;
  const devicePush = (userId: string, ops: unknown[]) =>
    executeSyncPush(db, { userId, deviceId: 'dev-a', ops, getScopeStub, clock });
  const pull = (userId: string) => executeSyncPull(db, { userId, cursors: {}, limit: 1000, getScopeStub });
  const deps = { store, db, getScopeStub, clock, fetchOptions: { fetch: fakeFetch } };
  return {
    db,
    store,
    calls,
    hooks,
    deps,
    getScopeStub,
    deviceHlc,
    devicePush,
    pull,
    setFeed(value: string) {
      feed = value;
    },
    setFeedStatus(status: number) {
      feedStatus = status;
    },
    icsOps: () => calls.filter((c) => c.deviceId === 'ics').flatMap((c) => c.ops),
    icsPushes: () => calls.filter((c) => c.deviceId === 'ics').length,
  };
}

type Harness = ReturnType<typeof createHarness>;

function projectRow(id: string, extra: Record<string, unknown> = {}) {
  return {
    id, name: id, viewMode: 'list', kind: 'TASK', isInbox: false, ownerId: 'm-a',
    sortKey: 'a0', showInSmart: 'all', notifyMode: 'all', createdAt: NOW_ISH, updatedAt: NOW_ISH,
    ...extra,
  };
}

function deviceOp(h: Harness, entity: string, row: Record<string, unknown>, hlc = h.deviceHlc()) {
  return { opId: `dev-${entity}-${String(row.id)}-${hlc}`, hlc, entity, entityId: String(row.id), op: 'upsert', fields: Object.keys(row), row };
}

/** A device edit of some fields of an existing row, stamped after the server's last write by default. */
async function deviceEdit(h: Harness, userId: string, entity: string, id: string, set: Record<string, unknown>, hlc = h.deviceHlc(Date.now() + 1000)) {
  const res = await h.devicePush(userId, [{ ...deviceOp(h, entity, { id, ...set }, hlc), fields: Object.keys(set) }]);
  expect(res.results[0]?.status).toBe('applied');
  const row = res.results[0]?.row as Record<string, unknown>;
  for (const [k, v] of Object.entries(set)) expect(row[k], k).toEqual(v);
}

async function seedUser(h: Harness, userId: string, memberId: string | null, withInbox = true) {
  await h.db.insert(schema.user).values({
    id: userId, name: userId, initial: userId[0], color: '#007AFF', avatarUrl: null, createdAt: NOW_ISH,
  });
  if (memberId) await h.db.update(schema.user).set({ meMemberId: memberId }).where(eq(schema.user.id, userId));
  if (withInbox) {
    const res = await h.devicePush(userId, [
      deviceOp(h, 'project', projectRow(`inbox-${userId}`, { isInbox: true, ownerId: memberId ?? '' })),
    ]);
    expect(res.results[0]?.status).toBe('applied');
  }
}

/** u-a with inbox and list p1, plus an ICS source on p1. */
async function seedSource(h: Harness, extra: { timezone?: string; filter?: { excludeKeywords?: string[] } } = {}) {
  await seedUser(h, 'u-a', 'm-a');
  const res = await h.devicePush('u-a', [deviceOp(h, 'project', projectRow('p1'))]);
  expect(res.results[0]?.status).toBe('applied');
  return h.store.addSource('u-a', { name: 'Work', url: FEED_URL, projectId: 'p1', ...extra });
}

type PullRes = Awaited<ReturnType<Harness['pull']>>;

function pulledTasks(res: PullRes): Record<string, unknown>[] {
  const out: Record<string, unknown>[] = [];
  for (const s of res.scopes) {
    for (const r of s.rows) if (r.entity === 'task' && !('gone' in r)) out.push(r.row as Record<string, unknown>);
  }
  return out;
}

async function taskOf(h: Harness, userId: string, id: string) {
  return pulledTasks(await h.pull(userId)).find((t) => t.id === id);
}

const sync = (h: Harness, userId: string, sourceId: number, options = {}, now = NOW) =>
  syncSource(h.deps, userId, sourceId, now, options);

async function onlyMapping(h: Harness, sourceId: number): Promise<IcsMapping> {
  const all = await h.store.listMappings('u-a', sourceId);
  expect(all).toHaveLength(1);
  return all[0]!;
}

const ICS_OWNED = new Set(['title', 'content', 'startDay', 'startMinute', 'endDay', 'endMinute', 'timeZone', 'updatedAt']);

describe('M15a create', () => {
  it('creates full tasks in one push that another device pulls, then skips an unchanged feed', async () => {
    const h = createHarness(
      calendar(
        event(['DESCRIPTION:Agenda', 'LOCATION:Room 1', 'PRIORITY:1', 'CATEGORIES:Busy']),
        ['BEGIN:VEVENT', 'UID:offsite', 'SUMMARY:Offsite', 'DTSTART;VALUE=DATE:20261005', 'DTEND;VALUE=DATE:20261007', 'END:VEVENT'].join('\r\n'),
      ),
    );
    const source = await seedSource(h);
    const stats = await sync(h, 'u-a', source.id);
    expect(stats).toMatchObject({ created: 2, updated: 0, errors: 0 });
    expect(h.icsPushes()).toBe(1);

    const mappings = await h.store.listMappings('u-a', source.id);
    expect(mappings.map((m) => m.state)).toEqual(['applied', 'applied']);
    expect(mappings.every((m) => typeof m.fingerprint === 'string' && m.lastError === null)).toBe(true);
    const meeting = mappings.find((m) => m.icsUid === 'meeting-a')!;
    const offsite = mappings.find((m) => m.icsUid === 'offsite')!;
    expect(meeting.taskId).toMatch(/^[0-9a-f]{8}-[0-9a-f]{4}-7/);

    // A second device pulls both tasks with the full create row.
    const tasks = pulledTasks(await h.pull('u-a'));
    const m = tasks.find((t) => t.id === meeting.taskId)!;
    expect(m).toMatchObject({
      projectId: 'p1',
      title: 'Meeting',
      content: 'Agenda\n\n📍 Room 1',
      priority: 5,
      status: 0,
      startDay: '2026-10-02',
      startMinute: 540,
      endDay: '2026-10-02',
      endMinute: 600,
      timeZone: 'Asia/Taipei',
      reminders: ['TRIGGER:-PT15M'],
      tags: [],
      importNote: 'ICS：Work',
    });
    const o = tasks.find((t) => t.id === offsite.taskId)!;
    expect(o).toMatchObject({ title: 'Offsite', startDay: '2026-10-05', endDay: '2026-10-06', reminders: [], priority: 0 });
    expect(o.startMinute ?? null).toBeNull();
    const keys = [m.sortKey, o.sortKey] as string[];
    expect(new Set(keys).size).toBe(2);
    expect(keys.every(isGeneratedKeyValid)).toBe(true);
    // Feed order top to bottom.
    expect(keys[0]! < keys[1]!).toBe(true);

    const source2 = await h.store.getSource('u-a', source.id);
    expect(source2?.lastStatus).toBe('success');
    expect(source2?.lastSyncAt).toBe(NOW);

    // Unchanged feed: no scope write, no mapping write.
    const commit = vi.spyOn(h.store, 'commitMappings');
    const mark = vi.spyOn(h.store, 'markUpdating');
    expect(await sync(h, 'u-a', source.id)).toMatchObject({ created: 0, updated: 0, skipped: 2, errors: 0 });
    expect(h.icsPushes()).toBe(1);
    expect(commit).not.toHaveBeenCalled();
    expect(mark).not.toHaveBeenCalled();
  });

  it('records an event whose schedule cannot be built as an error and still imports the others', async () => {
    const bad = ['BEGIN:VEVENT', 'UID:zero-length', 'SUMMARY:Broken', 'DTSTART;VALUE=DATE:20261005', 'DTEND;VALUE=DATE:20261005', 'END:VEVENT'].join('\r\n');
    const h = createHarness(calendar(event(), bad));
    const source = await seedSource(h);
    const stats = await sync(h, 'u-a', source.id, { includeChanges: true });
    expect(stats).toMatchObject({ created: 1, errors: 1 });
    expect(stats.changes).toContainEqual(expect.objectContaining({ uid: 'zero-length', action: 'error' }));
    expect((await h.store.listMappings('u-a', source.id)).map((m) => m.icsUid)).toEqual(['meeting-a']);
    expect((await h.store.getSource('u-a', source.id))?.lastStatus).toBe('partial');
  });

  it('imports 31 meetings in a single push and orders new tasks before existing ones', async () => {
    const meetings = Array.from({ length: 31 }, (_, i) => event([], `meeting-${String(i).padStart(2, '0')}`));
    const h = createHarness(calendar(...meetings));
    const source = await seedSource(h);
    await h.devicePush('u-a', [
      deviceOp(h, 'task', {
        id: 't-old', projectId: 'p1', title: 'old', content: '', priority: 0, status: 0, sortKey: 'i',
        reminders: [], tags: [], createdAt: NOW_ISH, updatedAt: NOW_ISH,
      }),
    ]);
    expect(await sync(h, 'u-a', source.id)).toMatchObject({ created: 31, errors: 0 });
    expect(h.icsPushes()).toBe(1);
    const tasks = pulledTasks(await h.pull('u-a')).filter((t) => t.projectId === 'p1');
    expect(tasks).toHaveLength(32);
    const keys = tasks.filter((t) => t.id !== 't-old').map((t) => String(t.sortKey));
    expect(new Set(keys).size).toBe(31);
    expect(keys.every((k) => isGeneratedKeyValid(k) && k < 'i' && k.length <= 6)).toBe(true);
    expect(await sync(h, 'u-a', source.id)).toMatchObject({ created: 0, skipped: 31, errors: 0 });
  });

  it('keeps reservations after a push that never reached the scope and recreates with the same ids', async () => {
    const h = createHarness(calendar(event([], 'first'), event([], 'second')));
    const source = await seedSource(h);
    h.hooks.failBeforeIcsPush = true;
    const failed = await sync(h, 'u-a', source.id);
    expect(failed.errors).toBeGreaterThan(0);
    expect((await h.store.getSource('u-a', source.id))?.lastStatus).not.toBe('success');
    const reserved = await h.store.listMappings('u-a', source.id);
    expect(reserved).toHaveLength(2);
    expect(reserved.every((m) => m.state === 'pending' && m.fingerprint === null)).toBe(true);
    expect(pulledTasks(await h.pull('u-a'))).toHaveLength(0);

    expect(await sync(h, 'u-a', source.id)).toMatchObject({ created: 2, errors: 0 });
    const ids = pulledTasks(await h.pull('u-a')).map((t) => String(t.id)).sort();
    expect(ids).toEqual(reserved.map((m) => m.taskId).sort());
    expect((await h.store.listMappings('u-a', source.id)).every((m) => m.state === 'applied')).toBe(true);
  });

  it('recovers a lost create response without a second task or overwriting priority and tags edited since', async () => {
    const h = createHarness();
    const source = await seedSource(h);
    h.hooks.loseIcsResponse = true;
    expect(await sync(h, 'u-a', source.id)).toMatchObject({ errors: 1 });
    const pending = await onlyMapping(h, source.id);
    expect(pending).toMatchObject({ state: 'pending', fingerprint: null });
    expect(await taskOf(h, 'u-a', pending.taskId)).toBeDefined();

    // The user edits the task on the phone before the next run.
    await deviceEdit(h, 'u-a', 'task', pending.taskId, { priority: 3, tags: ['mine'], reminders: ['TRIGGER:-PT1H'] });
    const pushes = h.icsPushes();
    expect(await sync(h, 'u-a', source.id)).toMatchObject({ created: 0, errors: 0 });
    // The task already matches the feed: nothing is written.
    expect(h.icsPushes()).toBe(pushes);
    expect(await onlyMapping(h, source.id)).toMatchObject({ state: 'applied', taskId: pending.taskId });
    const tasks = pulledTasks(await h.pull('u-a'));
    expect(tasks).toHaveLength(1);
    expect(tasks[0]).toMatchObject({ priority: 3, tags: ['mine'], reminders: ['TRIGGER:-PT1H'] });
  });

  it('does not reopen a task completed after a lost create response while the feed is unchanged', async () => {
    const h = createHarness();
    const source = await seedSource(h);
    h.hooks.loseIcsResponse = true;
    await sync(h, 'u-a', source.id);
    const pending = await onlyMapping(h, source.id);
    await deviceEdit(h, 'u-a', 'task', pending.taskId, { status: 2, completedAt: NOW_ISH });
    const pushes = h.icsPushes();
    expect(await sync(h, 'u-a', source.id)).toMatchObject({ errors: 0 });
    expect(h.icsPushes()).toBe(pushes);
    expect(await taskOf(h, 'u-a', pending.taskId)).toMatchObject({ status: 2, completedAt: NOW_ISH });
    expect(await onlyMapping(h, source.id)).toMatchObject({ state: 'applied' });
  });

  it('after a lost create response, a changed feed sends only the fields ICS owns', async () => {
    const h = createHarness();
    const source = await seedSource(h);
    h.hooks.loseIcsResponse = true;
    await sync(h, 'u-a', source.id);
    const pending = await onlyMapping(h, source.id);
    await deviceEdit(h, 'u-a', 'task', pending.taskId, { priority: 3, tags: ['mine'] });

    h.setFeed(calendar(event(['DESCRIPTION:New agenda']).replace('SUMMARY:Meeting', 'SUMMARY:Renamed')));
    const before = h.icsOps().length;
    expect(await sync(h, 'u-a', source.id)).toMatchObject({ created: 0, updated: 1, errors: 0 });
    const ops = h.icsOps().slice(before);
    expect(ops).toHaveLength(1);
    expect((ops[0]!.fields as string[]).every((f) => ICS_OWNED.has(f))).toBe(true);
    expect(await taskOf(h, 'u-a', pending.taskId)).toMatchObject({
      title: 'Renamed', content: 'New agenda', priority: 3, tags: ['mine'], reminders: ['TRIGGER:-PT15M'],
    });
    expect(await onlyMapping(h, source.id)).toMatchObject({ state: 'applied' });
  });
});

describe('M15a update', () => {
  it('updates the same task when the event changes, sending only ICS-owned fields', async () => {
    const h = createHarness(calendar(event(['LAST-MODIFIED:20261001T000000Z'])));
    const source = await seedSource(h);
    await sync(h, 'u-a', source.id);
    const first = await onlyMapping(h, source.id);
    h.setFeed(
      calendar(
        event(['LAST-MODIFIED:20261001T000000Z'])
          .replace('SUMMARY:Meeting', 'SUMMARY:Rescheduled')
          .replace('20261002T010000Z', '20261002T030000Z')
          .replace('20261002T020000Z', '20261002T040000Z'),
      ),
    );
    const before = h.icsOps().length;
    expect(await sync(h, 'u-a', source.id)).toMatchObject({ updated: 1, created: 0, errors: 0 });
    const ops = h.icsOps().slice(before);
    expect(ops).toHaveLength(1);
    expect(ops[0]!.entityId).toBe(first.taskId);
    expect((ops[0]!.fields as string[]).every((f) => ICS_OWNED.has(f))).toBe(true);
    const tasks = pulledTasks(await h.pull('u-a'));
    expect(tasks).toHaveLength(1);
    expect(tasks[0]).toMatchObject({ title: 'Rescheduled', startMinute: 660, endMinute: 720 });
    const after = await onlyMapping(h, source.id);
    expect(after.state).toBe('applied');
    expect(after.fingerprint).not.toBe(first.fingerprint);
  });

  it('ignores a DTSTAMP-only change but persists a SEQUENCE bump without writing the task', async () => {
    const h = createHarness(calendar(event(['DTSTAMP:20261001T010000Z'])));
    const source = await seedSource(h);
    await sync(h, 'u-a', source.id);
    const commit = vi.spyOn(h.store, 'commitMappings');
    const pushes = h.icsPushes();
    h.setFeed(calendar(event(['DTSTAMP:20261001T020000Z'])));
    expect(await sync(h, 'u-a', source.id)).toMatchObject({ skipped: 1, errors: 0 });
    expect(commit).not.toHaveBeenCalled();
    h.setFeed(calendar(event(['SEQUENCE:1', 'DTSTAMP:20261001T030000Z'])));
    expect(await sync(h, 'u-a', source.id)).toMatchObject({ skipped: 1, errors: 0 });
    expect(commit).toHaveBeenCalledTimes(1);
    expect(await onlyMapping(h, source.id)).toMatchObject({ sequence: 1, state: 'applied' });
    expect(h.icsPushes()).toBe(pushes);
  });

  it('rejects an older source revision even when its content changed', async () => {
    const h = createHarness(calendar(event(['SEQUENCE:3', 'DTSTAMP:20261001T010000Z'])));
    const source = await seedSource(h);
    await sync(h, 'u-a', source.id);
    const pushes = h.icsPushes();
    h.setFeed(calendar(event(['SEQUENCE:2', 'DTSTAMP:20261001T020000Z']).replace('SUMMARY:Meeting', 'SUMMARY:Old meeting')));
    expect(await sync(h, 'u-a', source.id)).toMatchObject({ skipped: 1, errors: 0 });
    expect(h.icsPushes()).toBe(pushes);
    expect(pulledTasks(await h.pull('u-a'))[0]?.title).toBe('Meeting');
  });

  it('does not roll back a newer write whose response was lost when an older feed arrives', async () => {
    const h = createHarness(calendar(event(['SEQUENCE:3']).replace('SUMMARY:Meeting', 'SUMMARY:Latest')));
    const source = await seedSource(h);
    h.hooks.loseIcsResponse = true;
    expect(await sync(h, 'u-a', source.id)).toMatchObject({ errors: 1 });
    const pushes = h.icsPushes();
    h.setFeed(calendar(event(['SEQUENCE:2']).replace('SUMMARY:Meeting', 'SUMMARY:Stale')));
    expect(await sync(h, 'u-a', source.id)).toMatchObject({ skipped: 1, errors: 1 });
    expect(h.icsPushes()).toBe(pushes);
    expect(pulledTasks(await h.pull('u-a'))[0]?.title).toBe('Latest');
  });

  it('recovers a lost update response without repeating the write', async () => {
    const h = createHarness();
    const source = await seedSource(h);
    await sync(h, 'u-a', source.id);
    h.setFeed(calendar(event(['DESCRIPTION:Moved agenda'])));
    h.hooks.loseIcsResponse = true;
    expect(await sync(h, 'u-a', source.id)).toMatchObject({ errors: 1 });
    const updating = await onlyMapping(h, source.id);
    expect(updating.state).toBe('updating');
    const pushes = h.icsPushes();
    expect(await sync(h, 'u-a', source.id)).toMatchObject({ errors: 0, created: 0 });
    expect(h.icsPushes()).toBe(pushes);
    expect(await onlyMapping(h, source.id)).toMatchObject({ state: 'applied', taskId: updating.taskId });
    expect(pulledTasks(await h.pull('u-a'))).toHaveLength(1);
  });

  it('keeps the old fingerprint when a device edit wins LWW, and retries on the next run', async () => {
    const h = createHarness();
    const source = await seedSource(h);
    await sync(h, 'u-a', source.id);
    const applied = await onlyMapping(h, source.id);
    h.setFeed(calendar(event(['DESCRIPTION:Agenda']).replace('SUMMARY:Meeting', 'SUMMARY:From feed')));
    // The phone renames the task with a clock ahead of the server, after the snapshot was read.
    const lead = Date.now() + 3 * 60_000;
    h.hooks.beforeIcsPush = () => deviceEdit(h, 'u-a', 'task', applied.taskId, { title: 'From phone' }, `${lead}:0000:dev-a`);

    const lost = await sync(h, 'u-a', source.id, { includeChanges: true });
    expect(lost).toMatchObject({ updated: 0, errors: 1 });
    expect(lost.lastError).toContain('title');
    expect(lost.changes?.[0]).toMatchObject({ action: 'error', taskId: applied.taskId });
    const kept = await onlyMapping(h, source.id);
    expect(kept.fingerprint).toBe(applied.fingerprint);
    expect(kept.state).toBe('updating');
    expect(kept.lastError).toContain('title');
    expect(await taskOf(h, 'u-a', applied.taskId)).toMatchObject({ title: 'From phone', content: 'Agenda' });
    expect((await h.store.getSource('u-a', source.id))?.lastStatus).toBe('partial');

    // Next run: the server clock now beats the phone's and the feed title is restored.
    expect(await sync(h, 'u-a', source.id)).toMatchObject({ updated: 1, errors: 0 });
    expect(await taskOf(h, 'u-a', applied.taskId)).toMatchObject({ title: 'From feed', content: 'Agenda' });
    const done = await onlyMapping(h, source.id);
    expect(done.state).toBe('applied');
    expect(done.fingerprint).not.toBe(applied.fingerprint);
    expect(done.lastError).toBeNull();
  });

  it('updates a meeting moved beyond the import window without importing unrelated distant meetings', async () => {
    const h = createHarness();
    const source = await seedSource(h);
    await sync(h, 'u-a', source.id);
    const { taskId } = await onlyMapping(h, source.id);
    h.setFeed(calendar(event().replaceAll('20261002', '20270402'), event([], 'distant-new').replaceAll('20261002', '20270402')));
    expect(await sync(h, 'u-a', source.id)).toMatchObject({ updated: 1, created: 0, errors: 0 });
    const tasks = pulledTasks(await h.pull('u-a'));
    expect(tasks).toHaveLength(1);
    expect(tasks[0]).toMatchObject({ id: taskId, startDay: '2027-04-02' });
  });

  it('imports three occurrences and updates just the moved exception', async () => {
    const master = event(['RRULE:FREQ=WEEKLY;COUNT=3']);
    const h = createHarness(calendar(master));
    const source = await seedSource(h);
    expect(await sync(h, 'u-a', source.id)).toMatchObject({ created: 3, errors: 0 });
    const before = new Map(pulledTasks(await h.pull('u-a')).map((t) => [String(t.id), t]));
    const moved = (await h.store.listMappings('u-a', source.id)).find((m) => m.occurrenceId === 'UTC:2026-10-09T01:00:00Z')!;
    h.setFeed(calendar(event(['RECURRENCE-ID:20261009T010000Z', 'SEQUENCE:2']).replaceAll('20261002', '20261010'), master));
    expect(await sync(h, 'u-a', source.id)).toMatchObject({ updated: 1, skipped: 2, errors: 0 });
    const after = pulledTasks(await h.pull('u-a'));
    expect(after).toHaveLength(3);
    for (const t of after) {
      if (t.id === moved.taskId) expect(t.startDay).toBe('2026-10-10');
      else expect(t).toEqual(before.get(String(t.id)));
    }
  });

  it('keeps user edits and completion while the event is unchanged, reopens and restores owned fields when it changes', async () => {
    const h = createHarness(calendar(event(['DESCRIPTION:Source information', 'LOCATION:Source room'])));
    const source = await seedSource(h);
    await sync(h, 'u-a', source.id);
    const { taskId } = await onlyMapping(h, source.id);
    await deviceEdit(h, 'u-a', 'task', taskId, {
      title: 'Edited by hand', status: 2, completedAt: NOW_ISH, tags: ['mine'], priority: 5, reminders: ['TRIGGER:-PT30M'],
    });
    const pushes = h.icsPushes();
    expect(await sync(h, 'u-a', source.id)).toMatchObject({ skipped: 1, updated: 0, errors: 0 });
    expect(h.icsPushes()).toBe(pushes);
    expect(await taskOf(h, 'u-a', taskId)).toMatchObject({ title: 'Edited by hand', status: 2 });

    h.setFeed(calendar(event(['DESCRIPTION:Changed source information', 'LOCATION:Source room'])));
    expect(await sync(h, 'u-a', source.id)).toMatchObject({ updated: 1, errors: 0 });
    const t = await taskOf(h, 'u-a', taskId);
    expect(t).toMatchObject({
      title: 'Meeting', content: 'Changed source information\n\n📍 Source room', status: 0,
      tags: ['mine'], priority: 5, reminders: ['TRIGGER:-PT30M'],
    });
    expect(t?.completedAt ?? null).toBeNull();
    expect(await sync(h, 'u-a', source.id)).toMatchObject({ skipped: 1, updated: 0, errors: 0 });
  });

  it('updates a task in the trash and leaves it there', async () => {
    const h = createHarness();
    const source = await seedSource(h);
    await sync(h, 'u-a', source.id);
    const { taskId } = await onlyMapping(h, source.id);
    await deviceEdit(h, 'u-a', 'task', taskId, { deletedAt: NOW_ISH });
    h.setFeed(calendar(event().replace('SUMMARY:Meeting', 'SUMMARY:Moved')));
    const before = h.icsOps().length;
    expect(await sync(h, 'u-a', source.id)).toMatchObject({ updated: 1, errors: 0 });
    expect(h.icsOps().slice(before).some((op) => (op.fields as string[]).includes('deletedAt'))).toBe(false);
    expect(await taskOf(h, 'u-a', taskId)).toMatchObject({ title: 'Moved', deletedAt: NOW_ISH });
  });

  it('keeps a mapping whose task is not visible, records an error and does not recreate it', async () => {
    const h = createHarness();
    const source = await seedSource(h);
    const lease = 'test-lease';
    expect(await h.store.acquireLease('u-a', source.id, lease, Date.now(), LEASE_TTL_MS)).toBe(true);
    const [m] = await h.store.reserveMappings('u-a', source.id, lease, [
      { icsUid: 'meeting-a', occurrenceId: '', taskId: '01900000-0000-7000-8000-000000000001', projectId: 'p1', sequence: 0, dtstamp: null, seriesSignature: null },
    ]);
    await h.store.commitMappings('u-a', source.id, lease, [
      { ...m!, fingerprint: 'stale', state: 'applied', lastError: null },
    ]);
    await h.store.releaseLease('u-a', source.id, lease);

    const stats = await sync(h, 'u-a', source.id);
    expect(stats).toMatchObject({ created: 0, updated: 0, errors: 1 });
    expect(h.icsPushes()).toBe(0);
    const kept = await onlyMapping(h, source.id);
    expect(kept).toMatchObject({ state: 'applied', fingerprint: 'stale', taskId: m!.taskId });
    expect(kept.lastError).toMatch(/missing/i);
  });
});

describe('M15a run control', () => {
  it('previews creates and updates without any store or scope writes', async () => {
    const h = createHarness();
    const source = await seedSource(h);
    const preview = await sync(h, 'u-a', source.id, { dryRun: true });
    expect(preview).toMatchObject({ dryRun: true, created: 1, errors: 0 });
    expect(preview.changes?.[0]).toMatchObject({ action: 'create', uid: 'meeting-a', summary: 'Meeting' });
    expect(h.icsPushes()).toBe(0);
    expect(await h.store.listMappings('u-a', source.id)).toEqual([]);
    expect((await h.store.getSource('u-a', source.id))?.lastSyncAt).toBeNull();

    await sync(h, 'u-a', source.id);
    const mapping = await onlyMapping(h, source.id);
    const pushes = h.icsPushes();
    h.setFeed(calendar(event().replace('20261002T010000Z', '20261002T013000Z')));
    const update = await sync(h, 'u-a', source.id, { dryRun: true });
    expect(update).toMatchObject({ dryRun: true, updated: 1, errors: 0 });
    expect(update.changes?.[0]).toMatchObject({
      action: 'update', taskId: mapping.taskId, previousStart: '2026-10-02T09:00:00+08:00', start: '2026-10-02T09:30:00+08:00',
    });
    expect(h.icsPushes()).toBe(pushes);
    expect(await onlyMapping(h, source.id)).toEqual(mapping);
  });

  it('returns changes only when asked', async () => {
    const h = createHarness();
    const source = await seedSource(h);
    expect((await sync(h, 'u-a', source.id)).changes).toBeUndefined();
    h.setFeed(calendar(event().replace('SUMMARY:Meeting', 'SUMMARY:Next')));
    const stats = await sync(h, 'u-a', source.id, { includeChanges: true });
    expect(stats.changes).toEqual([expect.objectContaining({ action: 'update', summary: 'Next' })]);
  });

  it('reports busy while another run holds the lease, and releases its own lease afterwards', async () => {
    const h = createHarness();
    const source = await seedSource(h);
    expect(await h.store.acquireLease('u-a', source.id, 'other', Date.now(), LEASE_TTL_MS)).toBe(true);
    expect(await sync(h, 'u-a', source.id)).toMatchObject({ busy: true, created: 0 });
    expect(h.icsPushes()).toBe(0);
    await h.store.releaseLease('u-a', source.id, 'other');

    const results = await Promise.all([sync(h, 'u-a', source.id), sync(h, 'u-a', source.id)]);
    expect(results.filter((r) => r.busy)).toHaveLength(1);
    expect(pulledTasks(await h.pull('u-a'))).toHaveLength(1);
    // Both runs are over: the lease is free again.
    expect(await h.store.acquireLease('u-a', source.id, 'after', Date.now(), LEASE_TTL_MS)).toBe(true);
  });

  it('sends nothing when the lease is lost between reservation and push', async () => {
    const h = createHarness(calendar(event([], 'a'), event([], 'b')));
    const source = await seedSource(h);
    const reserve = h.store.reserveMappings.bind(h.store);
    h.store.reserveMappings = async (userId, sourceId, lease, items) => {
      const reserved = await reserve(userId, sourceId, lease, items);
      await h.store.releaseLease(userId, sourceId, lease);
      return reserved;
    };
    expect(await sync(h, 'u-a', source.id)).toMatchObject({ errors: 1 });
    expect(h.icsPushes()).toBe(0);
    expect(await h.store.listMappings('u-a', source.id)).toHaveLength(2);
  });

  it('records a feed failure as an error and frees the lease', async () => {
    const h = createHarness();
    const source = await seedSource(h);
    h.setFeedStatus(503);
    const stats = await sync(h, 'u-a', source.id);
    expect(stats).toMatchObject({ errors: 1 });
    expect(stats.lastError).toContain('HTTP 503');
    expect(await h.store.getSource('u-a', source.id)).toMatchObject({ lastStatus: 'error', lastSyncAt: NOW });
    h.setFeedStatus(200);
    expect(await sync(h, 'u-a', source.id)).toMatchObject({ created: 1, errors: 0 });
  });

  it('does nothing for a missing source or one owned by another user', async () => {
    const h = createHarness();
    await seedSource(h);
    expect(await sync(h, 'u-a', 999)).toMatchObject({ created: 0, errors: 0 });
    expect(await sync(h, 'u-b', 1)).toMatchObject({ created: 0, errors: 0 });
    expect(h.icsPushes()).toBe(0);
  });

  it('refuses an account that never synced from the App, before reserving anything', async () => {
    const h = createHarness();
    await seedUser(h, 'u-a', null, false);
    const source = await h.store.addSource('u-a', { name: 'Work', url: FEED_URL, projectId: 'p1' });
    const stats = await sync(h, 'u-a', source.id);
    expect(stats).toMatchObject({ errors: 1, lastError: NO_DATA_MESSAGE });
    expect(h.icsPushes()).toBe(0);
    expect(await h.store.listMappings('u-a', source.id)).toEqual([]);
    expect((await h.store.getSource('u-a', source.id))?.lastStatus).toBe('error');
  });

  it('refuses a deleted source list without writing', async () => {
    const h = createHarness();
    const source = await seedSource(h);
    await deviceEdit(h, 'u-a', 'project', 'p1', { deletedAt: NOW_ISH });
    expect(await sync(h, 'u-a', source.id)).toMatchObject({ errors: 1 });
    expect(h.icsPushes()).toBe(0);
    expect(await h.store.listMappings('u-a', source.id)).toEqual([]);
  });
});

describe('M15a shared list', () => {
  /** u-a owns p1; u-b joins as editor and subscribes p1 to a feed. */
  async function seedShared(h: Harness) {
    await seedSource(h);
    await seedUser(h, 'u-b', 'm-b');
    const invite = await createInvite(h.db, { userId: 'u-a', projectId: 'p1', role: 'editor', nowMs: Date.now() });
    await acceptInvite(h.db, { code: invite.code, userId: 'u-b', getScopeStub: h.getScopeStub, nowMs: Date.now() });
    return h.store.addSource('u-b', { name: 'Team', url: FEED_URL, projectId: 'p1' });
  }

  it('writes nothing in a whole run after the subscriber is downgraded to viewer', async () => {
    const h = createHarness();
    const source = await seedShared(h);
    expect(await sync(h, 'u-b', source.id)).toMatchObject({ created: 1, errors: 0 });
    // The owner sees the task created through u-b's feed.
    expect(pulledTasks(await h.pull('u-a')).filter((t) => t.projectId === 'p1')).toHaveLength(1);

    await updateProjectMemberRole(h.db, {
      projectId: 'p1', targetUserId: 'u-b', requesterUserId: 'u-a', role: 'viewer', getScopeStub: h.getScopeStub, nowMs: Date.now(),
    });
    const mappings = await h.store.listMappings('u-b', source.id);
    const pushes = h.icsPushes();
    // A changed event and a new one: both would be written if the run went on.
    h.setFeed(calendar(event().replace('SUMMARY:Meeting', 'SUMMARY:Changed'), event([], 'new-one')));
    const stats = await sync(h, 'u-b', source.id);
    expect(stats).toMatchObject({ created: 0, updated: 0, errors: 1 });
    expect(stats.lastError).toMatch(/writ/i);
    expect(h.icsPushes()).toBe(pushes);
    expect(await h.store.listMappings('u-b', source.id)).toEqual(mappings);
    expect((await h.store.getSource('u-b', source.id))?.lastStatus).toBe('error');
    expect(pulledTasks(await h.pull('u-a')).map((t) => t.title)).toEqual(['Meeting']);
  });
});
