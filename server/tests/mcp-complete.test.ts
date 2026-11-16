import { drizzle } from 'drizzle-orm/d1';
import { eq } from 'drizzle-orm';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import * as schema from '../db/schema';
import { acceptInvite, createInvite } from '../src/sharing';
import { createServerHlcClock } from '../src/sync/hlc';
import { executeSyncPush, type ScopeStub } from '../src/sync/push';
import { loadSnapshot } from '../src/serverops/snapshot';
import { executeSyncPull } from '../src/sync/pull';
import { handleToolCall, HINTS, TOOL_DEFS } from '../src/mcp/registry';
import { addDays } from '../src/domain/schedule';
import { uuidv5 } from '../src/domain/uuid';
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

interface PushCall {
  scope: string;
  deviceId: string;
  ops: Array<Record<string, unknown>>;
}

function createHarness() {
  const { db } = createTestD1();
  const scopes = new Map<string, InstanceType<typeof ScopeObject>>();
  const calls: PushCall[] = [];
  // One-shot: runs before the next MCP push reaches the scope (simulates a phone edit in between).
  const hooks: {
    beforeMcpPush?: () => Promise<unknown>;
    // One-shot: makes the matching push throw before the scope applies it (a DO failure).
    failPush?: (input: Parameters<ScopeStub['push']>[0]) => boolean;
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
            if (input.deviceId === 'mcp' && hooks.beforeMcpPush) {
              const hook = hooks.beforeMcpPush;
              hooks.beforeMcpPush = undefined;
              await hook();
            }
            if (hooks.failPush?.(input)) {
              hooks.failPush = undefined;
              throw new Error(`injected failure in ${input.scope}`);
            }
            calls.push({
              scope: input.scope,
              deviceId: input.deviceId,
              ops: input.ops as Array<Record<string, unknown>>,
            });
            return target.push(input);
          };
        }
        const v = Reflect.get(target, prop, receiver) as unknown;
        return typeof v === 'function' ? (v as (...a: unknown[]) => unknown).bind(target) : v;
      },
    });
  };
  let seq = 0;
  // Device HLCs sit in the past unless a test asks for a lead.
  const deviceHlc = (ms = Date.now() - 60_000) => `${ms}:${String(seq++ % 10000).padStart(4, '0')}:dev-a`;
  const devicePush = (userId: string, ops: unknown[]) =>
    executeSyncPush(db, { userId, deviceId: 'dev-a', ops, getScopeStub, clock });
  const deps = (userId: string) => ({ db, userId, deviceId: 'mcp' as const, getScopeStub, clock });
  const snapshot = (userId: string) => loadSnapshot(db, userId, getScopeStub);
  const pull = (userId: string) => executeSyncPull(db, { userId, cursors: {}, limit: 1000, getScopeStub });
  return { db, calls, hooks, deviceHlc, devicePush, deps, snapshot, pull };
}

type Harness = ReturnType<typeof createHarness>;

const NOW_ISH = 1_700_000_000_000;

function projectRow(id: string, extra: Record<string, unknown> = {}) {
  return {
    id, name: id, viewMode: 'list', kind: 'TASK', isInbox: false, ownerId: 'm-a',
    sortKey: 'a0', showInSmart: 'all', notifyMode: 'all', createdAt: NOW_ISH, updatedAt: NOW_ISH,
    ...extra,
  };
}

function taskRow(id: string, projectId: string, extra: Record<string, unknown> = {}) {
  return {
    id, projectId, title: id, content: '', priority: 0, status: 0, sortKey: 'a0',
    reminders: [], tags: [], createdAt: NOW_ISH, updatedAt: NOW_ISH, ...extra,
  };
}

function deviceOp(h: Harness, entity: string, row: Record<string, unknown>, hlc = h.deviceHlc()) {
  return {
    opId: `dev-${entity}-${String(row.id)}-${hlc}`,
    hlc,
    entity,
    entityId: String(row.id),
    op: 'upsert',
    fields: Object.keys(row),
    row,
  };
}

