// M15b: ICS engine cancellation, source deletion, guards and terminal states (spec/mcp.md 9.3),
// against a real ScopeObject and the in-memory ICS store. Scenarios follow the rest of REF
// engine.test, rewritten for DayDo rows. The harness mirrors ics-engine-sync.test.ts with a
// per-URL feed so several sources can be synced in one test.
import { describe, expect, it, vi } from 'vitest';
import { acceptInvite, createInvite, updateProjectMemberRole } from '../src/sharing';
import { syncDueSources, syncSource } from '../src/ics/engine';
import type { IcsMapping } from '../src/ics/store';
import { MemoryIcsStore } from './helpers/memoryIcsStore';
import {
  createServerHarness,
  deviceOp,
  NOW_ISH,
  projectRow,
  seedUser,
  type PullRes,
} from './helpers/serverHarness';

const NOW = Date.parse('2026-10-01T00:00:00Z');
const FEED_URL = 'https://calendar.example/feed.ics';
const BAD_URL = 'https://calendar.example/bad.ics';
const PREFIX = '[已取消] ';

const event = (extra: string[] = [], uid = 'meeting-a') =>
  ['BEGIN:VEVENT', `UID:${uid}`, 'SUMMARY:Meeting', 'DTSTART:20261002T010000Z', 'DTEND:20261002T020000Z', ...extra, 'END:VEVENT'].join('\r\n');
const calendar = (...events: string[]) => ['BEGIN:VCALENDAR', 'VERSION:2.0', ...events, 'END:VCALENDAR'].join('\r\n');
const many = (prefix: string, n: number) => Array.from({ length: n }, (_, i) => event([], `${prefix}-${i}`));

function createHarness(initialFeed = calendar(event())) {
  const hooks: {
    beforeIcsPush?: () => Promise<unknown>;
    failBeforeIcsPush?: boolean;
    loseIcsResponse?: boolean;
  } = {};
  const { db, calls, clock, getScopeStub, devicePush, deviceHlc, pull } = createServerHarness({
    onPush: async (input, proceed) => {
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
      const res = await proceed(input);
      if (input.deviceId === 'ics' && hooks.loseIcsResponse) {
        hooks.loseIcsResponse = false;
        throw new Error('response lost');
      }
      return res;
    },
  });

  const feeds = new Map<string, { body: string; status: number }>([
    [FEED_URL, { body: initialFeed, status: 200 }],
    [BAD_URL, { body: 'unavailable', status: 403 }],
  ]);
  const fakeFetch = (async (url: string | URL | Request) => {
    const feed = feeds.get(String(url));
    if (!feed) throw new Error(`Unexpected fetch: ${String(url)}`);
    return new Response(feed.body, { status: feed.status });
  }) as typeof fetch;

  const store = new MemoryIcsStore();
  const deps = { store, db, getScopeStub, clock, fetchOptions: { fetch: fakeFetch } };
  return {
    db,
    store,
    hooks,
    deps,
    getScopeStub,
    deviceHlc,
    devicePush,
    pull,
    setFeed(body: string, url = FEED_URL) {
      feeds.set(url, { body, status: 200 });
    },
    icsOps: () => calls.filter((c) => c.deviceId === 'ics').flatMap((c) => c.ops),
    icsPushes: () => calls.filter((c) => c.deviceId === 'ics').length,
  };
}

type Harness = ReturnType<typeof createHarness>;

async function deviceEdit(h: Harness, userId: string, entity: string, id: string, set: Record<string, unknown>, hlc = h.deviceHlc(Date.now() + 1000)) {
  const res = await h.devicePush(userId, [{ ...deviceOp(h, entity, { id, ...set }, hlc), fields: Object.keys(set) }]);
  expect(res.results[0]?.status).toBe('applied');
}

/** A device purges a row (op: 'delete' leaves a tombstone with purgedAt). */
async function devicePurge(h: Harness, userId: string, entity: 'task' | 'project', id: string) {
  const hlc = h.deviceHlc(Date.now() + 1000);
  const res = await h.devicePush(userId, [
    { opId: `dev-del-${id}-${hlc}`, hlc, entity, entityId: id, op: 'delete', fields: [], row: {} },
  ]);
  expect(res.results[0]?.status).toBe('applied');
}

/** u-a with inbox and list p1, plus an ICS source on p1. */
async function seedSource(h: Harness) {
  await seedUser(h, 'u-a', 'm-a');
  const res = await h.devicePush('u-a', [deviceOp(h, 'project', projectRow('p1'))]);
  expect(res.results[0]?.status).toBe('applied');
  return h.store.addSource('u-a', { name: 'Work', url: FEED_URL, projectId: 'p1' });
}

/** Every task row the user can pull, trash included. */
function pulledTasks(res: PullRes): Record<string, unknown>[] {
  const out: Record<string, unknown>[] = [];
  for (const s of res.scopes) {
    for (const r of s.rows) if (r.entity === 'task' && !('gone' in r)) out.push(r.row as Record<string, unknown>);
  }
  return out;
}

const isLive = (t: Record<string, unknown>) => t.deletedAt === null || t.deletedAt === undefined;

async function liveTasks(h: Harness, userId = 'u-a') {
  return pulledTasks(await h.pull(userId)).filter(isLive);
}

async function taskOf(h: Harness, id: string, userId = 'u-a') {
  return pulledTasks(await h.pull(userId)).find((t) => t.id === id);
}

const sync = (h: Harness, userId: string, sourceId: number, options = {}, now = NOW) =>
  syncSource(h.deps, userId, sourceId, now, options);

async function onlyMapping(h: Harness, sourceId: number, userId = 'u-a'): Promise<IcsMapping> {
  const all = await h.store.listMappings(userId, sourceId);
  expect(all).toHaveLength(1);
  return all[0]!;
}

