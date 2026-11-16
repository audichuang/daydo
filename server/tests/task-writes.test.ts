// serverops/taskWrites: the task writes MCP and ICS share, checked against the App's behaviour
// (LocalDayDoAPI). The pure builders run on hand-made snapshots; completeOccurrence runs against
// a real ScopeObject, with the App fixture where one exists.
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { parseRecurrence } from '../src/domain/recurrence';
import { addDays } from '../src/domain/schedule';
import { normalizeTagLabels } from '../src/domain/tags';
import { uuidv5 } from '../src/domain/uuid';
import { acceptInvite, createInvite } from '../src/sharing';
import {
  withCreated,
  type Snapshot,
  type SnapshotRow,
} from '../src/serverops/snapshot';
import {
  checklistIntents,
  completeOccurrence,
  completeTaskIntent,
  createTaskIntent,
  firstTaskSortKey,
  moveTaskIntent,
  newTaskIntents,
  patchTaskIntents,
  tagIntents,
  taskListDenial,
  trashTaskIntent,
} from '../src/serverops/taskWrites';
import { rowSchedule } from '../src/serverops/values';
import type { MembershipRole } from '../src/sync/entities';
import {
  type ScopePushInput,
} from './helpers/scopeWorld';
import {
  createServerHarness,
  deviceOp,
  NOW_ISH,
  projectRow,
  pulled,
  seedUser,
  taskRow,
} from './helpers/serverHarness';

// MARK: - Hand-made snapshots for the pure builders

type Entity = SnapshotRow['entity'];

function fakeSnapshot(
  rows: Array<[Entity, Record<string, unknown>, string?]>,
  memberships: Record<string, MembershipRole> = {},
): Snapshot {
  const all: SnapshotRow[] = rows.map(([entity, row, scope = 'u:u-a']) => ({ entity, scope, row, clocks: {}, serverSeq: 0 }));
  const roles = new Map(Object.entries(memberships));
  const keyOf = (r: SnapshotRow) => String(r.entity === 'tag' ? r.row.name : r.row.id);
  return {
    userId: 'u-a',
    meMemberId: 'm-a',
    inboxProjectId: null,
    memberships: roles,
    rows: (entity) => all.filter((r) => r.entity === entity),
    findRow: (entity, id) => all.find((r) => r.entity === entity && keyOf(r) === id),
    liveProjects: () => all.filter((r) => r.entity === 'project'),
    liveTasks: () => all.filter((r) => r.entity === 'task'),
    canWrite: (id) => roles.get(id) === 'owner' || roles.get(id) === 'editor',
  };
}

describe('taskListDenial', () => {
  const snap = fakeSnapshot(
    [
      ['project', { id: 'live' }],
      ['project', { id: 'shared' }],
      ['project', { id: 'trashed', deletedAt: NOW_ISH }],
      ['project', { id: 'purged', purgedAt: NOW_ISH }],
      ['project', { id: 'archived', archivedAt: NOW_ISH }],
      ['project', { id: 'archived-shared', archivedAt: NOW_ISH }],
      ['project', { id: 'trashed-shared', deletedAt: NOW_ISH }],
    ],
    { live: 'owner', shared: 'viewer', trashed: 'owner', purged: 'owner', archived: 'editor', 'archived-shared': 'viewer', 'trashed-shared': 'viewer' },
  );

  it.each([
    ['live', null, null],
    ['shared', 'read-only', 'read-only'],
    ['unknown', 'missing', 'missing'],
    ['trashed', 'missing', 'missing'],
    ['purged', 'missing', 'missing'],
    ['trashed-shared', 'missing', 'missing'],
    // MCP hides archived lists; an ICS subscription keeps writing to one it may write.
    ['archived', 'archived', null],
    ['archived-shared', 'archived', 'read-only'],
  ])('%s: %s for MCP, %s with allowArchived', (id, mcp, ics) => {
    expect(taskListDenial(snap, id)).toBe(mcp);
    expect(taskListDenial(snap, id, { allowArchived: true })).toBe(ics);
  });
});