async function seedUser(h: Harness, userId: string, memberId: string | null, withInbox = true) {
  await h.db.insert(schema.user).values({
    id: userId, name: userId, initial: userId[0], color: '#007AFF', avatarUrl: null,
    createdAt: NOW_ISH,
  });
  if (memberId) {
    await h.db.update(schema.user).set({ meMemberId: memberId }).where(eq(schema.user.id, userId));
  }
  if (withInbox) {
    const res = await h.devicePush(userId, [
      deviceOp(h, 'project', projectRow(`inbox-${userId}`, { isInbox: true, ownerId: memberId ?? '' })),
    ]);
    expect(res.results[0]?.status).toBe('applied');
  }
}

/** u-a with inbox, list p1 and task t1 (scheduled). */
async function seedBasic(h: Harness) {
  await seedUser(h, 'u-a', 'm-a');
  const res = await h.devicePush('u-a', [
    deviceOp(h, 'project', projectRow('p1')),
    deviceOp(
      h,
      'task',
      taskRow('t1', 'p1', {
        startDay: '2026-11-20', startMinute: 540, endDay: '2026-11-20', endMinute: 600,
        timeZone: 'Asia/Taipei', reminders: ['TRIGGER:PT0S'],
      }),
    ),
  ]);
  expect(res.results.map((r) => r.status)).toEqual(['applied', 'applied']);
}


async function call(h: Harness, userId: string, name: string, args: Record<string, unknown> = {}) {
  const res = await handleToolCall(name, args, {
    userId,
    clientId: 'test',
    services: { db: h.db, getScopeStub: h.deps(userId).getScopeStub },
  });
  const text = res.content[0]!.text;
  return { isError: res.isError === true, text, json: res.isError ? null : (JSON.parse(text) as any) };
}

/** u-a (owner of p1, with t1), u-b as `role` on p1. */
async function seedShared(h: Harness, role: 'viewer' | 'editor') {
  await seedBasic(h);
  await seedUser(h, 'u-b', 'm-b');
  const invite = await createInvite(h.db, { userId: 'u-a', projectId: 'p1', role, nowMs: Date.now() });
  await acceptInvite(h.db, {
    code: invite.code, userId: 'u-b', getScopeStub: (s) => h.deps('u-b').getScopeStub(s), nowMs: Date.now(),
  });
}


type PullRes = Awaited<ReturnType<Harness['pull']>>;

function pulled(res: PullRes, entity: string, key: string): Record<string, unknown> | undefined {
  for (const s of res.scopes) {
    for (const r of s.rows) {
      if (r.entity !== entity || 'gone' in r) continue;
      const id = entity === 'tag' ? r.row.name : r.row.id;
      if (id === key) return r.row as Record<string, unknown>;
    }
  }
  return undefined;
}

const mcpOps = (h: Harness) => h.calls.filter((c) => c.deviceId === 'mcp').flatMap((c) => c.ops);

const mcpCalls = (h: Harness) => h.calls.filter((c) => c.deviceId === 'mcp');

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const fixturePath = path.resolve(__dirname, '../../spec/fixtures/sync-ops.json');
const FIXTURE = JSON.parse(readFileSync(fixturePath, 'utf8')) as { ops: Array<Record<string, any>> };
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

const repCopyId = (day = '2026-11-15', minute: string | number = 540) => uuidv5(`rep|${day}|${minute}`);

beforeEach(() => {
  vi.useFakeTimers({ toFake: ['Date'] });
  vi.setSystemTime(FIX_NOW);
});

afterEach(() => {
  vi.useRealTimers();
});

describe('M12 registry', () => {
  it('registers complete_task as idempotent-write without TickTick or habit wording', () => {
    const def = TOOL_DEFS.find((t) => t.name === 'complete_task');
    expect(def).toBeDefined();
    expect(HINTS.complete_task).toBe('idempotent-write');
    expect(def!.description).not.toMatch(/ticktick|habit/i);
    expect(def!.inputSchema.required).toEqual(['project_id', 'task_id']);
  });
});

