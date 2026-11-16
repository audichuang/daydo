import { drizzle } from 'drizzle-orm/d1';
import { eq } from 'drizzle-orm';
import { describe, expect, it, vi } from 'vitest';
import * as schema from '../db/schema';
import { acceptInvite, createInvite } from '../src/sharing';
import { createServerHlcClock } from '../src/sync/hlc';
import { executeSyncPush, type ScopeStub } from '../src/sync/push';
import { loadSnapshot } from '../src/serverops/snapshot';
import { handleToolCall, HINTS, TOOL_DEFS } from '../src/mcp/registry';
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
          return (input: Parameters<ScopeStub['push']>[0]) => {
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
  return { db, calls, deviceHlc, devicePush, deps, snapshot };
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


const READ_TOOLS = ['list_recent_tasks', 'list_tasks', 'search_tasks', 'get_task', 'get_completed_tasks'];

describe('M11a registry', () => {
  it('registers the five read tools as read-only', () => {
    const names = TOOL_DEFS.map((t) => t.name);
    for (const n of READ_TOOLS) {
      expect(names).toContain(n);
      expect(HINTS[n]).toBe('read');
    }
  });
});

describe('M11a list_recent_tasks', () => {
  it('orders by updatedAt desc, honours limit, active_only and tag', async () => {
    const h = createHarness();
    await seedBasic(h);
    await h.devicePush('u-a', [
      deviceOp(h, 'task', taskRow('t2', 'p1', { updatedAt: NOW_ISH + 30, tags: ['work'] })),
      deviceOp(h, 'task', taskRow('t3', 'p1', { updatedAt: NOW_ISH + 20, status: 2, completedAt: NOW_ISH, tags: ['work'] })),
      deviceOp(h, 'task', taskRow('t4', 'p1', { updatedAt: NOW_ISH + 10 })),
    ]);
    const all = await call(h, 'u-a', 'list_recent_tasks', { project_id: 'p1' });
    expect(all.json.map((t: any) => t.id)).toEqual(['t2', 't3', 't4', 't1']);
    const two = await call(h, 'u-a', 'list_recent_tasks', { project_id: 'p1', limit: 2 });
    expect(two.json.map((t: any) => t.id)).toEqual(['t2', 't3']);
    const active = await call(h, 'u-a', 'list_recent_tasks', { project_id: 'p1', active_only: true });
    expect(active.json.map((t: any) => t.id)).toEqual(['t2', 't4', 't1']);
    const tagged = await call(h, 'u-a', 'list_recent_tasks', { project_id: 'p1', tag: '#Work' });
    expect(tagged.json.map((t: any) => t.id)).toEqual(['t2', 't3']);
  });

  it('rejects an unknown or archived project and a bad limit', async () => {
    const h = createHarness();
    await seedBasic(h);
    await h.devicePush('u-a', [deviceOp(h, 'project', projectRow('pa', { archivedAt: NOW_ISH }))]);
    expect((await call(h, 'u-a', 'list_recent_tasks', { project_id: 'nope' })).isError).toBe(true);
    expect((await call(h, 'u-a', 'list_recent_tasks', { project_id: 'pa' })).isError).toBe(true);
    expect((await call(h, 'u-a', 'list_recent_tasks', { project_id: 'p1', limit: 0 })).isError).toBe(true);
  });
});

describe('M11a visibility', () => {
  it('hides trashed tasks and tasks of trashed or archived projects in every read tool', async () => {
    const h = createHarness();
    await seedBasic(h);
    await h.devicePush('u-a', [
      deviceOp(h, 'project', projectRow('p-arch', { archivedAt: NOW_ISH })),
      deviceOp(h, 'project', projectRow('p-trash', { deletedAt: NOW_ISH })),
      deviceOp(h, 'task', taskRow('ghost-arch', 'p-arch', { title: 'needle arch' })),
      deviceOp(h, 'task', taskRow('ghost-proj', 'p-trash', { title: 'needle proj' })),
      deviceOp(h, 'task', taskRow('ghost-del', 'p1', { title: 'needle del', deletedAt: NOW_ISH })),
      deviceOp(h, 'task', taskRow('ghost-done', 'p-arch', { title: 'needle done', status: 2, completedAt: NOW_ISH })),
      deviceOp(h, 'task', taskRow('seen', 'p1', { title: 'needle seen', sortKey: 'b' })),
    ]);
    const search = await call(h, 'u-a', 'search_tasks', { query: 'needle' });
    expect(search.json.map((t: any) => t.id)).toEqual(['seen']);
    const list = await call(h, 'u-a', 'list_tasks');
    expect(list.json.map((t: any) => t.id)).toEqual(['t1', 'seen']);
    expect((await call(h, 'u-a', 'get_completed_tasks')).json).toEqual([]);
    expect((await call(h, 'u-a', 'get_task', { project_id: 'p1', task_id: 'ghost-del' })).isError).toBe(true);
    expect((await call(h, 'u-a', 'get_task', { project_id: 'p-arch', task_id: 'ghost-arch' })).isError).toBe(true);
  });

  it('shows tasks of a shared list to the member', async () => {
    const h = createHarness();
    await seedShared(h, 'viewer');
    const list = await call(h, 'u-b', 'list_tasks');
    expect(list.json.map((t: any) => t.id)).toEqual(['t1']);
    const recent = await call(h, 'u-b', 'list_recent_tasks', { project_id: 'p1' });
    expect(recent.json.map((t: any) => t.id)).toEqual(['t1']);
    expect((await call(h, 'u-b', 'get_task', { project_id: 'p1', task_id: 't1' })).json.id).toBe('t1');
  });
});

describe('M11a list_tasks / get_completed_tasks', () => {
  it('list_tasks returns open tasks by sortKey, optionally for one project', async () => {
    const h = createHarness();
    await seedBasic(h);
    await h.devicePush('u-a', [
      deviceOp(h, 'project', projectRow('p2', { sortKey: 'b' })),
      deviceOp(h, 'task', taskRow('t2', 'p1', { sortKey: '9' })),
      deviceOp(h, 'task', taskRow('t3', 'p2', { sortKey: 'a' })),
      deviceOp(h, 'task', taskRow('t4', 'p1', { status: 2, completedAt: NOW_ISH })),
    ]);
    const all = await call(h, 'u-a', 'list_tasks');
    expect(all.json.map((t: any) => t.id)).toEqual(['t2', 't3', 't1']);
    const one = await call(h, 'u-a', 'list_tasks', { project_id: 'p2' });
    expect(one.json.map((t: any) => t.id)).toEqual(['t3']);
    expect((await call(h, 'u-a', 'list_tasks', { project_id: 'nope' })).isError).toBe(true);
  });

  it('get_completed_tasks orders by completedAt desc and filters by project', async () => {
    const h = createHarness();
    await seedBasic(h);
    await h.devicePush('u-a', [
      deviceOp(h, 'project', projectRow('p2')),
      deviceOp(h, 'task', taskRow('c1', 'p1', { status: 2, completedAt: NOW_ISH + 1 })),
      deviceOp(h, 'task', taskRow('c2', 'p1', { status: 2, completedAt: NOW_ISH + 3 })),
      deviceOp(h, 'task', taskRow('c3', 'p2', { status: 2, completedAt: NOW_ISH + 2 })),
    ]);
    const all = await call(h, 'u-a', 'get_completed_tasks');
    expect(all.json.map((t: any) => t.id)).toEqual(['c2', 'c3', 'c1']);
    const one = await call(h, 'u-a', 'get_completed_tasks', { project_id: 'p1' });
    expect(one.json.map((t: any) => t.id)).toEqual(['c2', 'c1']);
  });
});

describe('M11a search_tasks', () => {
  it('matches title, content, tags and checklist titles case-insensitively; open before done, newest first', async () => {
    const h = createHarness();
    await seedBasic(h);
    await h.devicePush('u-a', [
      deviceOp(h, 'task', taskRow('s-title', 'p1', { title: 'Buy MILK', updatedAt: NOW_ISH + 1 })),
      deviceOp(h, 'task', taskRow('s-content', 'p1', { content: 'ask about milk', updatedAt: NOW_ISH + 5 })),
      deviceOp(h, 'task', taskRow('s-tag', 'p1', { tags: ['milkrun'], updatedAt: NOW_ISH + 3 })),
      deviceOp(h, 'task', taskRow('s-item', 'p1', { updatedAt: NOW_ISH + 2 })),
      deviceOp(h, 'checklistItem', { id: 'ci1', taskId: 's-item', title: 'oat Milk', status: 0, sortKey: 'a', createdAt: NOW_ISH, updatedAt: NOW_ISH }),
      deviceOp(h, 'task', taskRow('s-done', 'p1', { title: 'milk old', status: 2, completedAt: NOW_ISH, updatedAt: NOW_ISH + 99 })),
      deviceOp(h, 'task', taskRow('s-none', 'p1', { title: 'bread' })),
    ]);
    const r = await call(h, 'u-a', 'search_tasks', { query: 'MiLk' });
    expect(r.json.map((t: any) => t.id)).toEqual(['s-content', 's-tag', 's-item', 's-title', 's-done']);
    const active = await call(h, 'u-a', 'search_tasks', { query: 'milk', active_only: true });
    expect(active.json.map((t: any) => t.id)).toEqual(['s-content', 's-tag', 's-item', 's-title']);
  });

  it('caps results at 200', async () => {
    const h = createHarness();
    await seedBasic(h);
    const ops = Array.from({ length: 205 }, (_, i) => deviceOp(h, 'task', taskRow(`m${i}`, 'p1', { title: 'zzz', updatedAt: NOW_ISH + i })));
    for (let i = 0; i < ops.length; i += 100) await h.devicePush('u-a', ops.slice(i, i + 100));
    const r = await call(h, 'u-a', 'search_tasks', { query: 'zzz' });
    expect(r.json).toHaveLength(200);
    expect(r.json[0].id).toBe('m204');
  });
});

describe('M11a get_task and summaries', () => {
  it('returns the full record, and errors when project_id does not match', async () => {
    const h = createHarness();
    await seedBasic(h);
    await h.devicePush('u-a', [
      deviceOp(h, 'project', projectRow('p2')),
      deviceOp(h, 'task', taskRow('t5', 'p1', { content: 'x'.repeat(150) })),
      deviceOp(h, 'checklistItem', { id: 'c1', taskId: 't5', title: 'one', status: 0, sortKey: 'a', createdAt: NOW_ISH, updatedAt: NOW_ISH }),
    ]);
    const ok = await call(h, 'u-a', 'get_task', { project_id: 'p1', task_id: 't5' });
    expect(ok.json.content).toBe('x'.repeat(150));
    expect(ok.json.items).toEqual([expect.objectContaining({ id: 'c1', title: 'one' })]);
    const bad = await call(h, 'u-a', 'get_task', { project_id: 'p2', task_id: 't5' });
    expect(bad.isError).toBe(true);
    expect((await call(h, 'u-a', 'get_task', { project_id: 'p1', task_id: 'nope' })).isError).toBe(true);
  });

  it('list tools cut content to 100 characters and turn items into a count', async () => {
    const h = createHarness();
    await seedBasic(h);
    await h.devicePush('u-a', [
      deviceOp(h, 'task', taskRow('t5', 'p1', { content: 'y'.repeat(150), updatedAt: NOW_ISH + 5 })),
      deviceOp(h, 'checklistItem', { id: 'c1', taskId: 't5', title: 'one', status: 0, sortKey: 'a', createdAt: NOW_ISH, updatedAt: NOW_ISH }),
    ]);
    for (const [name, args] of [
      ['list_recent_tasks', { project_id: 'p1' }],
      ['list_tasks', {}],
      ['search_tasks', { query: 't5' }],
    ] as const) {
      const r = await call(h, 'u-a', name, args);
      const t5 = r.json.find((t: any) => t.id === 't5');
      expect(t5.content, name).toBe(`${'y'.repeat(100)}...`);
      expect(t5.items, name).toBe(1);
    }
  });
});
