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

describe('M10 registry', () => {
  it('registers the eight tools with hints', () => {
    const names = TOOL_DEFS.map((t) => t.name).sort();
    expect(names).toEqual(
      ['create_project', 'create_tag', 'delete_project', 'get_project', 'get_project_data', 'list_projects', 'list_tags', 'update_project'],
    );
    for (const n of names) expect(HINTS[n]).toBeDefined();
    expect(HINTS.delete_project).toBe('destructive');
  });
});

describe('M10 list_projects / get_project / get_project_data', () => {
  it('lists inbox first with role and can_write=true for the owner', async () => {
    const h = createHarness();
    await seedBasic(h);
    const r = await call(h, 'u-a', 'list_projects');
    expect(r.json.map((p: any) => p.id)).toEqual(['inbox-u-a', 'p1']);
    expect(r.json[0]).toMatchObject({ is_inbox: true, role: 'owner', can_write: true });
    expect(r.json[1]).toMatchObject({ id: 'p1', role: 'owner', can_write: true, view_mode: 'list', kind: 'TASK' });
  });

  it('gives a viewer can_write=false and an editor can_write=true', async () => {
    const h = createHarness();
    await seedShared(h, 'viewer');
    const v = await call(h, 'u-b', 'list_projects');
    const shared = v.json.find((p: any) => p.id === 'p1');
    expect(shared).toMatchObject({ role: 'viewer', can_write: false });
    const g = await call(h, 'u-b', 'get_project', { project_id: 'p1' });
    expect(g.json).toMatchObject({ role: 'viewer', can_write: false });

    const h2 = createHarness();
    await seedShared(h2, 'editor');
    const e = await call(h2, 'u-b', 'list_projects');
    expect(e.json.find((p: any) => p.id === 'p1')).toMatchObject({ role: 'editor', can_write: true });
  });

  it('get_project reports an unknown id', async () => {
    const h = createHarness();
    await seedBasic(h);
    const r = await call(h, 'u-a', 'get_project', { project_id: 'nope' });
    expect(r.isError).toBe(true);
    expect(r.text).toContain('list_projects');
  });

  it('get_project_data returns open tasks only, with content cut and items counted', async () => {
    const h = createHarness();
    await seedBasic(h);
    await h.devicePush('u-a', [
      deviceOp(h, 'task', taskRow('t2', 'p1', { status: 2, completedAt: NOW_ISH, sortKey: 'b' })),
      deviceOp(h, 'task', taskRow('t3', 'p1', { content: 'x'.repeat(150), sortKey: 'c' })),
      deviceOp(h, 'task', taskRow('t4', 'p1', { deletedAt: NOW_ISH, sortKey: 'd' })),
      deviceOp(h, 'checklistItem', {
        id: 'c1', taskId: 't3', title: 'one', status: 0, sortKey: 'a', createdAt: NOW_ISH, updatedAt: NOW_ISH,
      }),
    ]);
    const r = await call(h, 'u-a', 'get_project_data', { project_id: 'p1' });
    expect(r.json.project.id).toBe('p1');
    expect(r.json.tasks.map((t: any) => t.id)).toEqual(['t1', 't3']);
    const t1 = r.json.tasks[0];
    expect(t1).toMatchObject({ start: '2026-11-20T09:00:00+08:00', due: '2026-11-20T10:00:00+08:00', all_day: false, timezone: 'Asia/Taipei' });
    const t3 = r.json.tasks[1];
    expect(t3.content).toBe(`${'x'.repeat(100)}...`);
    expect(t3.items).toBe(1);
  });
});

describe('M10 create_project', () => {
  it('creates a list owned by the caller, not inbox, with a unique valid sortKey', async () => {
    const h = createHarness();
    await seedBasic(h);
    const r = await call(h, 'u-a', 'create_project', { name: ' Work ', color: '#FF5733', view_mode: 'kanban' });
    expect(r.isError).toBe(false);
    expect(r.json).toMatchObject({ name: 'Work', color: '#FF5733', view_mode: 'kanban', kind: 'TASK', is_inbox: false, owner_id: 'm-a', role: 'owner', can_write: true });
    expect(r.json.sort_key).toMatch(/^[0-9a-z]*[1-9a-z]$/);
    const list = await call(h, 'u-a', 'list_projects');
    expect(list.json.map((p: any) => p.name)).toEqual(['inbox-u-a', 'p1', 'Work']);
    expect(list.json.slice(0, 2).map((p: any) => p.sort_key)).not.toContain(r.json.sort_key);
    expect(list.json[2].id).toBe(r.json.id);
    expect(list.json[2].role).toBe('owner');
  });

  it('rejects a bad color or empty name before pushing', async () => {
    const h = createHarness();
    await seedBasic(h);
    h.calls.length = 0;
    expect((await call(h, 'u-a', 'create_project', { name: 'x', color: 'red' })).isError).toBe(true);
    expect((await call(h, 'u-a', 'create_project', { name: '  ' })).isError).toBe(true);
    expect((await call(h, 'u-a', 'create_project', { name: 'x', view_mode: 'grid' })).isError).toBe(true);
    expect(h.calls).toEqual([]);
  });

  it('asks an account that never synced to log in first', async () => {
    const h = createHarness();
    await seedUser(h, 'u-a', null);
    const r = await call(h, 'u-a', 'create_project', { name: 'x' });
    expect(r.isError).toBe(true);
    expect(r.text).toContain('DayDo App');
  });
});