describe('M15b cancellation', () => {
  it('cancels in place, writing only the title prefix, status, completedAt and reminders, and never imports a cancelled event', async () => {
    const h = createHarness(calendar(event(['DESCRIPTION:Agenda'])));
    const source = await seedSource(h);
    await sync(h, 'u-a', source.id);
    const { taskId } = await onlyMapping(h, source.id);
    const before = (await taskOf(h, taskId))!;
    // The user renamed it on the phone; the prefix goes on the user's title.
    await deviceEdit(h, 'u-a', 'task', taskId, { title: 'My meeting', priority: 3 });

    h.setFeed(calendar(event(['DESCRIPTION:Agenda', 'STATUS:CANCELLED'])));
    const preview = await sync(h, 'u-a', source.id, { dryRun: true });
    expect(preview).toMatchObject({ deleted: 1, updated: 0, errors: 0 });
    expect(preview.changes?.[0]).toMatchObject({ action: 'cancel', taskId });

    const opsBefore = h.icsOps().length;
    const stats = await sync(h, 'u-a', source.id, { includeChanges: true });
    expect(stats).toMatchObject({ deleted: 1, updated: 0, errors: 0 });
    expect(stats.changes?.[0]).toMatchObject({ action: 'cancel', taskId });
    const ops = h.icsOps().slice(opsBefore);
    expect(ops).toHaveLength(1);
    expect(new Set(ops[0]!.fields as string[])).toEqual(new Set(['title', 'status', 'completedAt', 'reminders', 'updatedAt']));
    const t = (await taskOf(h, taskId))!;
    expect(t).toMatchObject({
      title: `${PREFIX}My meeting`, status: 2, completedAt: NOW, reminders: [], priority: 3,
      content: 'Agenda', startDay: before.startDay, startMinute: before.startMinute,
    });
    expect(await onlyMapping(h, source.id)).toMatchObject({ state: 'cancelled', lastError: null });

    const pushes = h.icsPushes();
    expect(await sync(h, 'u-a', source.id)).toMatchObject({ skipped: 1, deleted: 0, errors: 0 });
    expect(h.icsPushes()).toBe(pushes);

    // An event already cancelled when first seen is not imported.
    h.setFeed(calendar(event(['DESCRIPTION:Agenda', 'STATUS:CANCELLED']), event(['STATUS:CANCELLED'], 'never-imported')));
    expect(await sync(h, 'u-a', source.id)).toMatchObject({ created: 0, errors: 0 });
    expect(h.icsPushes()).toBe(pushes);
    expect((await h.store.listMappings('u-a', source.id)).map((m) => m.icsUid)).toEqual(['meeting-a']);
  });

  it('keeps a completion the user made before the event was cancelled', async () => {
    const h = createHarness();
    const source = await seedSource(h);
    await sync(h, 'u-a', source.id);
    const { taskId } = await onlyMapping(h, source.id);
    await deviceEdit(h, 'u-a', 'task', taskId, { status: 2, completedAt: NOW_ISH });
    h.setFeed(calendar(event(['STATUS:CANCELLED'])));
    const opsBefore = h.icsOps().length;
    expect(await sync(h, 'u-a', source.id)).toMatchObject({ deleted: 1, errors: 0 });
    const ops = h.icsOps().slice(opsBefore);
    expect(ops[0]!.fields as string[]).not.toContain('completedAt');
    expect(await taskOf(h, taskId)).toMatchObject({ title: `${PREFIX}Meeting`, status: 2, completedAt: NOW_ISH, reminders: [] });
  });

  it('reopens the task as a source change when the cancellation is withdrawn', async () => {
    const h = createHarness();
    const source = await seedSource(h);
    await sync(h, 'u-a', source.id);
    const { taskId } = await onlyMapping(h, source.id);
    h.setFeed(calendar(event(['STATUS:CANCELLED'])));
    await sync(h, 'u-a', source.id);
    h.setFeed(calendar(event()));
    expect(await sync(h, 'u-a', source.id)).toMatchObject({ updated: 1, deleted: 0, errors: 0 });
    const t = (await taskOf(h, taskId))!;
    expect(t).toMatchObject({ title: 'Meeting', status: 0 });
    expect(t.completedAt ?? null).toBeNull();
    expect(await onlyMapping(h, source.id)).toMatchObject({ state: 'applied' });
  });

  it('does not create a reserved task whose event was cancelled before the create landed, and creates it after the cancellation is withdrawn', async () => {
    const h = createHarness();
    const source = await seedSource(h);
    h.hooks.failBeforeIcsPush = true;
    await sync(h, 'u-a', source.id);
    const reserved = await onlyMapping(h, source.id);
    expect(reserved.state).toBe('pending');

    h.setFeed(calendar(event(['STATUS:CANCELLED'])));
    const pushes = h.icsPushes();
    expect(await sync(h, 'u-a', source.id)).toMatchObject({ created: 0, errors: 0 });
    expect(h.icsPushes()).toBe(pushes);
    expect(pulledTasks(await h.pull('u-a'))).toHaveLength(0);

    h.setFeed(calendar(event()));
    expect(await sync(h, 'u-a', source.id)).toMatchObject({ created: 1, errors: 0 });
    expect((await liveTasks(h)).map((t) => t.id)).toEqual([reserved.taskId]);
  });

  it('recovers a lost cancel response without writing again', async () => {
    const h = createHarness();
    const source = await seedSource(h);
    await sync(h, 'u-a', source.id);
    const { taskId } = await onlyMapping(h, source.id);
    h.setFeed(calendar(event(['STATUS:CANCELLED'])));
    h.hooks.loseIcsResponse = true;
    expect(await sync(h, 'u-a', source.id)).toMatchObject({ errors: 1 });
    expect(await onlyMapping(h, source.id)).toMatchObject({ state: 'updating' });
    const pushes = h.icsPushes();
    expect(await sync(h, 'u-a', source.id)).toMatchObject({ errors: 0 });
    expect(h.icsPushes()).toBe(pushes);
    expect(await onlyMapping(h, source.id)).toMatchObject({ state: 'cancelled' });
    expect(await taskOf(h, taskId)).toMatchObject({ title: `${PREFIX}Meeting`, status: 2 });
  });

  it('cancels an existing occurrence excluded by EXDATE', async () => {
    const master = event(['RRULE:FREQ=WEEKLY;COUNT=3']);
    const h = createHarness(calendar(master));
    const source = await seedSource(h);
    await sync(h, 'u-a', source.id);
    const excluded = (await h.store.listMappings('u-a', source.id)).find((m) => m.occurrenceId === 'UTC:2026-10-09T01:00:00Z')!;
    h.setFeed(calendar(event(['RRULE:FREQ=WEEKLY;COUNT=3', 'EXDATE:20261009T010000Z'])));
    expect(await sync(h, 'u-a', source.id)).toMatchObject({ deleted: 1, skipped: 2, errors: 0 });
    const tasks = pulledTasks(await h.pull('u-a'));
    expect(tasks).toHaveLength(3);
    for (const t of tasks) {
      if (t.id === excluded.taskId) expect(t).toMatchObject({ status: 2, title: `${PREFIX}Meeting` });
      else expect(t).toMatchObject({ status: 0, title: 'Meeting' });
    }
  });

  it.each([[], ['RRULE:FREQ=WEEKLY;COUNT=3']])('cancels every mapped slot when a bare cancelled master without DTSTART replaces the series %j', async (...rule: string[]) => {
    const h = createHarness(calendar(event(['RRULE:FREQ=WEEKLY;COUNT=3'])));
    const source = await seedSource(h);
    await sync(h, 'u-a', source.id);
    expect(await h.store.listMappings('u-a', source.id)).toHaveLength(3);
    h.setFeed(calendar(['BEGIN:VEVENT', 'UID:meeting-a', 'STATUS:CANCELLED', ...rule, 'END:VEVENT'].join('\r\n')));
    expect(await sync(h, 'u-a', source.id)).toMatchObject({ deleted: 3, created: 0, errors: 0 });
    const tasks = pulledTasks(await h.pull('u-a'));
    expect(tasks).toHaveLength(3);
    expect(tasks.every((t) => t.status === 2 && t.title === `${PREFIX}Meeting` && isLive(t))).toBe(true);
    expect((await h.store.listMappings('u-a', source.id)).every((m) => m.state === 'cancelled')).toBe(true);
  });
});

