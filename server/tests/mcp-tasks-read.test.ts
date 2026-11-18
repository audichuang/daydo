import { describe, expect, it } from 'vitest';
import { acceptInvite, createInvite } from '../src/sharing';
import {
  HINTS,
  TOOL_DEFS,
} from '../src/mcp/registry';
import {
  call,
  createServerHarness,
  deviceOp,
  NOW_ISH,
  projectRow,
  seedBasic,
  seedUser,
  taskRow,
} from './helpers/serverHarness';

type Harness = ReturnType<typeof createServerHarness>;

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
    const h = createServerHarness();
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
    const h = createServerHarness();
    await seedBasic(h);
    await h.devicePush('u-a', [deviceOp(h, 'project', projectRow('pa', { archivedAt: NOW_ISH }))]);
    expect((await call(h, 'u-a', 'list_recent_tasks', { project_id: 'nope' })).isError).toBe(true);
    expect((await call(h, 'u-a', 'list_recent_tasks', { project_id: 'pa' })).isError).toBe(true);
    expect((await call(h, 'u-a', 'list_recent_tasks', { project_id: 'p1', limit: 0 })).isError).toBe(true);
  });
});

describe('M11a visibility', () => {
  it('hides trashed tasks and tasks of trashed or archived projects in every read tool', async () => {
    const h = createServerHarness();
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
    const h = createServerHarness();
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
    const h = createServerHarness();
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
    const h = createServerHarness();
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
    const h = createServerHarness();
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

  it('include_deleted returns trashed tasks (including in deleted projects) marked deleted:true, hiding purged and archived', async () => {
    const h = createServerHarness();
    await seedBasic(h);
    await h.devicePush('u-a', [
      deviceOp(h, 'project', projectRow('p-trash', { deletedAt: NOW_ISH })),
      deviceOp(h, 'project', projectRow('p-arch', { archivedAt: NOW_ISH })),
      deviceOp(h, 'task', taskRow('live', 'p1', { title: 'needle live', updatedAt: NOW_ISH + 30 })),
      deviceOp(h, 'task', taskRow('del-open', 'p1', { title: 'needle del open', deletedAt: NOW_ISH, updatedAt: NOW_ISH + 20 })),
      deviceOp(h, 'task', taskRow('del-done', 'p1', { title: 'needle del done', status: 2, completedAt: NOW_ISH, deletedAt: NOW_ISH, updatedAt: NOW_ISH + 40 })),
      deviceOp(h, 'task', taskRow('del-proj', 'p-trash', { title: 'needle del proj', deletedAt: NOW_ISH, updatedAt: NOW_ISH + 10 })),
      deviceOp(h, 'task', taskRow('arch', 'p-arch', { title: 'needle arch', deletedAt: NOW_ISH, updatedAt: NOW_ISH + 50 })),
      deviceOp(h, 'task', taskRow('purged', 'p1', { title: 'needle purged', deletedAt: NOW_ISH })),
    ]);
    await h.devicePush('u-a', [
      { opId: 'purge-1', hlc: h.deviceHlc(), entity: 'task', entityId: 'purged', op: 'delete', fields: [], row: {} },
    ]);

    const def = await call(h, 'u-a', 'search_tasks', { query: 'needle' });
    expect(def.json.map((t: any) => t.id)).toEqual(['live']);
    expect(def.json[0].deleted).toBeUndefined();

    const withDel = await call(h, 'u-a', 'search_tasks', { query: 'needle', include_deleted: true });
    expect(withDel.json.map((t: any) => [t.id, t.deleted ?? false])).toEqual([
      ['live', false],
      ['del-open', true],
      ['del-proj', true],
      ['del-done', true],
    ]);

    const activeDel = await call(h, 'u-a', 'search_tasks', { query: 'needle', include_deleted: true, active_only: true });
    expect(activeDel.json.map((t: any) => t.id)).toEqual(['live', 'del-open', 'del-proj']);
  });

  it('caps results at 200', async () => {
    const h = createServerHarness();
    await seedBasic(h);
    const ops = Array.from({ length: 205 }, (_, i) => deviceOp(h, 'task', taskRow(`m${i}`, 'p1', { title: 'zzz', updatedAt: NOW_ISH + i })));
    for (let i = 0; i < ops.length; i += 100) await h.devicePush('u-a', ops.slice(i, i + 100));
    const r = await call(h, 'u-a', 'search_tasks', { query: 'zzz' });
    expect(r.json).toHaveLength(200);
    expect(r.json[0].id).toBe('m204');
  });
});

describe('M11a get_task and summaries', () => {
  it('returns the full record including sorted non-deleted attachments, and errors when project_id does not match', async () => {
    const h = createServerHarness();
    await seedBasic(h);
    await h.devicePush('u-a', [
      deviceOp(h, 'project', projectRow('p2')),
      deviceOp(h, 'task', taskRow('t5', 'p1', { content: 'x'.repeat(150) })),
      deviceOp(h, 'checklistItem', { id: 'c1', taskId: 't5', title: 'one', status: 0, sortKey: 'a', createdAt: NOW_ISH, updatedAt: NOW_ISH }),
      deviceOp(h, 'attachment', { id: 'a2', taskId: 't5', fileName: 'b.txt', size: 20, mimeType: 'text/plain', createdAt: NOW_ISH + 20, updatedAt: NOW_ISH + 20 }),
      deviceOp(h, 'attachment', { id: 'a1', taskId: 't5', fileName: 'a.png', size: 10, mimeType: 'image/png', createdAt: NOW_ISH + 10, updatedAt: NOW_ISH + 10 }),
      deviceOp(h, 'attachment', { id: 'a-del', taskId: 't5', fileName: 'gone.txt', size: 5, mimeType: 'text/plain', createdAt: NOW_ISH, updatedAt: NOW_ISH, deletedAt: NOW_ISH }),
    ]);
    const ok = await call(h, 'u-a', 'get_task', { project_id: 'p1', task_id: 't5' });
    expect(ok.json.content).toBe('x'.repeat(150));
    expect(ok.json.items).toEqual([expect.objectContaining({ id: 'c1', title: 'one' })]);
    expect(ok.json.attachments).toEqual([
      { id: 'a1', file_name: 'a.png', size: 10, mime_type: 'image/png', created_at: NOW_ISH + 10 },
      { id: 'a2', file_name: 'b.txt', size: 20, mime_type: 'text/plain', created_at: NOW_ISH + 20 },
    ]);
    const bad = await call(h, 'u-a', 'get_task', { project_id: 'p2', task_id: 't5' });
    expect(bad.isError).toBe(true);
    expect((await call(h, 'u-a', 'get_task', { project_id: 'p1', task_id: 'nope' })).isError).toBe(true);
  });

  it('list tools cut content to 100 characters and turn items and attachments into counts', async () => {
    const h = createServerHarness();
    await seedBasic(h);
    await h.devicePush('u-a', [
      deviceOp(h, 'task', taskRow('t5', 'p1', { content: 'y'.repeat(150), updatedAt: NOW_ISH + 5 })),
      deviceOp(h, 'checklistItem', { id: 'c1', taskId: 't5', title: 'one', status: 0, sortKey: 'a', createdAt: NOW_ISH, updatedAt: NOW_ISH }),
      deviceOp(h, 'attachment', { id: 'a1', taskId: 't5', fileName: 'a.txt', size: 10, mimeType: 'text/plain', createdAt: NOW_ISH, updatedAt: NOW_ISH }),
      deviceOp(h, 'attachment', { id: 'a2', taskId: 't5', fileName: 'b.txt', size: 10, mimeType: 'text/plain', createdAt: NOW_ISH + 1, updatedAt: NOW_ISH + 1 }),
      deviceOp(h, 'attachment', { id: 'a-del', taskId: 't5', fileName: 'c.txt', size: 10, mimeType: 'text/plain', createdAt: NOW_ISH + 2, updatedAt: NOW_ISH + 2, deletedAt: NOW_ISH }),
    ]);
    for (const [name, args] of [
      ['list_recent_tasks', { project_id: 'p1' }],
      ['list_tasks', {}],
      ['search_tasks', { query: 't5' }],
      ['get_project_data', { project_id: 'p1' }],
    ] as const) {
      const r = await call(h, 'u-a', name, args);
      const list = name === 'get_project_data' ? r.json.tasks : r.json;
      const t5 = list.find((t: any) => t.id === 't5');
      expect(t5.content, name).toBe(`${'y'.repeat(100)}...`);
      expect(t5.items, name).toBe(1);
      expect(t5.attachments, name).toBe(2);
    }
  });
});