describe('M12 complete_task, one-off tasks', () => {
  it('writes status=2 with completedAt and returns the completed task', async () => {
    const h = createHarness();
    await seedBasic(h);
    h.calls.length = 0;
    const r = await call(h, 'u-a', 'complete_task', { project_id: 'p1', task_id: 't1' });
    expect(r.isError, r.text).toBe(false);
    expect(r.json).toMatchObject({ id: 't1', status: 2, completed_at: FIX_NOW });
    const ops = mcpOps(h);
    expect(ops).toHaveLength(1);
    expect(ops[0]!.row).toMatchObject({ id: 't1', status: 2, completedAt: FIX_NOW });
    expect(pulled(await h.pull('u-a'), 'task', 't1')).toMatchObject({ status: 2, completedAt: FIX_NOW });
  });

  it('returns an already completed task unchanged without pushing', async () => {
    const h = createHarness();
    await seedBasic(h);
    await h.devicePush('u-a', [deviceOp(h, 'task', { id: 't1', status: 2, completedAt: 123 })]);
    h.calls.length = 0;
    const r = await call(h, 'u-a', 'complete_task', { project_id: 'p1', task_id: 't1' });
    expect(r.isError, r.text).toBe(false);
    expect(r.json).toMatchObject({ id: 't1', status: 2, completed_at: 123 });
    expect(mcpCalls(h)).toEqual([]);
  });

  it('errors when the task is in another project, and for viewers, without pushing', async () => {
    const h = createHarness();
    await seedShared(h, 'viewer');
    h.calls.length = 0;
    const wrong = await call(h, 'u-a', 'complete_task', { project_id: 'inbox-u-a', task_id: 't1' });
    expect(wrong.isError).toBe(true);
    expect(wrong.text).toContain('not in project');
    const viewer = await call(h, 'u-b', 'complete_task', { project_id: 'p1', task_id: 't1' });
    expect(viewer.isError).toBe(true);
    expect(viewer.text).toContain('read-only');
    expect(mcpCalls(h)).toEqual([]);
  });
});