describe('firstTaskSortKey', () => {
  it("is the list's smallest key, trashed and completed tasks included, other lists and blank keys ignored", () => {
    const snap = fakeSnapshot([
      ['task', { id: 'a', projectId: 'p1', sortKey: 'm' }],
      ['task', { id: 'b', projectId: 'p1', sortKey: '4', status: 2 }],
      ['task', { id: 'c', projectId: 'p1', sortKey: '2', deletedAt: NOW_ISH }],
      ['task', { id: 'd', projectId: 'p1', sortKey: '' }],
      ['task', { id: 'e', projectId: 'p1', sortKey: 7 }],
      ['task', { id: 'f', projectId: 'p2', sortKey: '1' }],
    ]);
    expect(firstTaskSortKey(snap, 'p1')).toBe('2');
    expect(firstTaskSortKey(snap, 'p3')).toBeNull();
  });

  it('compares by code unit, as the App does', () => {
    const snap = fakeSnapshot([
      ['task', { id: 'a', projectId: 'p1', sortKey: 'a' }],
      ['task', { id: 'b', projectId: 'p1', sortKey: 'Z' }],
      ['task', { id: 'c', projectId: 'p1', sortKey: 'a0' }],
    ]);
    expect(firstTaskSortKey(snap, 'p1')).toBe('Z');
  });
});

describe('task intents', () => {
  const columns = { projectId: 'p1', title: 'T', content: '', priority: 0, reminders: [], tags: [], sortKey: 'i' };

  it('creates an open task with the base columns first and only the extra columns given', () => {
    const intent = createTaskIntent('t1', columns, { importNote: 'ICS：Work', startDay: '2026-11-20' });
    expect(intent).toEqual({ entity: 'task', entityId: 't1', set: { id: 't1', ...columns, status: 0, importNote: 'ICS：Work', startDay: '2026-11-20' } });
    expect(Object.keys(intent.set)).toEqual([
      'id', 'projectId', 'title', 'content', 'priority', 'status', 'reminders', 'tags', 'sortKey', 'importNote', 'startDay',
    ]);
    expect(Object.keys(createTaskIntent('t1', columns).set)).not.toContain('repeatRule');
  });

  it('completes, trashes and moves with only the columns that change', () => {
    expect(completeTaskIntent('t1', 5)).toEqual({ entity: 'task', entityId: 't1', set: { status: 2, completedAt: 5 } });
    expect(trashTaskIntent('t1', 5)).toEqual({ entity: 'task', entityId: 't1', set: { deletedAt: 5 } });
    expect(moveTaskIntent('t1', 'p2')).toEqual({ entity: 'task', entityId: 't1', set: { projectId: 'p2' } });
  });

  it('keys a new task before every task in the list, and leaves out a null schedule and repeat rule', () => {
    const snap = fakeSnapshot([
      ['task', { id: 't-trash', projectId: 'p1', sortKey: '2', deletedAt: NOW_ISH }],
      ['task', { id: 't-done', projectId: 'p1', sortKey: '4', status: 2 }],
    ]);
    const [task, ...rest] = newTaskIntents(
      snap, 'u-a', 'new',
      { projectId: 'p1', title: 'first', content: '', priority: 0, reminders: [], tags: [], subtasks: [], schedule: null, repeatRule: null },
      NOW_ISH,
    );
    expect(task!.set.sortKey).toBe('1');
    expect(Object.keys(task!.set)).toEqual(['id', 'projectId', 'title', 'content', 'priority', 'status', 'reminders', 'tags', 'sortKey']);
    expect(rest).toEqual([]);
  });

  it('writes a new task with its schedule and repeat, then tag rows, then its checklist without blank titles', () => {
    const snap = fakeSnapshot([]);
    const schedule = { startDay: '2026-12-01', startMinute: 780, endDay: '2026-12-01', endMinute: 840, timeZone: 'Asia/Taipei' };
    const intents = newTaskIntents(
      snap, 'u-a', 'new',
      {
        projectId: 'p1', title: 'Dentist', content: '', priority: 5, reminders: ['TRIGGER:PT0S'],
        tags: normalizeTagLabels(['Work']), subtasks: ['bring card', '  ', 'pay'], schedule, repeatRule: 'RRULE:FREQ=WEEKLY',
      },
      NOW_ISH,
    );
    expect(intents.map((i) => i.entity)).toEqual(['task', 'tag', 'checklistItem', 'checklistItem']);
    expect(intents[0]!.set).toMatchObject({ tags: ['work'], repeatRule: 'RRULE:FREQ=WEEKLY', ...schedule });
    expect(Object.keys(intents[0]!.set).slice(-6)).toEqual(['repeatRule', 'startDay', 'startMinute', 'endDay', 'endMinute', 'timeZone']);
    expect(intents.slice(2).map((i) => [i.set.title, i.set.taskId])).toEqual([['bring card', 'new'], ['pay', 'new']]);
    expect(String(intents[2]!.set.sortKey) < String(intents[3]!.set.sortKey)).toBe(true);
  });

  it("creates missing tag rows after the user's last key, revives trashed ones and leaves live ones", () => {
    const snap = fakeSnapshot([
      ['tag', { name: 'old', label: 'Old', sortKey: 'i', deletedAt: NOW_ISH }],
      ['tag', { name: 'live', label: 'Live', sortKey: 'k' }],
      ['tag', { name: 'other', label: 'Other', sortKey: 'z' }, 'u:u-b'],
    ]);
    expect(tagIntents(snap, 'u-a', normalizeTagLabels(['Old', 'live', 'Fresh', 'Other']))).toEqual([
      { entity: 'tag', entityId: 'old', set: { deletedAt: null } },
      { entity: 'tag', entityId: 'fresh', set: { name: 'fresh', label: 'Fresh', sortKey: 's' } },
      { entity: 'tag', entityId: 'other', set: { name: 'other', label: 'Other', sortKey: 'w' } },
    ]);
  });

  it('builds checklist rows in order with fresh ids, skipping blank titles', () => {
    const intents = checklistIntents('t1', ['a', '', ' ', 'b'], NOW_ISH);
    expect(intents.map((i) => [i.set.title, i.set.status, i.set.taskId])).toEqual([['a', 0, 't1'], ['b', 0, 't1']]);
    expect(intents[0]!.entityId).toBe(intents[0]!.set.id);
    expect(intents[0]!.entityId).not.toBe(intents[1]!.entityId);
    expect(String(intents[0]!.set.sortKey) < String(intents[1]!.set.sortKey)).toBe(true);
  });
});