describe('M15b source deletion', () => {
  it('moves a removed event to the trash and deletes its mapping, leaving unrelated tasks alone', async () => {
    const h = createHarness();
    const source = await seedSource(h);
    await sync(h, 'u-a', source.id);
    const { taskId } = await onlyMapping(h, source.id);
    await h.devicePush('u-a', [
      deviceOp(h, 'task', {
        id: 'manual', projectId: 'p1', title: 'My manual task', content: '', priority: 0, status: 0, sortKey: 'i',
        reminders: [], tags: [], createdAt: NOW_ISH, updatedAt: NOW_ISH,
      }),
    ]);
    h.setFeed(calendar());
    const pushes = h.icsPushes();
    const preview = await sync(h, 'u-a', source.id, { dryRun: true });
    expect(preview).toMatchObject({ deleted: 1, errors: 0 });
    expect(preview.changes?.[0]).toMatchObject({ action: 'delete', taskId });
    expect(h.icsPushes()).toBe(pushes);
    expect(await h.store.listMappings('u-a', source.id)).toHaveLength(1);

    const opsBefore = h.icsOps().length;
    expect(await sync(h, 'u-a', source.id)).toMatchObject({ deleted: 1, errors: 0 });
    const ops = h.icsOps().slice(opsBefore);
    expect(ops).toHaveLength(1);
    expect(new Set(ops[0]!.fields as string[])).toEqual(new Set(['deletedAt', 'updatedAt']));
    expect(await taskOf(h, taskId)).toMatchObject({ deletedAt: NOW });
    expect((await liveTasks(h)).map((t) => t.id)).toEqual(['manual']);
    expect(await h.store.listMappings('u-a', source.id)).toEqual([]);
    expect(await sync(h, 'u-a', source.id)).toMatchObject({ deleted: 0, errors: 0 });
  });

  it.each(['push failure', 'lost response', 'device restore'] as const)(
    'keeps the mapping after a %s and finishes the deletion on the next run',
    async (fault) => {
      const h = createHarness();
      const source = await seedSource(h);
      await sync(h, 'u-a', source.id);
      const { taskId } = await onlyMapping(h, source.id);
      h.setFeed(calendar());
      if (fault === 'push failure') h.hooks.failBeforeIcsPush = true;
      if (fault === 'lost response') h.hooks.loseIcsResponse = true;
      if (fault === 'device restore') {
        // The phone touches the task with a clock ahead of the server, after the snapshot was read.
        const lead = Date.now() + 3 * 60_000;
        h.hooks.beforeIcsPush = () => deviceEdit(h, 'u-a', 'task', taskId, { deletedAt: null }, `${lead}:0000:dev-a`);
      }
      expect(await sync(h, 'u-a', source.id)).toMatchObject({ errors: 1, deleted: 0 });
      expect(await h.store.listMappings('u-a', source.id)).toHaveLength(1);
      expect(await sync(h, 'u-a', source.id)).toMatchObject({ deleted: 1, errors: 0 });
      expect(await taskOf(h, taskId)).toMatchObject({ deletedAt: expect.any(Number) });
      expect(await h.store.listMappings('u-a', source.id)).toEqual([]);
    },
  );

  it('recovers when the mapping delete fails after the task was trashed', async () => {
    const h = createHarness();
    const source = await seedSource(h);
    await sync(h, 'u-a', source.id);
    const { taskId } = await onlyMapping(h, source.id);
    h.setFeed(calendar());
    const remove = h.store.deleteMapping.bind(h.store);
    let failOnce = true;
    h.store.deleteMapping = async (...args) => {
      if (failOnce) {
        failOnce = false;
        throw new Error('D1 offline');
      }
      await remove(...args);
    };
    expect(await sync(h, 'u-a', source.id)).toMatchObject({ errors: 1, deleted: 0 });
    expect(await taskOf(h, taskId)).toMatchObject({ deletedAt: NOW });
    expect(await h.store.listMappings('u-a', source.id)).toHaveLength(1);
    const pushes = h.icsPushes();
    expect(await sync(h, 'u-a', source.id)).toMatchObject({ deleted: 1, errors: 0 });
    expect(h.icsPushes()).toBe(pushes);
    expect(await h.store.listMappings('u-a', source.id)).toEqual([]);
  });

  it('keeps keyword-excluded events and recurring slots beyond a smaller window', async () => {
    const h = createHarness(calendar(event(['RRULE:FREQ=WEEKLY;COUNT=3']), event([], 'single')));
    const source = await seedSource(h);
    await sync(h, 'u-a', source.id);
    const before = (await liveTasks(h)).map((t) => t.id).sort();
    expect(before).toHaveLength(4);
    const narrowed = { ...(await h.store.getSource('u-a', source.id))!, filter: { futureDays: 1, excludeKeywords: ['Meeting'] } };
    vi.spyOn(h.store, 'getSource').mockResolvedValue(narrowed);
    const pushes = h.icsPushes();
    expect(await sync(h, 'u-a', source.id)).toMatchObject({ deleted: 0, errors: 0 });
    expect(h.icsPushes()).toBe(pushes);
    expect((await liveTasks(h)).map((t) => t.id).sort()).toEqual(before);
    expect(await h.store.listMappings('u-a', source.id)).toHaveLength(4);
  });

  it('trashes a removed orphan exception without touching another slot sharing its UID', async () => {
    const a = event(['RECURRENCE-ID:20261002T010000Z']);
    const b = event(['RECURRENCE-ID:20261009T010000Z']).replaceAll('20261002', '20261009');
    const h = createHarness(calendar(a, b));
    const source = await seedSource(h);
    await sync(h, 'u-a', source.id);
    const keep = (await h.store.listMappings('u-a', source.id)).find((m) => m.occurrenceId === 'UTC:2026-10-09T01:00:00Z')!;
    h.setFeed(calendar(b));
    expect(await sync(h, 'u-a', source.id)).toMatchObject({ deleted: 1, skipped: 1, errors: 0 });
    expect((await liveTasks(h)).map((t) => t.id)).toEqual([keep.taskId]);
  });

  // Guards the second ICAL.parse in the engine, which would throw on a BOM fetchIcs let through.
  it('accepts a feed that starts with a byte-order mark', async () => {
    const h = createHarness(`\uFEFF${calendar(event())}`);
    const source = await seedSource(h);
    expect(await sync(h, 'u-a', source.id)).toMatchObject({ created: 1, errors: 0 });
  });

  it.each(['<html>gateway failure</html>', 'BEGIN:VCALENDAR\nVERSION:2.0\nBEGIN:VEVENT\nUID:broken'])(
    'rejects invalid or truncated input before touching any task: %s',
    async (feed) => {
      const h = createHarness();
      const source = await seedSource(h);
      await sync(h, 'u-a', source.id);
      const mappings = await h.store.listMappings('u-a', source.id);
      const pushes = h.icsPushes();
      h.setFeed(feed);
      expect(await sync(h, 'u-a', source.id)).toMatchObject({ errors: 1, deleted: 0 });
      expect((await h.store.getSource('u-a', source.id))?.lastStatus).toBe('error');
      expect(h.icsPushes()).toBe(pushes);
      expect(await h.store.listMappings('u-a', source.id)).toEqual(mappings);
    },
  );
});