describe('M10 update_project', () => {
  it('renames and recolors for the owner', async () => {
    const h = createHarness();
    await seedBasic(h);
    const r = await call(h, 'u-a', 'update_project', { project_id: 'p1', name: 'Renamed', color: '#abc' });
    expect(r.json).toMatchObject({ id: 'p1', name: 'Renamed', color: '#abc' });
    expect((await call(h, 'u-a', 'get_project', { project_id: 'p1' })).json.name).toBe('Renamed');
  });

  it('refuses a viewer without pushing', async () => {
    const h = createHarness();
    await seedShared(h, 'viewer');
    h.calls.length = 0;
    const r = await call(h, 'u-b', 'update_project', { project_id: 'p1', name: 'mine' });
    expect(r.isError).toBe(true);
    expect(r.text).toContain('read-only');
    expect(h.calls).toEqual([]);
  });

  it('needs something to change', async () => {
    const h = createHarness();
    await seedBasic(h);
    expect((await call(h, 'u-a', 'update_project', { project_id: 'p1' })).isError).toBe(true);
  });
});

describe('M10 delete_project', () => {
  it('lets the owner delete: tasks (including completed) are trashed first, then the list', async () => {
    const h = createHarness();
    await seedBasic(h);
    await h.devicePush('u-a', [
      deviceOp(h, 'task', taskRow('t2', 'p1', { status: 2, completedAt: NOW_ISH, sortKey: 'b' })),
    ]);
    h.calls.length = 0;
    const r = await call(h, 'u-a', 'delete_project', { project_id: 'p1' });
    expect(r.json).toMatchObject({ deleted: true, project_id: 'p1', trashed_tasks: 2 });
    expect(h.calls[0]!.ops.map((o) => `${o.entity}:${String(o.entityId)}`)).toEqual(['task:t1', 'task:t2', 'project:p1']);
    const list = await call(h, 'u-a', 'list_projects');
    expect(list.json.map((p: any) => p.id)).toEqual(['inbox-u-a']);
    const snap = await h.snapshot('u-a');
    expect(snap.findRow('task', 't1')?.row.deletedAt).toBeTypeOf('number');
    expect(snap.findRow('task', 't2')?.row.deletedAt).toBeTypeOf('number');
  });

  it.each(['viewer', 'editor'] as const)('refuses a %s without pushing', async (role) => {
    const h = createHarness();
    await seedShared(h, role);
    h.calls.length = 0;
    const r = await call(h, 'u-b', 'delete_project', { project_id: 'p1' });
    expect(r.isError).toBe(true);
    expect(r.text).toContain('Only the owner');
    expect(h.calls).toEqual([]);
    const snap = await h.snapshot('u-a');
    expect(snap.findRow('project', 'p1')?.row.deletedAt).toBeUndefined();
    expect(snap.findRow('task', 't1')?.row.deletedAt).toBeUndefined();
  });

  it('refuses to delete the inbox', async () => {
    const h = createHarness();
    await seedBasic(h);
    h.calls.length = 0;
    const r = await call(h, 'u-a', 'delete_project', { project_id: 'inbox-u-a' });
    expect(r.isError).toBe(true);
    expect(r.text).toContain('inbox');
    expect(h.calls).toEqual([]);
  });
});

describe('M10 tags', () => {
  it('creates a normalized tag, lists it, and is idempotent', async () => {
    const h = createHarness();
    await seedBasic(h);
    expect((await call(h, 'u-a', 'list_tags')).json).toEqual([]);
    const r = await call(h, 'u-a', 'create_tag', { name: '#Work#', color: '#00FF00' });
    expect(r.json).toEqual({ name: 'work', label: 'Work', color: '#00FF00', active_count: 0 });
    h.calls.length = 0;
    const again = await call(h, 'u-a', 'create_tag', { name: 'WORK' });
    expect(again.json.name).toBe('work');
    expect(h.calls).toEqual([]);
    await call(h, 'u-a', 'create_tag', { name: 'home' });
    const list = await call(h, 'u-a', 'list_tags');
    expect(list.json.map((t: any) => t.name)).toEqual(['work', 'home']);
  });

  it('counts open tasks per tag and rejects bad input', async () => {
    const h = createHarness();
    await seedBasic(h);
    await h.devicePush('u-a', [deviceOp(h, 'task', taskRow('t5', 'p1', { tags: ['work'], sortKey: 'e' }))]);
    await call(h, 'u-a', 'create_tag', { name: 'work' });
    expect((await call(h, 'u-a', 'list_tags')).json[0].active_count).toBe(1);
    expect((await call(h, 'u-a', 'create_tag', { name: '###' })).isError).toBe(true);
    expect((await call(h, 'u-a', 'create_tag', { name: 'x', color: 'blue' })).isError).toBe(true);
    expect((await call(h, 'u-a', 'create_tag', { name: 'x', parent: 'y' })).isError).toBe(true);
  });
});