describe('patchTaskIntents', () => {
  const scheduled = {
    id: 't1', projectId: 'p1', startDay: '2026-11-20', startMinute: 540, endDay: '2026-11-20', endMinute: 600,
    timeZone: 'Asia/Taipei', reminders: ['TRIGGER:PT0S'], repeatRule: 'RRULE:FREQ=DAILY',
  };
  const snap = fakeSnapshot([
    ['task', scheduled],
    ['task', { id: 'dateless', projectId: 'p1' }],
    ['checklistItem', { id: 'c-old', taskId: 't1', title: 'old', sortKey: 'i' }],
    ['checklistItem', { id: 'c-trash', taskId: 't1', title: 'gone', sortKey: 'j', deletedAt: NOW_ISH }],
    ['checklistItem', { id: 'c-other', taskId: 'dateless', title: 'other', sortKey: 'k' }],
  ]);
  const task = snap.findRow('task', 't1')!;
  const dateless = snap.findRow('task', 'dateless')!;

  it('writes only the given columns, leaves an unchanged schedule out, and touches the task', () => {
    const intents = patchTaskIntents(snap, 'u-a', task, { title: 'Renamed', schedule: rowSchedule(task.row) }, NOW_ISH);
    expect(intents).toEqual([{ entity: 'task', entityId: 't1', set: { title: 'Renamed' }, touch: true }]);
  });

  it('sends all five schedule columns when the schedule changes', () => {
    const [intent] = patchTaskIntents(snap, 'u-a', task, { schedule: { ...rowSchedule(task.row)!, timeZone: 'Asia/Tokyo' } }, NOW_ISH)!;
    expect(intent!.set).toEqual({ startDay: '2026-11-20', startMinute: 540, endDay: '2026-11-20', endMinute: 600, timeZone: 'Asia/Tokyo' });
  });

  it('clears reminders and repeat with a cleared date, but not when the task had none', () => {
    const [cleared] = patchTaskIntents(snap, 'u-a', task, { schedule: null }, NOW_ISH)!;
    expect(cleared!.set).toMatchObject({ startDay: null, reminders: [], repeatRule: null });
    expect(patchTaskIntents(snap, 'u-a', dateless, { schedule: null }, NOW_ISH)).toBeNull();
  });

  it('replaces the whole checklist: live items are trashed, new ones appended', () => {
    const intents = patchTaskIntents(snap, 'u-a', task, { subtasks: ['new one', 'new two'] }, NOW_ISH)!;
    expect(intents[0]).toEqual({ entity: 'task', entityId: 't1', set: {}, touch: true });
    expect(intents[1]).toEqual({ entity: 'checklistItem', entityId: 'c-old', set: { deletedAt: NOW_ISH } });
    expect(intents.slice(2).map((i) => [i.set.title, i.set.taskId])).toEqual([['new one', 't1'], ['new two', 't1']]);
  });

  it('replaces the tags and writes their rows', () => {
    const intents = patchTaskIntents(snap, 'u-a', task, { tags: normalizeTagLabels(['Fresh']) }, NOW_ISH)!;
    expect(intents.map((i) => [i.entity, i.set.tags ?? i.set.name])).toEqual([['task', ['fresh']], ['tag', 'fresh']]);
  });

  it('is null when nothing would be written, an empty checklist on a task without items included', () => {
    expect(patchTaskIntents(snap, 'u-a', task, {}, NOW_ISH)).toBeNull();
    const bare = fakeSnapshot([['task', { id: 'bare', projectId: 'p1' }]]);
    expect(patchTaskIntents(bare, 'u-a', bare.findRow('task', 'bare')!, { subtasks: [] }, NOW_ISH)).toBeNull();
  });
});