describe('M15b mass-delete guard', () => {
  it('refuses a run that would remove most imported events, then recovers', async () => {
    const h = createHarness(calendar(...many('m', 6)));
    const source = await seedSource(h);
    await sync(h, 'u-a', source.id);
    const pushes = h.icsPushes();
    h.setFeed(calendar());
    const stats = await sync(h, 'u-a', source.id);
    expect(stats).toMatchObject({ deleted: 0, errors: 1 });
    expect(stats.lastError).toContain('safety check');
    expect(h.icsPushes()).toBe(pushes);
    expect(await h.store.listMappings('u-a', source.id)).toHaveLength(6);
    expect((await h.store.getSource('u-a', source.id))?.lastStatus).toBe('error');
    h.setFeed(calendar(...many('m', 6)));
    expect(await sync(h, 'u-a', source.id)).toMatchObject({ created: 0, deleted: 0, errors: 0 });
    expect(await liveTasks(h)).toHaveLength(6);
  });

  it('refuses a UID swap before reserving or writing anything, in preview and for real', async () => {
    const h = createHarness(calendar(...many('old', 10)));
    const source = await seedSource(h);
    await sync(h, 'u-a', source.id);
    const pushes = h.icsPushes();
    const mappings = await h.store.listMappings('u-a', source.id);
    h.setFeed(calendar(...many('new', 10)));

    const dry = await sync(h, 'u-a', source.id, { dryRun: true });
    expect(dry).toMatchObject({ created: 0, deleted: 0 });
    expect(dry.errors).toBeGreaterThanOrEqual(1);
    expect(dry.lastError).toContain('safety check');
    expect(dry.changes).toHaveLength(10);
    expect(dry.changes?.every((c) => c.action === 'skip' && c.reason === 'mass-delete guard' && c.uid.startsWith('old-'))).toBe(true);

    const real = await sync(h, 'u-a', source.id);
    expect(real).toMatchObject({ created: 0, deleted: 0 });
    expect(real.lastError).toBe(dry.lastError);
    expect(h.icsPushes()).toBe(pushes);
    expect(await h.store.listMappings('u-a', source.id)).toEqual(mappings);
    expect(await liveTasks(h)).toHaveLength(10);
  });

  it('deletes normally below the threshold', async () => {
    const h = createHarness(calendar(...many('old', 10)));
    const source = await seedSource(h);
    await sync(h, 'u-a', source.id);
    h.setFeed(calendar(...many('old', 6)));
    expect(await sync(h, 'u-a', source.id)).toMatchObject({ deleted: 4, errors: 0 });
    expect(await liveTasks(h)).toHaveLength(6);
    expect(await h.store.listMappings('u-a', source.id)).toHaveLength(6);
  });

  it('allows a mass delete only when explicitly opted in', async () => {
    const h = createHarness(calendar(...many('ev', 8)));
    const source = await seedSource(h);
    await sync(h, 'u-a', source.id);
    h.setFeed(calendar(...many('ev', 3)));
    const refused = await sync(h, 'u-a', source.id);
    expect(refused.lastError).toContain('safety check');
    expect(await liveTasks(h)).toHaveLength(8);

    const dry = await sync(h, 'u-a', source.id, { dryRun: true, allowMassDelete: true });
    expect(dry).toMatchObject({ deleted: 5, errors: 0 });
    expect(dry.changes?.filter((c) => c.action === 'delete')).toHaveLength(5);

    expect(await sync(h, 'u-a', source.id, { allowMassDelete: true })).toMatchObject({ deleted: 5, errors: 0 });
    expect(await liveTasks(h)).toHaveLength(3);
    expect(await h.store.listMappings('u-a', source.id)).toHaveLength(3);
  });
});