describe('M12 complete_task, repeating tasks', () => {
  it('matches the App fixture: v5 copy, checklist copy, then the original moved to the next week', async () => {
    const h = createHarness();
    const project = fixtureOp('01a1dd5b-fc88-7f98-9743-8bbff3400c35').row;
    const task = fixtureOp(FIX_TASK_ID).row;
    const item = fixtureOp('01a1dd5b-fc8a-7648-b8cc-9f08d7e42a43').row;
    await seedUser(h, 'u-a', FIX_MEMBER_ID);
    const seeded = await h.devicePush('u-a', [
      deviceOp(h, 'project', project),
      deviceOp(h, 'task', task),
      deviceOp(h, 'checklistItem', item),
    ]);
    expect(seeded.results.map((r) => r.status)).toEqual(['applied', 'applied', 'applied']);
    h.calls.length = 0;

    const r = await call(h, 'u-a', 'complete_task', { project_id: project.id, task_id: FIX_TASK_ID });
    expect(r.isError, r.text).toBe(false);
    expect(r.json).toMatchObject({ id: FIX_COPY_ID, status: 2, completed_at: FIX_NOW, repeat: null, title: '每週讀書會' });
    expect(r.json.items.map((i: any) => i.id)).toEqual([FIX_ITEM_COPY_ID]);

    // Copy, then checklist, then original, each in its own push.
    const calls = mcpCalls(h);
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

  it('copies live checklist items with their status and reopens the done ones on the original', async () => {
    const h = createHarness();
    await seedRepeating(h);
    await h.devicePush('u-a', [
      deviceOp(h, 'checklistItem', { id: 'c1', taskId: 'rep', title: 'done one', status: 1, sortKey: 'a0', createdAt: NOW_ISH, updatedAt: NOW_ISH }),
      deviceOp(h, 'checklistItem', { id: 'c2', taskId: 'rep', title: 'open one', status: 0, sortKey: 'b', createdAt: NOW_ISH, updatedAt: NOW_ISH }),
      deviceOp(h, 'checklistItem', { id: 'c3', taskId: 'rep', title: 'trashed', status: 0, sortKey: 'c', createdAt: NOW_ISH, updatedAt: NOW_ISH, deletedAt: NOW_ISH }),
    ]);
    h.calls.length = 0;
    const r = await call(h, 'u-a', 'complete_task', { project_id: 'p1', task_id: 'rep' });
    expect(r.isError, r.text).toBe(false);
    const copyId = await repCopyId();
    const [c1Copy, c2Copy] = [await uuidv5(`${copyId}|c1`), await uuidv5(`${copyId}|c2`)];
    expect(r.json.items.map((i: any) => [i.id, i.title, i.status])).toEqual([
      [c1Copy, 'done one', 1],
      [c2Copy, 'open one', 0],
    ]);
    const checklistPush = mcpCalls(h)[1]!.ops.map((o) => [o.entityId, (o.row as Record<string, unknown>).status]);
    // Per item, as the App: copy, then reopen the original.
    // Copies first; the done originals are reopened only once every copy is stored.
    expect(checklistPush).toEqual([[c1Copy, 1], [c2Copy, 0]]);
    expect(mcpCalls(h)[2]!.ops.map((o) => [o.entityId, (o.row as Record<string, unknown>).status])).toEqual([['c1', 0]]);
    const res = await h.pull('u-a');
    expect(pulled(res, 'checklistItem', 'c1')).toMatchObject({ status: 0, taskId: 'rep' });
    expect(pulled(res, 'checklistItem', c1Copy)).toMatchObject({ status: 1, taskId: copyId, sortKey: 'a0' });
  });

  it('uses a v7 copy id when the snapshot already holds a tombstone for the v5 id', async () => {
    const h = createHarness();
    await seedRepeating(h);
    const v5 = await repCopyId();
    await h.devicePush('u-a', [deviceOp(h, 'task', taskRow(v5, 'p1', { status: 2, completedAt: NOW_ISH }))]);
    await h.devicePush('u-a', [
      { opId: 'dev-del-copy', hlc: h.deviceHlc(), entity: 'task', entityId: v5, op: 'delete', fields: [], row: {} },
    ]);
    expect((await h.snapshot('u-a')).findRow('task', v5)?.row.purgedAt).toBeTypeOf('number');
    h.calls.length = 0;

    const r = await call(h, 'u-a', 'complete_task', { project_id: 'p1', task_id: 'rep' });
    expect(r.isError, r.text).toBe(false);
    expect(isV7(r.json.id)).toBe(true);
    expect(mcpOps(h).some((o) => o.entityId === v5)).toBe(false);
    expect(mcpCalls(h).map((c) => c.ops.map((o) => o.entityId))).toEqual([[r.json.id], ['rep']]);
    expect(pulled(await h.pull('u-a'), 'task', r.json.id)).toMatchObject({ status: 2, title: 'Weekly sync' });
  });

  it('resends the copy with a v7 id when the push answers with a tombstone missing from the snapshot', async () => {
    const h = createHarness();
    await seedRepeating(h);
    await h.devicePush('u-a', [
      deviceOp(h, 'checklistItem', { id: 'c1', taskId: 'rep', title: 'item', status: 0, sortKey: 'i', createdAt: NOW_ISH, updatedAt: NOW_ISH }),
    ]);
    const v5 = await repCopyId();
    h.hooks.beforeMcpPush = () =>
      h.devicePush('u-a', [
        deviceOp(h, 'task', taskRow(v5, 'p1', { status: 2, completedAt: NOW_ISH })),
        { opId: 'dev-del-copy', hlc: h.deviceHlc(), entity: 'task', entityId: v5, op: 'delete', fields: [], row: {} },
      ]);
    h.calls.length = 0;

    const r = await call(h, 'u-a', 'complete_task', { project_id: 'p1', task_id: 'rep' });
    expect(r.isError, r.text).toBe(false);
    const v7 = r.json.id as string;
    expect(isV7(v7)).toBe(true);
    const itemCopy = await uuidv5(`${v7}|c1`);
    expect(mcpCalls(h).map((c) => c.ops.map((o) => o.entityId))).toEqual([[v5], [v7], [itemCopy], ['rep']]);
    expect(mcpOps(h).filter((o) => o.entity === 'checklistItem').every((o) => (o.row as Record<string, unknown>).taskId === v7)).toBe(true);
    const res = await h.pull('u-a');
    expect(pulled(res, 'task', 'rep')).toMatchObject({ startDay: '2026-11-22' });
    expect(pulled(res, 'task', v7)).toMatchObject({ status: 2, startDay: '2026-11-15' });
    expect(pulled(res, 'checklistItem', itemCopy)).toMatchObject({ taskId: v7 });
  });

  it('only completes an existing open copy, and leaves an existing completed copy alone', async () => {
    const h = createHarness();
    await seedRepeating(h);
    const v5 = await repCopyId();
    await h.devicePush('u-a', [deviceOp(h, 'task', taskRow(v5, 'p1', { title: 'old copy' }))]);
    h.calls.length = 0;
    const r = await call(h, 'u-a', 'complete_task', { project_id: 'p1', task_id: 'rep' });
    expect(r.isError, r.text).toBe(false);
    expect(r.json).toMatchObject({ id: v5, status: 2, title: 'old copy' });
    const copyOp = mcpCalls(h)[0]!.ops[0]!;
    expect(copyOp.entityId).toBe(v5);
    expect([...(copyOp.fields as string[])].sort()).toEqual(['completedAt', 'status', 'updatedAt']);

    // Move the original back onto the same occurrence: the completed copy is reused, not rewritten.
    await h.devicePush('u-a', [
      deviceOp(h, 'task', { id: 'rep', startDay: '2026-11-15', startMinute: 540, endDay: '2026-11-15', endMinute: 600, timeZone: 'Asia/Taipei' }, h.deviceHlc(FIX_NOW + 10)),
    ]);
    h.calls.length = 0;
    const again = await call(h, 'u-a', 'complete_task', { project_id: 'p1', task_id: 'rep' });
    expect(again.isError, again.text).toBe(false);
    expect(again.json.id).toBe(v5);
    expect(mcpCalls(h).map((c) => c.ops.map((o) => o.entityId))).toEqual([['rep']]);
  });

  it('rebuilds a trashed copy from the original, keeping its createdAt', async () => {
    const h = createHarness();
    await seedRepeating(h);
    const v5 = await repCopyId();
    await h.devicePush('u-a', [
      deviceOp(h, 'task', taskRow(v5, 'p1', { title: 'stale', createdAt: 123, deletedAt: NOW_ISH, importNote: 'old note' })),
    ]);
    h.calls.length = 0;
    const r = await call(h, 'u-a', 'complete_task', { project_id: 'p1', task_id: 'rep' });
    expect(r.isError, r.text).toBe(false);
    expect(r.json).toMatchObject({ id: v5, status: 2, title: 'Weekly sync', import_note: null, created_at: 123 });
    const row = pulled(await h.pull('u-a'), 'task', v5);
    expect(row).toMatchObject({ title: 'Weekly sync', startDay: '2026-11-15', createdAt: 123 });
    expect([row?.deletedAt ?? null, row?.repeatRule ?? null, row?.importNote ?? null]).toEqual([null, null, null]);
  });

  it('catches up to today in the task zone', async () => {
    const h = createHarness();
    await seedRepeating(h, { startDay: '2026-11-01', endDay: '2026-11-01', repeatRule: 'RRULE:FREQ=DAILY' });
    const r = await call(h, 'u-a', 'complete_task', { project_id: 'p1', task_id: 'rep' });
    expect(r.isError, r.text).toBe(false);
    expect(r.json.id).toBe(await repCopyId('2026-11-01'));
    expect(pulled(await h.pull('u-a'), 'task', 'rep')).toMatchObject({ startDay: '2026-11-15', endDay: '2026-11-15' });
  });

  it('takes today from the task zone, or DEFAULT_TIMEZONE for floating tasks', async () => {
    vi.setSystemTime(Date.parse('2026-11-15T17:00:00Z')); // 2026-11-16 01:00 in Asia/Taipei
    for (const [timeZone, expected] of [['UTC', '2026-11-15'], [null, '2026-11-16'], ['Asia/Taipei', '2026-11-16']] as const) {
      const h = createHarness();
      await seedRepeating(h, { startDay: '2026-11-10', endDay: '2026-11-10', timeZone, repeatRule: 'RRULE:FREQ=DAILY' });
      const r = await call(h, 'u-a', 'complete_task', { project_id: 'p1', task_id: 'rep' });
      expect(r.isError, r.text).toBe(false);
      expect(pulled(await h.pull('u-a'), 'task', 'rep')?.startDay, String(timeZone)).toBe(expected);
    }
  });

  it('stops catching up after 1000 steps, as the App does', async () => {
    const h = createHarness();
    await seedRepeating(h, { startDay: '2020-01-01', endDay: '2020-01-01', repeatRule: 'RRULE:FREQ=DAILY' });
    const r = await call(h, 'u-a', 'complete_task', { project_id: 'p1', task_id: 'rep' });
    expect(r.isError, r.text).toBe(false);
    const moved = addDays('2020-01-01', 1001);
    expect(pulled(await h.pull('u-a'), 'task', 'rep')).toMatchObject({ startDay: moved, endDay: moved });
  });

  it('uses an empty minute part for all-day occurrences', async () => {
    const h = createHarness();
    await seedRepeating(h, { startMinute: null, endMinute: null, timeZone: null, reminders: [] });
    const r = await call(h, 'u-a', 'complete_task', { project_id: 'p1', task_id: 'rep' });
    expect(r.isError, r.text).toBe(false);
    expect(r.json.id).toBe(await repCopyId('2026-11-15', ''));
  });

  it('keeps the done checklist items on the original when storing their copies fails, so a retry copies them done', async () => {
    const h = createHarness();
    await seedRepeating(h);
    await h.devicePush('u-a', [
      deviceOp(h, 'checklistItem', { id: 'c1', taskId: 'rep', title: 'done one', status: 1, sortKey: 'a0', createdAt: NOW_ISH, updatedAt: NOW_ISH }),
    ]);
    await seedUser(h, 'u-b', 'm-b');
    const invite = await createInvite(h.db, { userId: 'u-a', projectId: 'p1', role: 'editor', nowMs: Date.now() });
    await acceptInvite(h.db, {
      code: invite.code, userId: 'u-b', getScopeStub: (s) => h.deps('u-b').getScopeStub(s), nowMs: Date.now(),
    });
    // The copies live in u-b's scope, the original item in u-a's: fail the copy side once.
    h.hooks.failPush = (input) =>
      input.deviceId === 'mcp' && input.scope === 'u:u-b' && input.ops.some((o) => (o as { entity: string }).entity === 'checklistItem');

    const first = await call(h, 'u-b', 'complete_task', { project_id: 'p1', task_id: 'rep' });
    expect(first.isError).toBe(true);
    let res = await h.pull('u-a');
    expect(pulled(res, 'checklistItem', 'c1')).toMatchObject({ status: 1 });
    expect(pulled(res, 'task', 'rep')).toMatchObject({ startDay: '2026-11-15' });

    const retry = await call(h, 'u-b', 'complete_task', { project_id: 'p1', task_id: 'rep' });
    expect(retry.isError, retry.text).toBe(false);
    expect(retry.json.items.map((i: any) => [i.title, i.status])).toEqual([['done one', 1]]);
    res = await h.pull('u-a');
    expect(pulled(res, 'checklistItem', 'c1')).toMatchObject({ status: 0 });
    expect(pulled(res, 'task', 'rep')).toMatchObject({ startDay: '2026-11-22' });
  });

  it('refuses a rule whose next occurrence cannot be computed before writing anything', async () => {
    const h = createHarness();
    await seedRepeating(h, { repeatRule: 'RRULE:FREQ=YEARLY;INTERVAL=8000' });
    h.calls.length = 0;
    const r = await call(h, 'u-a', 'complete_task', { project_id: 'p1', task_id: 'rep' });
    expect(r.isError).toBe(true);
    expect(mcpCalls(h)).toEqual([]);
    expect(pulled(await h.pull('u-a'), 'task', await repCopyId())).toBeUndefined();
  });
});