// MARK: - completeOccurrence against a real scope

function createHarness() {
  const hooks: {
    /** One-shot: runs before the next server push reaches the scope (a phone edit in between). */
    beforeServerPush?: () => Promise<unknown>;
    /** One-shot: makes the matching push throw before the scope applies it (a DO failure). */
    failPush?: (input: ScopePushInput) => boolean;
  } = {};
  const world = createServerHarness({
    onPush: async (input, proceed) => {
      if (input.deviceId === 'mcp' && hooks.beforeServerPush) {
        const hook = hooks.beforeServerPush;
        hooks.beforeServerPush = undefined;
        await hook();
      }
      if (hooks.failPush?.(input)) {
        hooks.failPush = undefined;
        throw new Error(`injected failure in ${input.scope}`);
      }
      return proceed(input);
    },
  });
  return { ...world, hooks };
}

type Harness = ReturnType<typeof createHarness>;

/** p1 with a weekly 09:00 task `rep` from 2026-11-15 (Asia/Taipei). */
async function seedRepeating(h: Harness, extra: Record<string, unknown> = {}) {
  await seedUser(h, 'u-a', 'm-a');
  const res = await h.devicePush('u-a', [
    deviceOp(h, 'project', projectRow('p1')),
    deviceOp(
      h,
      'task',
      taskRow('rep', 'p1', {
        title: 'Weekly sync', startDay: '2026-11-15', startMinute: 540, endDay: '2026-11-15', endMinute: 600,
        timeZone: 'Asia/Taipei', repeatRule: 'RRULE:FREQ=WEEKLY', reminders: ['TRIGGER:PT0S'], tags: ['work'],
        ...extra,
      }),
    ),
  ]);
  expect(res.results.map((r) => r.status)).toEqual(['applied', 'applied']);
}

const serverCalls = (h: Harness) => h.calls.filter((c) => c.deviceId === 'mcp');
const serverOps = (h: Harness) => serverCalls(h).flatMap((c) => c.ops);