describe('M15b redefinition guard', () => {
  it('refuses a single event that became a recurring series, and a redefined rule', async () => {
    const h = createHarness();
    const source = await seedSource(h);
    await sync(h, 'u-a', source.id);
    const pushes = h.icsPushes();
    h.setFeed(calendar(event(['RRULE:FREQ=WEEKLY;COUNT=3'])));
    const legacy = await sync(h, 'u-a', source.id);
    expect(legacy).toMatchObject({ errors: 1, created: 0 });
    expect(h.icsPushes()).toBe(pushes);
    expect(await h.store.listMappings('u-a', source.id)).toHaveLength(1);

    const h2 = createHarness(calendar(event(['RRULE:FREQ=WEEKLY;COUNT=3'])));
    const source2 = await seedSource(h2);
    await sync(h2, 'u-a', source2.id);
    const pushes2 = h2.icsPushes();
    h2.setFeed(calendar(event(['RRULE:FREQ=DAILY;COUNT=3'])));
    const redefined = await sync(h2, 'u-a', source2.id);
    expect(redefined).toMatchObject({ errors: 1, created: 0, deleted: 0 });
    expect(redefined.lastError).toMatch(/series/i);
    expect(h2.icsPushes()).toBe(pushes2);
  });

  it('accepts a series whose end moved later, and trashes the slots a shorter end drops', async () => {
    const h = createHarness(calendar(event(['RRULE:FREQ=WEEKLY;COUNT=3'])));
    const source = await seedSource(h);
    expect(await sync(h, 'u-a', source.id)).toMatchObject({ created: 3, errors: 0 });
    h.setFeed(calendar(event(['RRULE:FREQ=WEEKLY;UNTIL=20261023T010000Z'])));
    expect(await sync(h, 'u-a', source.id)).toMatchObject({ created: 1, skipped: 3, errors: 0 });
    expect(new Set((await h.store.listMappings('u-a', source.id)).map((m) => m.seriesSignature)).size).toBe(1);
    h.setFeed(calendar(event(['RRULE:FREQ=WEEKLY;COUNT=2'])));
    expect(await sync(h, 'u-a', source.id)).toMatchObject({ errors: 0, deleted: 2, skipped: 2 });
    expect(await liveTasks(h)).toHaveLength(2);
    expect((await h.store.listMappings('u-a', source.id)).map((m) => m.occurrenceId).sort()).toEqual([
      'UTC:2026-10-02T01:00:00Z',
      'UTC:2026-10-09T01:00:00Z',
    ]);
  });

  it('trashes the slot of a removed RDATE', async () => {
    const h = createHarness(calendar(event(['RRULE:FREQ=WEEKLY;COUNT=2', 'RDATE:20261020T010000Z'])));
    const source = await seedSource(h);
    expect(await sync(h, 'u-a', source.id)).toMatchObject({ created: 3, errors: 0 });
    const extra = (await h.store.listMappings('u-a', source.id)).find((m) => m.occurrenceId === 'UTC:2026-10-20T01:00:00Z')!;
    h.setFeed(calendar(event(['RRULE:FREQ=WEEKLY;COUNT=2'])));
    expect(await sync(h, 'u-a', source.id)).toMatchObject({ deleted: 1, skipped: 2, errors: 0 });
    expect(await taskOf(h, extra.taskId)).toMatchObject({ deletedAt: NOW });
    expect(await liveTasks(h)).toHaveLength(2);
  });

  it('trashes only the slots an earlier UNTIL drops, and keeps the rest of the series and the source syncing', async () => {
    const other = (summary: string) => event([], 'other').replace('SUMMARY:Meeting', `SUMMARY:${summary}`);
    const h = createHarness(calendar(event(['RRULE:FREQ=WEEKLY;COUNT=4']), other('Other')));
    const source = await seedSource(h);
    expect(await sync(h, 'u-a', source.id)).toMatchObject({ created: 5, errors: 0 });
    const slots = await h.store.listMappings('u-a', source.id);
    const slotTask = (occurrenceId: string) => slots.find((m) => m.occurrenceId === occurrenceId)!.taskId;
    const kept = ['UTC:2026-10-02T01:00:00Z', 'UTC:2026-10-09T01:00:00Z'].map(slotTask);
    const dropped = ['UTC:2026-10-16T01:00:00Z', 'UTC:2026-10-23T01:00:00Z'].map(slotTask);

    // "This and following" in a calendar app: the series ends earlier and the rest moves to a new UID.
    const shortened = event(['RRULE:FREQ=WEEKLY;UNTIL=20261009T010000Z']);
    const following = event(['RRULE:FREQ=WEEKLY;COUNT=2'], 'meeting-b').replaceAll('20261002', '20261016');
    h.setFeed(calendar(shortened, following, other('Other renamed')));
    const preview = await sync(h, 'u-a', source.id, { dryRun: true });
    expect(preview).toMatchObject({ deleted: 2, created: 2, updated: 1, errors: 0 });

    const stats = await sync(h, 'u-a', source.id, { includeChanges: true });
    expect(stats).toMatchObject({ deleted: 2, created: 2, updated: 1, skipped: 2, errors: 0 });
    expect(new Set(stats.changes?.filter((c) => c.action === 'delete').map((c) => c.taskId))).toEqual(new Set(dropped));
    for (const id of dropped) expect(await taskOf(h, id)).toMatchObject({ deletedAt: NOW });
    const live = await liveTasks(h);
    expect(live.map((t) => t.title).sort()).toEqual(['Meeting', 'Meeting', 'Meeting', 'Meeting', 'Other renamed']);
    for (const id of kept) expect(live.some((t) => t.id === id)).toBe(true);
    expect((await h.store.getSource('u-a', source.id))?.lastStatus).toBe('success');

    const mappings = await h.store.listMappings('u-a', source.id);
    expect(mappings).toHaveLength(5);
    expect(new Set(mappings.filter((m) => m.icsUid === 'meeting-a').map((m) => m.seriesSignature)).size).toBe(1);
    const pushes = h.icsPushes();
    expect(await sync(h, 'u-a', source.id)).toMatchObject({ created: 0, updated: 0, deleted: 0, errors: 0 });
    expect(h.icsPushes()).toBe(pushes);
  });

  it('keeps vanished series slots under the mass-delete guard', async () => {
    const h = createHarness(calendar(event(['RRULE:FREQ=WEEKLY;COUNT=10'])));
    const source = await seedSource(h);
    expect(await sync(h, 'u-a', source.id)).toMatchObject({ created: 10, errors: 0 });
    const pushes = h.icsPushes();
    h.setFeed(calendar(event(['RRULE:FREQ=WEEKLY;COUNT=2'])));
    const refused = await sync(h, 'u-a', source.id);
    expect(refused).toMatchObject({ deleted: 0, errors: 1 });
    expect(refused.lastError).toContain('safety check');
    expect(h.icsPushes()).toBe(pushes);
    expect(await liveTasks(h)).toHaveLength(10);
    expect(await sync(h, 'u-a', source.id, { allowMassDelete: true })).toMatchObject({ deleted: 8, errors: 0 });
    expect(await liveTasks(h)).toHaveLength(2);
  });

  it('refuses only the redefined UID and keeps syncing the other events of the source', async () => {
    const other = (summary: string) => event([], 'other').replace('SUMMARY:Meeting', `SUMMARY:${summary}`);
    const h = createHarness(calendar(event(['RRULE:FREQ=WEEKLY;COUNT=3']), other('Other')));
    const source = await seedSource(h);
    expect(await sync(h, 'u-a', source.id)).toMatchObject({ created: 4, errors: 0 });
    const series = (await h.store.listMappings('u-a', source.id)).filter((m) => m.icsUid === 'meeting-a');

    const redefined = event(['RRULE:FREQ=DAILY;COUNT=3']).replace('SUMMARY:Meeting', 'SUMMARY:Daily now');
    h.setFeed(calendar(redefined, other('Other renamed'), event([], 'fresh')));
    const preview = await sync(h, 'u-a', source.id, { dryRun: true, includeChanges: true });
    expect(preview).toMatchObject({ errors: 1, updated: 1, created: 1, deleted: 0 });
    expect(preview.lastError).toMatch(/series definition changed/i);

    const stats = await sync(h, 'u-a', source.id, { includeChanges: true });
    expect(stats).toMatchObject({ errors: 1, updated: 1, created: 1, deleted: 0 });
    expect(stats.lastError).toMatch(/series definition changed/i);
    expect(stats.changes?.filter((c) => c.action === 'error').map((c) => c.uid)).toEqual(['meeting-a']);
    expect((await h.store.getSource('u-a', source.id))?.lastStatus).toBe('partial');
    const live = await liveTasks(h);
    expect(live).toHaveLength(5);
    for (const m of series) expect(live.find((t) => t.id === m.taskId)).toMatchObject({ title: 'Meeting' });
    expect(live.filter((t) => t.title === 'Other renamed')).toHaveLength(1);
    const after = await h.store.listMappings('u-a', source.id);
    for (const m of after.filter((x) => x.icsUid === 'meeting-a')) {
      expect(m.lastError).toMatch(/series definition changed/i);
      expect(m.fingerprint).toBe(series.find((s) => s.occurrenceId === m.occurrenceId)!.fingerprint);
    }
    expect(after.filter((x) => x.icsUid === 'meeting-a')).toHaveLength(3);
  });

  it('detects a single event turned series and a redefined series outside the window, writing nothing to them', async () => {
    const later = NOW + 30 * 86_400_000;
    const fresh = event([], 'fresh').replaceAll('20261002', '20261105');
    const h = createHarness(calendar(event(), event(['RRULE:FREQ=WEEKLY;COUNT=2'], 'series-b')));
    const source = await seedSource(h);
    expect(await sync(h, 'u-a', source.id)).toMatchObject({ created: 3, errors: 0 });
    const before = await h.store.listMappings('u-a', source.id);
    const single = before.find((m) => m.icsUid === 'meeting-a')!;

    // Both changes sit before the window a month later; only the new meeting is inside it.
    h.setFeed(calendar(event(['RRULE:FREQ=WEEKLY;COUNT=2']), event(['RRULE:FREQ=DAILY;COUNT=2'], 'series-b'), fresh));
    const preview = await sync(h, 'u-a', source.id, { dryRun: true }, later);
    expect(preview).toMatchObject({ errors: 2, deleted: 0, created: 1 });

    const stats = await sync(h, 'u-a', source.id, { includeChanges: true }, later);
    expect(stats).toMatchObject({ errors: 2, deleted: 0, created: 1 });
    expect(new Set(stats.changes?.filter((c) => c.action === 'error').map((c) => c.uid))).toEqual(new Set(['meeting-a', 'series-b']));
    expect((await h.store.getSource('u-a', source.id))?.lastStatus).toBe('partial');
    const tasks = pulledTasks(await h.pull('u-a'));
    expect(tasks).toHaveLength(4);
    expect(tasks.every(isLive)).toBe(true);
    const after = await h.store.listMappings('u-a', source.id);
    expect(after.find((m) => m.icsUid === 'meeting-a')).toMatchObject({ occurrenceId: '', taskId: single.taskId });
    expect(after.find((m) => m.icsUid === 'meeting-a')?.lastError).toMatch(/single event became a recurring series/i);
    expect(after.filter((m) => m.icsUid === 'series-b')).toHaveLength(2);
  });

  it('refuses an exception that replaces a mapped single event without trashing the task', async () => {
    const h = createHarness();
    const source = await seedSource(h);
    await sync(h, 'u-a', source.id);
    const { taskId } = await onlyMapping(h, source.id);
    h.setFeed(calendar(event(['RECURRENCE-ID:20261002T010000Z'])));
    const stats = await sync(h, 'u-a', source.id);
    expect(stats).toMatchObject({ errors: 1, created: 0, deleted: 0 });
    expect(stats.lastError).toMatch(/single event became a recurring series/i);
    expect((await liveTasks(h)).map((t) => t.id)).toEqual([taskId]);
    expect(await onlyMapping(h, source.id)).toMatchObject({ occurrenceId: '', taskId });
  });

  it('keeps a floating slot that a narrower window ends just before, in a zone behind UTC', async () => {
    // 20:00 in Los Angeles is 03:00Z the next day; the slot's id reads 20:00 as UTC.
    const floating = event(['RRULE:FREQ=WEEKLY;COUNT=3'])
      .replace('DTSTART:20261002T010000Z', 'DTSTART:20261002T200000')
      .replace('DTEND:20261002T020000Z', 'DTEND:20261002T210000');
    const h = createHarness(calendar(floating));
    await seedSource(h);
    const source = await h.store.addSource('u-a', { name: 'LA', url: FEED_URL, projectId: 'p1', timezone: 'America/Los_Angeles' });
    expect(await sync(h, 'u-a', source.id)).toMatchObject({ created: 3, errors: 0 });
    // The window now ends at 2026-10-10T00:00Z: after 2026-10-09T20:00 read as UTC, before the real start.
    const narrowed = { ...(await h.store.getSource('u-a', source.id))!, filter: { futureDays: 9 } };
    vi.spyOn(h.store, 'getSource').mockResolvedValue(narrowed);
    expect(await sync(h, 'u-a', source.id)).toMatchObject({ deleted: 0, errors: 0 });
    expect(await h.store.listMappings('u-a', source.id)).toHaveLength(3);
  });

  it('keeps the slots an older revision of a series lacks, and resumes when the newer revision returns', async () => {
    const h = createHarness(calendar(event(['SEQUENCE:2', 'RRULE:FREQ=WEEKLY;COUNT=3'])));
    const source = await seedSource(h);
    expect(await sync(h, 'u-a', source.id)).toMatchObject({ created: 3, errors: 0 });
    const before = await h.store.listMappings('u-a', source.id);
    const third = before.find((m) => m.occurrenceId === 'UTC:2026-10-16T01:00:00Z')!;
    await deviceEdit(h, 'u-a', 'task', third.taskId, { status: 2, completedAt: NOW_ISH });

    // A stale cache or mirror serves the earlier, shorter version of the series.
    h.setFeed(calendar(event(['SEQUENCE:1', 'RRULE:FREQ=WEEKLY;COUNT=2'])));
    const preview = await sync(h, 'u-a', source.id, { dryRun: true });
    expect(preview).toMatchObject({ deleted: 0, created: 0, updated: 0 });
    const pushes = h.icsPushes();
    const stale = await sync(h, 'u-a', source.id, { includeChanges: true });
    expect(stale).toMatchObject({ deleted: 0, created: 0, updated: 0 });
    expect(stale.changes?.some((c) => c.action === 'delete')).toBe(false);
    expect(h.icsPushes()).toBe(pushes);
    const kept = await taskOf(h, third.taskId);
    expect(kept && isLive(kept)).toBe(true);
    expect(kept).toMatchObject({ status: 2, completedAt: NOW_ISH });
    expect((await h.store.listMappings('u-a', source.id)).map((m) => m.taskId).sort()).toEqual(before.map((m) => m.taskId).sort());

    h.setFeed(calendar(event(['SEQUENCE:2', 'RRULE:FREQ=WEEKLY;COUNT=3'])));
    expect(await sync(h, 'u-a', source.id)).toMatchObject({ created: 0, deleted: 0, errors: 0 });
    const after = await h.store.listMappings('u-a', source.id);
    expect(after.map((m) => m.taskId).sort()).toEqual(before.map((m) => m.taskId).sort());
    expect(await liveTasks(h)).toHaveLength(3);
    expect(await taskOf(h, third.taskId)).toMatchObject({ status: 2, completedAt: NOW_ISH });
  });

  it('treats an equal SEQUENCE with an older DTSTAMP as stale, records the kept slot, and keeps syncing other UIDs', async () => {
    const other = (summary: string) => event([], 'other').replace('SUMMARY:Meeting', `SUMMARY:${summary}`);
    const series = (stamp: string, count: number) => event([`DTSTAMP:${stamp}`, `RRULE:FREQ=WEEKLY;COUNT=${count}`]);
    const h = createHarness(calendar(series('20260902T000000Z', 3), other('Other'), event([], 'gone')));
    const source = await seedSource(h);
    expect(await sync(h, 'u-a', source.id)).toMatchObject({ created: 5, errors: 0 });
    const before = await h.store.listMappings('u-a', source.id);
    const third = before.find((m) => m.occurrenceId === 'UTC:2026-10-16T01:00:00Z')!;
    const gone = before.find((m) => m.icsUid === 'gone')!;

    h.setFeed(calendar(series('20260901T000000Z', 2), other('Other renamed')));
    const stats = await sync(h, 'u-a', source.id, { includeChanges: true });
    expect(stats).toMatchObject({ updated: 1, deleted: 1, created: 0 });
    expect(stats.changes?.filter((c) => c.action === 'delete').map((c) => c.taskId)).toEqual([gone.taskId]);
    expect(stats.changes?.find((c) => c.taskId === third.taskId)).toMatchObject({ action: 'skip', reason: expect.stringMatching(/older source revision/i) });
    const live = await liveTasks(h);
    expect(live.some((t) => t.id === third.taskId)).toBe(true);
    expect(live.some((t) => t.title === 'Other renamed')).toBe(true);
    expect(live.some((t) => t.id === gone.taskId)).toBe(false);
  });

  it('keeps the slots of a stale revision whose remaining slots are keyword-excluded', async () => {
    const h = createHarness(calendar(event(['SEQUENCE:2', 'RRULE:FREQ=WEEKLY;COUNT=3'])));
    await seedSource(h);
    const source = await h.store.addSource('u-a', { name: 'Filtered', url: FEED_URL, projectId: 'p1', filter: { excludeKeywords: ['Draft'] } });
    expect(await sync(h, 'u-a', source.id)).toMatchObject({ created: 3, errors: 0 });
    const third = (await h.store.listMappings('u-a', source.id)).find((m) => m.occurrenceId === 'UTC:2026-10-16T01:00:00Z')!;
    h.setFeed(calendar(event(['SEQUENCE:1', 'RRULE:FREQ=WEEKLY;COUNT=2']).replace('SUMMARY:Meeting', 'SUMMARY:Draft meeting')));
    expect(await sync(h, 'u-a', source.id)).toMatchObject({ deleted: 0 });
    expect((await liveTasks(h)).some((t) => t.id === third.taskId)).toBe(true);
  });

  it('trashes the slots a shorter series drops even when none of it is inside the window', async () => {
    const later = NOW + 30 * 86_400_000;
    const h = createHarness(calendar(event(['RRULE:FREQ=WEEKLY;COUNT=3'])));
    const source = await seedSource(h);
    expect(await sync(h, 'u-a', source.id)).toMatchObject({ created: 3, errors: 0 });
    const first = (await h.store.listMappings('u-a', source.id)).find((m) => m.occurrenceId === 'UTC:2026-10-02T01:00:00Z')!;
    h.setFeed(calendar(event(['RRULE:FREQ=WEEKLY;UNTIL=20261002T010000Z'])));
    expect(await sync(h, 'u-a', source.id, {}, later)).toMatchObject({ deleted: 2, errors: 0 });
    expect((await liveTasks(h)).map((t) => t.id)).toEqual([first.taskId]);
  });
});

