import {
  describe,
  expect,
  it,
} from 'vitest';
import { acceptInvite, createInvite } from '../src/sharing';
import { executeSyncPush } from '../src/sync/push';
import {
  HINTS,
  TOOL_DEFS,
} from '../src/mcp/registry';
import type { GetNow } from '../src/clock';
import { advancingNow } from './helpers/advancingClock';
import type { ScopePushInput } from './helpers/scopeWorld';
import {
  call,
  createServerHarness,
  deviceOp,
  NOW_ISH,
  seedBasic,
  seedUser,
  taskRow,
} from './helpers/serverHarness';

function createHarness(options: { getNow?: GetNow } = {}) {
  // One-shot hooks: failPush makes a matching push throw; beforeMcpPush runs right before an MCP push lands.
  const hooks: { failPush?: (input: ScopePushInput) => boolean; beforeMcpPush?: () => Promise<unknown> } = {};
  const world = createServerHarness({
    ...options,
    onPush: async (input, proceed) => {
      if (input.deviceId === 'mcp' && hooks.beforeMcpPush) {
        const hook = hooks.beforeMcpPush;
        hooks.beforeMcpPush = undefined;
        await hook();
      }
      if (hooks.failPush?.(input)) {
        hooks.failPush = undefined;
        return Promise.reject(new Error(`injected failure in ${input.scope}`));
      }
      return proceed(input);
    },
  });
  return { ...world, hooks };
}

type Harness = ReturnType<typeof createHarness>;

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
  it('registers the project and tag tools with hints', () => {
    const names = TOOL_DEFS.map((t) => t.name);
    for (const n of ['create_project', 'create_tag', 'delete_project', 'get_project', 'get_project_data', 'list_projects', 'list_tags', 'update_project']) {
      expect(names).toContain(n);
    }
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

  it('stamps updatedAt from the injected clock, not wall time', async () => {
    const PAST = NOW_ISH + 60_000;
    const h = createHarness({ getNow: () => PAST });
    await seedBasic(h);
    const r = await call(h, 'u-a', 'update_project', { project_id: 'p1', name: 'Renamed' });
    expect(r.isError, r.text).toBe(false);
    expect(r.json.updated_at).toBe(PAST);
    const snap = await h.snapshot('u-a');
    expect(snap.findRow('project', 'p1')?.row.updatedAt).toBe(PAST);
  });

  it.each([
    ['trashes', 'deletedAt'],
    ['archives', 'archivedAt'],
  ] as const)(
    'errors with Unknown project_id when another device %s the project between snapshot and write',
    async (_action, field) => {
      const h = createHarness();
      await seedBasic(h);
      h.hooks.beforeMcpPush = () =>
        h.devicePush('u-a', [{ ...deviceOp(h, 'project', { id: 'p1', [field]: NOW_ISH }), fields: [field] }]);
      const r = await call(h, 'u-a', 'update_project', { project_id: 'p1', name: 'Renamed' });
      expect(h.hooks.beforeMcpPush).toBeUndefined();
      expect(r.isError).toBe(true);
      expect(r.text).toContain("Unknown project_id 'p1'");
    },
  );
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
    expect(h.calls.map((c) => c.ops.map((o) => `${String(o.entity)}:${String(o.entityId)}`))).toEqual([['task:t1', 'task:t2'], ['project:p1']]);
    const list = await call(h, 'u-a', 'list_projects');
    expect(list.json.map((p: any) => p.id)).toEqual(['inbox-u-a']);
    const snap = await h.snapshot('u-a');
    expect(snap.findRow('task', 't1')?.row.deletedAt).toBeTypeOf('number');
    expect(snap.findRow('task', 't2')?.row.deletedAt).toBeTypeOf('number');
  });

  it('stamps the trashed tasks and the list with one now', async () => {
    const h = createHarness({ getNow: advancingNow(Date.now() + 120_000) });
    await seedBasic(h);
    const r = await call(h, 'u-a', 'delete_project', { project_id: 'p1' });
    expect(r.isError, r.text).toBe(false);
    const snap = await h.snapshot('u-a');
    const task = snap.findRow('task', 't1')!.row;
    const project = snap.findRow('project', 'p1')!.row;
    expect(task.deletedAt).toBeTypeOf('number');
    expect(task.updatedAt).toBe(task.deletedAt);
    expect(project.deletedAt).toBe(task.deletedAt);
    expect(project.updatedAt).toBe(project.deletedAt);
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

  it('deletes the list only after every task is trashed, so a failed run can be retried', async () => {
    const h = createHarness();
    await seedShared(h, 'editor');
    // u-b's task lives in u-b's scope, the list in u-a's.
    const seeded = await executeSyncPush(h.db, {
      userId: 'u-b', deviceId: 'dev-b', ops: [deviceOp(h, 'task', taskRow('tb', 'p1', { sortKey: 'b' }))],
      getScopeStub: h.deps('u-b').getScopeStub, clock: h.deps('u-b').clock,
    });
    expect(seeded.results[0]?.status).toBe('applied');
    h.hooks.failPush = (input) => input.deviceId === 'mcp' && input.scope === 'u:u-b';

    const first = await call(h, 'u-a', 'delete_project', { project_id: 'p1' });
    expect(first.isError).toBe(true);
    expect((await h.snapshot('u-a')).findRow('project', 'p1')?.row.deletedAt).toBeUndefined();

    const retry = await call(h, 'u-a', 'delete_project', { project_id: 'p1' });
    expect(retry.isError, retry.text).toBe(false);
    // t1 (u-a's scope) already landed in the failed run; the retry finishes tb.
    expect(retry.json).toMatchObject({ deleted: true, trashed_tasks: 1 });
    const snap = await h.snapshot('u-a');
    expect(snap.findRow('task', 't1')?.row.deletedAt).toBeTypeOf('number');
    expect(snap.findRow('project', 'p1')?.row.deletedAt).toBeTypeOf('number');
    expect(snap.findRow('task', 'tb')?.row.deletedAt).toBeTypeOf('number');
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