/** Completes the current occurrence of `taskId` as `userId` would through any server caller. */
async function complete(h: Harness, userId: string, taskId: string, defaultTimeZone = 'Asia/Taipei') {
  const snapshot = await h.snapshot(userId);
  const task = snapshot.findRow('task', taskId)!;
  const rule = parseRecurrence(String(task.row.repeatRule))!;
  const result = await completeOccurrence(h.deps(userId), snapshot, task, rule, rowSchedule(task.row)!, {
    defaultTimeZone,
    nowMs: Date.now(),
  });
  const view = withCreated(snapshot, result.outcomes);
  const items = view
    .rows('checklistItem')
    .filter((c) => c.row.taskId === result.copyId)
    .sort((a, b) => (String(a.row.sortKey) < String(b.row.sortKey) ? -1 : 1))
    .map((c) => c.row);
  return { ...result, copy: view.findRow('task', result.copyId)?.row, items };
}

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const FIXTURE = JSON.parse(readFileSync(path.resolve(__dirname, '../../spec/fixtures/sync-ops.json'), 'utf8')) as {
  ops: Array<Record<string, any>>;
};
const FIX_NOW = 1794715200000; // 2026-11-15 12:00 Asia/Taipei, the App's clock when it wrote the fixture
const FIX_TASK_ID = '01a1dd5b-fc89-75e1-b4c4-fb62891e2107';
const FIX_COPY_ID = 'cc64dbd5-1983-5448-8442-0fba63492416';
const FIX_ITEM_COPY_ID = '9295d8c6-ba7b-5466-a4b7-0a5a17b4e573';
const FIX_MEMBER_ID = '01a1dd5b-fc85-7f74-88e6-a04f8baa6fc6';

/** The fixture op that writes `entityId`, the n-th one when it is written several times. */
function fixtureOp(entityId: string, nth = 0): Record<string, any> {
  const op = FIXTURE.ops.filter((o) => o.entityId === entityId)[nth];
  if (!op) throw new Error(`fixture has no op #${nth} for ${entityId}`);
  return op;
}

const isV7 = (id: string) => /^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(id);
const repCopyId = (day = '2026-11-15', minute: string | number = 540) => uuidv5(`rep|${day}|${minute}`);