describe('M15b purged terminal state', () => {
  it('marks the mapping purged when the snapshot holds a tombstone, and never writes it again', async () => {
    const h = createHarness();
    const source = await seedSource(h);
    await sync(h, 'u-a', source.id);
    const { taskId } = await onlyMapping(h, source.id);
    await devicePurge(h, 'u-a', 'task', taskId);
    const pushes = h.icsPushes();
    h.setFeed(calendar(event().replace('SUMMARY:Meeting', 'SUMMARY:Changed')));
    expect(await sync(h, 'u-a', source.id)).toMatchObject({ updated: 0, created: 0, errors: 0 });
    expect(h.icsPushes()).toBe(pushes);
    expect(await onlyMapping(h, source.id)).toMatchObject({ state: 'purged', taskId });

    h.setFeed(calendar(event().replace('SUMMARY:Meeting', 'SUMMARY:Changed again')));
    expect(await sync(h, 'u-a', source.id)).toMatchObject({ updated: 0, created: 0, errors: 0 });
    h.setFeed(calendar(event(['STATUS:CANCELLED'])));
    expect(await sync(h, 'u-a', source.id)).toMatchObject({ updated: 0, deleted: 0, errors: 0 });
    expect(h.icsPushes()).toBe(pushes);
    expect(await onlyMapping(h, source.id)).toMatchObject({ state: 'purged' });
  });

  it('marks the mapping purged when the push response carries purgedAt', async () => {
    const h = createHarness();
    const source = await seedSource(h);
    await sync(h, 'u-a', source.id);
    const { taskId } = await onlyMapping(h, source.id);
    h.setFeed(calendar(event().replace('SUMMARY:Meeting', 'SUMMARY:Changed')));
    h.hooks.beforeIcsPush = () => devicePurge(h, 'u-a', 'task', taskId);
    expect(await sync(h, 'u-a', source.id)).toMatchObject({ updated: 0 });
    expect(await onlyMapping(h, source.id)).toMatchObject({ state: 'purged' });

    const pushes = h.icsPushes();
    h.setFeed(calendar(event().replace('SUMMARY:Meeting', 'SUMMARY:Changed again')));
    expect(await sync(h, 'u-a', source.id)).toMatchObject({ updated: 0, created: 0, errors: 0 });
    expect(h.icsPushes()).toBe(pushes);
  });

  it('marks mappings purged when the push answers Project is purged', async () => {
    const h = createHarness();
    const source = await seedSource(h);
    await sync(h, 'u-a', source.id);
    // A new event is created while the owner purges the list mid-run.
    h.setFeed(calendar(event(), event([], 'new-one')));
    h.hooks.beforeIcsPush = () => devicePurge(h, 'u-a', 'project', 'p1');
    const stats = await sync(h, 'u-a', source.id);
    expect(stats.created).toBe(0);
    const fresh = (await h.store.listMappings('u-a', source.id)).find((m) => m.icsUid === 'new-one')!;
    expect(fresh.state).toBe('purged');
  });

  it('keeps the mapping on Forbidden and writes once write access is back', async () => {
    const h = createHarness();
    await seedSource(h);
    await seedUser(h, 'u-b', 'm-b');
    const invite = await createInvite(h.db, { userId: 'u-a', projectId: 'p1', role: 'editor', nowMs: Date.now() });
    await acceptInvite(h.db, { code: invite.code, userId: 'u-b', getScopeStub: h.getScopeStub, nowMs: Date.now() });
    const source = await h.store.addSource('u-b', { name: 'Team', url: FEED_URL, projectId: 'p1' });
    expect(await sync(h, 'u-b', source.id)).toMatchObject({ created: 1, errors: 0 });
    const applied = await onlyMapping(h, source.id, 'u-b');

    const setRole = (role: 'viewer' | 'editor') =>
      updateProjectMemberRole(h.db, {
        projectId: 'p1', targetUserId: 'u-b', requesterUserId: 'u-a', role, getScopeStub: h.getScopeStub, nowMs: Date.now(),
      });
    h.setFeed(calendar(event().replace('SUMMARY:Meeting', 'SUMMARY:Changed')));
    // Downgraded after the run checked the list (between markUpdating and the push, which reads
    // memberships before reaching the scope): the push itself is refused.
    const mark = h.store.markUpdating.bind(h.store);
    let downgradeOnce = true;
    h.store.markUpdating = async (...args) => {
      if (downgradeOnce) {
        downgradeOnce = false;
        await setRole('viewer');
      }
      await mark(...args);
    };
    const stats = await sync(h, 'u-b', source.id);
    expect(stats).toMatchObject({ updated: 0, errors: 1 });
    expect(stats.lastError).toContain('Forbidden');
    const kept = await onlyMapping(h, source.id, 'u-b');
    expect(kept.state).not.toBe('purged');
    expect(kept).toMatchObject({ taskId: applied.taskId, fingerprint: applied.fingerprint });
    expect(kept.lastError).toContain('Forbidden');

    await setRole('editor');
    expect(await sync(h, 'u-b', source.id)).toMatchObject({ updated: 1, errors: 0 });
    expect(await onlyMapping(h, source.id, 'u-b')).toMatchObject({ state: 'applied', lastError: null });
    expect(await taskOf(h, applied.taskId)).toMatchObject({ title: 'Changed' });
  });
});

describe('M15b syncDueSources', () => {
  it('syncs due sources one by one across users, and one failing source does not stop the rest', async () => {
    const h = createHarness();
    const good = await seedSource(h);
    await seedUser(h, 'u-b', 'm-b');
    const resB = await h.devicePush('u-b', [deviceOp(h, 'project', projectRow('pb', { ownerId: 'm-b' }))]);
    expect(resB.results[0]?.status).toBe('applied');
    const bad = await h.store.addSource('u-b', { name: 'Bad', url: BAD_URL, projectId: 'pb' });
    const broken = await h.store.addSource('u-b', { name: 'Broken', url: FEED_URL, projectId: 'pb' });
    const other = await h.store.addSource('u-b', { name: 'Good', url: FEED_URL, projectId: 'pb' });
    // A failure that escapes syncSource itself.
    const acquire = h.store.acquireLease.bind(h.store);
    h.store.acquireLease = async (userId, id, ...rest) => {
      if (id === broken.id) throw new Error('D1 unavailable');
      return acquire(userId, id, ...rest);
    };

    const results = await syncDueSources(h.deps, NOW);
    expect(results.map((r) => [r.source, r.userId, r.stats.errors])).toEqual([
      [good.id, 'u-a', 0],
      [bad.id, 'u-b', 1],
      [broken.id, 'u-b', 1],
      [other.id, 'u-b', 0],
    ]);
    expect(results[2]!.stats.lastError).toBe('D1 unavailable');
    expect((await liveTasks(h, 'u-a')).filter((t) => t.projectId === 'p1')).toHaveLength(1);
    expect((await liveTasks(h, 'u-b')).filter((t) => t.projectId === 'pb')).toHaveLength(1);
  });

  it('syncs at most five sources per run, least recently synced first', async () => {
    const h = createHarness();
    await seedSource(h);
    for (let i = 0; i < 6; i++) await h.store.addSource('u-a', { name: `S${i}`, url: FEED_URL, projectId: 'p1' });
    const first = await syncDueSources(h.deps, NOW);
    expect(first.map((r) => r.source)).toEqual([1, 2, 3, 4, 5]);
    const second = await syncDueSources(h.deps, NOW);
    expect(second.map((r) => r.source)).toEqual([6, 7]);
    expect(first.every((r) => r.stats.errors === 0 && typeof r.ms === 'number')).toBe(true);
  });
});