describe('completeOccurrence', () => {
  beforeEach(() => {
    vi.useFakeTimers({ toFake: ['Date'] });
    vi.setSystemTime(FIX_NOW);
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it('matches the App fixture: v5 copy, checklist copy, then the original moved to the next week', async () => {
    const h = createHarness();
    const project = fixtureOp('01a1dd5b-fc88-7f98-9743-8bbff3400c35').row;
    const task = fixtureOp(FIX_TASK_ID).row;
    const item = fixtureOp('01a1dd5b-fc8a-7648-b8cc-9f08d7e42a43').row;
    await seedUser(h, 'u-a', FIX_MEMBER_ID);
    const seeded = await h.devicePush('u-a', [deviceOp(h, 'project', project), deviceOp(h, 'task', task), deviceOp(h, 'checklistItem', item)]);
    expect(seeded.results.map((r) => r.status)).toEqual(['applied', 'applied', 'applied']);
    h.calls.length = 0;

    const r = await complete(h, 'u-a', FIX_TASK_ID);
    expect(r.copyId).toBe(FIX_COPY_ID);
    expect(r.outcomes.map((o) => o.entityId)).toEqual([FIX_COPY_ID, FIX_ITEM_COPY_ID]);
    // Copy, then checklist, then original, each in its own push.
    const calls = serverCalls(h);
    expect(calls.map((c) => c.ops.map((o) => o.entityId))).toEqual([[FIX_COPY_ID], [FIX_ITEM_COPY_ID], [FIX_TASK_ID]]);
    const [copyOp, itemOp] = [calls[0]!.ops[0]!, calls[1]!.ops[0]!];
    const fixCopy = fixtureOp(FIX_COPY_ID);
    const fixItem = fixtureOp(FIX_ITEM_COPY_ID);
    expect([...(copyOp.fields as string[])].sort()).toEqual([...fixCopy.fields].sort());
    expect(copyOp.row).toEqual(fixCopy.row);
    expect([...(itemOp.fields as string[])].sort()).toEqual([...fixItem.fields].sort());
    expect(itemOp.row).toEqual(fixItem.row);

    const fixMoved = fixtureOp(FIX_TASK_ID, 1).row;
    const res = await h.pull('u-a');
    expect(pulled(res, 'task', FIX_TASK_ID)).toMatchObject({
      startDay: fixMoved.startDay, endDay: fixMoved.endDay, startMinute: 1140, endMinute: 1230,
      status: 0, repeatRule: 'RRULE:FREQ=WEEKLY', updatedAt: fixMoved.updatedAt,
    });
    expect(pulled(res, 'task', FIX_COPY_ID)).toMatchObject({ status: 2, completedAt: FIX_NOW, startDay: '2026-11-15' });
    expect(pulled(res, 'checklistItem', FIX_ITEM_COPY_ID)).toMatchObject({ taskId: FIX_COPY_ID, title: '準備章節摘要' });
  });

  it('copies live checklist items with their status, then reopens the done originals in a later push', async () => {
    const h = createHarness();
    await seedRepeating(h);
    await h.devicePush('u-a', [
      deviceOp(h, 'checklistItem', { id: 'c1', taskId: 'rep', title: 'done one', status: 1, sortKey: 'a0', createdAt: NOW_ISH, updatedAt: NOW_ISH }),
      deviceOp(h, 'checklistItem', { id: 'c2', taskId: 'rep', title: 'open one', status: 0, sortKey: 'b', createdAt: NOW_ISH, updatedAt: NOW_ISH }),
      deviceOp(h, 'checklistItem', { id: 'c3', taskId: 'rep', title: 'trashed', status: 0, sortKey: 'c', createdAt: NOW_ISH, updatedAt: NOW_ISH, deletedAt: NOW_ISH }),
    ]);
    h.calls.length = 0;
    const r = await complete(h, 'u-a', 'rep');
    const copyId = await repCopyId();
    const [c1Copy, c2Copy] = [await uuidv5(`${copyId}|c1`), await uuidv5(`${copyId}|c2`)];
    expect(r.items.map((i) => [i.id, i.title, i.status])).toEqual([[c1Copy, 'done one', 1], [c2Copy, 'open one', 0]]);
    const statuses = (n: number) => serverCalls(h)[n]!.ops.map((o) => [o.entityId, (o.row as Record<string, unknown>).status]);
    expect(statuses(1)).toEqual([[c1Copy, 1], [c2Copy, 0]]);
    expect(statuses(2)).toEqual([['c1', 0]]);
    const res = await h.pull('u-a');
    expect(pulled(res, 'checklistItem', 'c1')).toMatchObject({ status: 0, taskId: 'rep' });
    expect(pulled(res, 'checklistItem', c1Copy)).toMatchObject({ status: 1, taskId: copyId, sortKey: 'a0' });
  });

  it('uses a v7 copy id when the snapshot already holds a tombstone for the v5 id', async () => {
    const h = createHarness();
    await seedRepeating(h);
    const v5 = await repCopyId();
    await h.devicePush('u-a', [deviceOp(h, 'task', taskRow(v5, 'p1', { status: 2, completedAt: NOW_ISH }))]);
    await h.devicePush('u-a', [{ opId: 'dev-del-copy', hlc: h.deviceHlc(), entity: 'task', entityId: v5, op: 'delete', fields: [], row: {} }]);
    expect((await h.snapshot('u-a')).findRow('task', v5)?.row.purgedAt).toBeTypeOf('number');
    h.calls.length = 0;

    const r = await complete(h, 'u-a', 'rep');
    expect(isV7(r.copyId)).toBe(true);
    expect(serverOps(h).some((o) => o.entityId === v5)).toBe(false);
    expect(serverCalls(h).map((c) => c.ops.map((o) => o.entityId))).toEqual([[r.copyId], ['rep']]);
    expect(pulled(await h.pull('u-a'), 'task', r.copyId)).toMatchObject({ status: 2, title: 'Weekly sync' });
  });

  it('resends the copy with a v7 id when the push answers with a tombstone missing from the snapshot', async () => {
    const h = createHarness();
    await seedRepeating(h);
    await h.devicePush('u-a', [
      deviceOp(h, 'checklistItem', { id: 'c1', taskId: 'rep', title: 'item', status: 0, sortKey: 'i', createdAt: NOW_ISH, updatedAt: NOW_ISH }),
    ]);
    const v5 = await repCopyId();
    h.hooks.beforeServerPush = () =>
      h.devicePush('u-a', [
        deviceOp(h, 'task', taskRow(v5, 'p1', { status: 2, completedAt: NOW_ISH })),
        { opId: 'dev-del-copy', hlc: h.deviceHlc(), entity: 'task', entityId: v5, op: 'delete', fields: [], row: {} },
      ]);
    h.calls.length = 0;

    const r = await complete(h, 'u-a', 'rep');
    expect(isV7(r.copyId)).toBe(true);
    const itemCopy = await uuidv5(`${r.copyId}|c1`);
    expect(serverCalls(h).map((c) => c.ops.map((o) => o.entityId))).toEqual([[v5], [r.copyId], [itemCopy], ['rep']]);
    expect(serverOps(h).filter((o) => o.entity === 'checklistItem').every((o) => (o.row as Record<string, unknown>).taskId === r.copyId)).toBe(true);
    const res = await h.pull('u-a');
    expect(pulled(res, 'task', 'rep')).toMatchObject({ startDay: '2026-11-22' });
    expect(pulled(res, 'task', r.copyId)).toMatchObject({ status: 2, startDay: '2026-11-15' });
    expect(pulled(res, 'checklistItem', itemCopy)).toMatchObject({ taskId: r.copyId });
  });

  it('only completes an existing open copy, and leaves an existing completed copy alone', async () => {
    const h = createHarness();
    await seedRepeating(h);
    const v5 = await repCopyId();
    await h.devicePush('u-a', [deviceOp(h, 'task', taskRow(v5, 'p1', { title: 'old copy' }))]);
    h.calls.length = 0;
    const r = await complete(h, 'u-a', 'rep');
    expect(r.copyId).toBe(v5);
    expect(r.copy).toMatchObject({ status: 2, title: 'old copy' });
    const copyOp = serverCalls(h)[0]!.ops[0]!;
    expect(copyOp.entityId).toBe(v5);
    expect([...(copyOp.fields as string[])].sort()).toEqual(['completedAt', 'status', 'updatedAt']);

    // Move the original back onto the same occurrence: the completed copy is reused, not rewritten.
    await h.devicePush('u-a', [
      deviceOp(h, 'task', { id: 'rep', startDay: '2026-11-15', startMinute: 540, endDay: '2026-11-15', endMinute: 600, timeZone: 'Asia/Taipei' }, h.deviceHlc(FIX_NOW + 10)),
    ]);
    h.calls.length = 0;
    const again = await complete(h, 'u-a', 'rep');
    expect(again.copyId).toBe(v5);
    expect(again.outcomes).toEqual([]);
    expect(serverCalls(h).map((c) => c.ops.map((o) => o.entityId))).toEqual([['rep']]);
  });

  it('rebuilds a trashed copy from the original, keeping its createdAt', async () => {
    const h = createHarness();
    await seedRepeating(h);
    const v5 = await repCopyId();
    await h.devicePush('u-a', [
      deviceOp(h, 'task', taskRow(v5, 'p1', { title: 'stale', createdAt: 123, deletedAt: NOW_ISH, importNote: 'old note' })),
    ]);
    const r = await complete(h, 'u-a', 'rep');
    expect(r.copyId).toBe(v5);
    const row = pulled(await h.pull('u-a'), 'task', v5);
    expect(row).toMatchObject({ status: 2, title: 'Weekly sync', startDay: '2026-11-15', createdAt: 123 });
    expect([row?.deletedAt ?? null, row?.repeatRule ?? null, row?.importNote ?? null]).toEqual([null, null, null]);
  });

  it('catches up to today in the task zone', async () => {
    const h = createHarness();
    await seedRepeating(h, { startDay: '2026-11-01', endDay: '2026-11-01', repeatRule: 'RRULE:FREQ=DAILY' });
    const r = await complete(h, 'u-a', 'rep');
    expect(r.copyId).toBe(await repCopyId('2026-11-01'));
    expect(pulled(await h.pull('u-a'), 'task', 'rep')).toMatchObject({ startDay: '2026-11-15', endDay: '2026-11-15' });
  });

  it('takes today from the task zone, or from defaultTimeZone for a floating task', async () => {
    vi.setSystemTime(Date.parse('2026-11-15T17:00:00Z')); // 2026-11-16 01:00 in Asia/Taipei
    const cases = [
      ['UTC', 'Asia/Taipei', '2026-11-15'],
      ['Asia/Taipei', 'UTC', '2026-11-16'],
      [null, 'Asia/Taipei', '2026-11-16'],
      [null, 'UTC', '2026-11-15'],
    ] as const;
    for (const [timeZone, defaultTimeZone, expected] of cases) {
      const h = createHarness();
      await seedRepeating(h, { startDay: '2026-11-10', endDay: '2026-11-10', timeZone, repeatRule: 'RRULE:FREQ=DAILY' });
      await complete(h, 'u-a', 'rep', defaultTimeZone);
      expect(pulled(await h.pull('u-a'), 'task', 'rep')?.startDay, `${timeZone} / ${defaultTimeZone}`).toBe(expected);
    }
  });

  it('stops catching up after 1000 steps, as the App does', async () => {
    const h = createHarness();
    await seedRepeating(h, { startDay: '2020-01-01', endDay: '2020-01-01', repeatRule: 'RRULE:FREQ=DAILY' });
    await complete(h, 'u-a', 'rep');
    const moved = addDays('2020-01-01', 1001);
    expect(pulled(await h.pull('u-a'), 'task', 'rep')).toMatchObject({ startDay: moved, endDay: moved });
  });

  it('uses an empty minute part for all-day occurrences', async () => {
    const h = createHarness();
    await seedRepeating(h, { startMinute: null, endMinute: null, timeZone: null, reminders: [] });
    expect((await complete(h, 'u-a', 'rep')).copyId).toBe(await repCopyId('2026-11-15', ''));
  });

  it('keeps the done checklist items on the original when storing their copies fails, so a retry copies them done', async () => {
    const h = createHarness();
    await seedRepeating(h);
    await h.devicePush('u-a', [
      deviceOp(h, 'checklistItem', { id: 'c1', taskId: 'rep', title: 'done one', status: 1, sortKey: 'a0', createdAt: NOW_ISH, updatedAt: NOW_ISH }),
    ]);
    await seedUser(h, 'u-b', 'm-b');
    const invite = await createInvite(h.db, { userId: 'u-a', projectId: 'p1', role: 'editor', nowMs: Date.now() });
    await acceptInvite(h.db, { code: invite.code, userId: 'u-b', getScopeStub: (s) => h.deps('u-b').getScopeStub(s), nowMs: Date.now() });
    // The copies live in u-b's scope, the original item in u-a's: fail the copy side once.
    h.hooks.failPush = (input) =>
      input.deviceId === 'mcp' && input.scope === 'u:u-b' && input.ops.some((o) => (o as { entity: string }).entity === 'checklistItem');

    await expect(complete(h, 'u-b', 'rep')).rejects.toThrow();
    let res = await h.pull('u-a');
    expect(pulled(res, 'checklistItem', 'c1')).toMatchObject({ status: 1 });
    expect(pulled(res, 'task', 'rep')).toMatchObject({ startDay: '2026-11-15' });

    const retry = await complete(h, 'u-b', 'rep');
    expect(retry.items.map((i) => [i.title, i.status])).toEqual([['done one', 1]]);
    res = await h.pull('u-a');
    expect(pulled(res, 'checklistItem', 'c1')).toMatchObject({ status: 0 });
    expect(pulled(res, 'task', 'rep')).toMatchObject({ startDay: '2026-11-22' });
  });

  it('refuses a rule whose next occurrence cannot be computed before writing anything', async () => {
    const h = createHarness();
    await seedRepeating(h, { repeatRule: 'RRULE:FREQ=YEARLY;INTERVAL=8000' });
    h.calls.length = 0;
    await expect(complete(h, 'u-a', 'rep')).rejects.toThrow();
    expect(serverCalls(h)).toEqual([]);
    expect(pulled(await h.pull('u-a'), 'task', await repCopyId())).toBeUndefined();
  });
});