it('renews the lease before the removal push, so a lost lease writes nothing', async () => {
  const h = createHarness();
  const source = await seedSource(h);
  await sync(h, 'u-a', source.id);
  h.setFeed(calendar());
  const renew = h.store.renewLease.bind(h.store);
  h.store.renewLease = async (userId, id, token, ...rest) => {
    await h.store.releaseLease(userId, id, token);
    return renew(userId, id, token, ...rest);
  };
  expect(await sync(h, 'u-a', source.id)).toMatchObject({ errors: 1, deleted: 0 });
  expect(h.icsPushes()).toBe(1);
  expect(await h.store.listMappings('u-a', source.id)).toHaveLength(1);
});

// The run's clock is the one stamp every ICS write carries: updatedAt must equal the injected
// now (and the deletedAt / completedAt of the same write), not whatever Date.now() says later.
describe('ICS writes use the injected nowMs', () => {
  const LATER = NOW + 3_600_000;

  it('stamps createdAt and updatedAt of a new task with the run clock', async () => {
    const h = createHarness();
    const source = await seedSource(h);
    await sync(h, 'u-a', source.id);
    const { taskId } = await onlyMapping(h, source.id);
    expect(await taskOf(h, taskId)).toMatchObject({ createdAt: NOW, updatedAt: NOW });
  });

  it('stamps a trashed task with the same now for deletedAt and updatedAt', async () => {
    const h = createHarness();
    const source = await seedSource(h);
    await sync(h, 'u-a', source.id);
    const { taskId } = await onlyMapping(h, source.id);
    h.setFeed(calendar());
    await sync(h, 'u-a', source.id, {}, LATER);
    expect(await taskOf(h, taskId)).toMatchObject({ deletedAt: LATER, updatedAt: LATER });
  });

  it('stamps a cancelled task with the same now for completedAt and updatedAt', async () => {
    const h = createHarness();
    const source = await seedSource(h);
    await sync(h, 'u-a', source.id);
    const { taskId } = await onlyMapping(h, source.id);
    h.setFeed(calendar(event(['STATUS:CANCELLED'])));
    await sync(h, 'u-a', source.id, {}, LATER);
    expect(await taskOf(h, taskId)).toMatchObject({ status: 2, completedAt: LATER, updatedAt: LATER });
  });
});
