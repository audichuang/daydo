import { describe, expect, it } from 'vitest';
import { attachmentObjectKey } from '../src/attachments/r2';
import { acceptInvite, createInvite, removeProjectMember } from '../src/sharing';
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

  it('include_deleted returns trashed tasks (including in deleted or archived lists) marked deleted:true, hiding purged and non-member lists', async () => {
    const h = createServerHarness({ getNow: () => NOW_ISH + 25 });
    await seedBasic(h);
    await seedUser(h, 'u-other', 'm-other');
    await h.devicePush('u-other', [
      deviceOp(h, 'project', projectRow('p-other', { ownerId: 'm-other' })),
      deviceOp(h, 'task', taskRow('other-del', 'p-other', { title: 'needle other', deletedAt: NOW_ISH })),
    ]);
    await h.devicePush('u-a', [
      deviceOp(h, 'project', projectRow('p-trash', { deletedAt: NOW_ISH })),
      deviceOp(h, 'project', projectRow('p-arch')),
      deviceOp(h, 'task', taskRow('live', 'p1', { title: 'needle live', updatedAt: NOW_ISH + 30 })),
      deviceOp(h, 'task', taskRow('del-open', 'p1', { title: 'needle del open', deletedAt: NOW_ISH, updatedAt: NOW_ISH + 20 })),
      deviceOp(h, 'task', taskRow('del-done', 'p1', { title: 'needle del done', status: 2, completedAt: NOW_ISH, deletedAt: NOW_ISH, updatedAt: NOW_ISH + 40 })),
      deviceOp(h, 'task', taskRow('del-proj', 'p-trash', { title: 'needle del proj', deletedAt: NOW_ISH, updatedAt: NOW_ISH + 10 })),
      deviceOp(h, 'task', taskRow('arch-live', 'p-arch', { title: 'needle arch live', updatedAt: NOW_ISH + 60 })),
      deviceOp(h, 'task', taskRow('arch', 'p-arch', { title: 'needle arch', updatedAt: NOW_ISH + 15 })),
      deviceOp(h, 'task', taskRow('purged', 'p1', { title: 'needle purged', deletedAt: NOW_ISH })),
    ]);
    // Delete task first, then archive the list.
    expect((await call(h, 'u-a', 'delete_task', { project_id: 'p-arch', task_id: 'arch' })).isError).toBe(false);
    await h.devicePush('u-a', [
      { ...deviceOp(h, 'project', { id: 'p-arch', archivedAt: NOW_ISH }), fields: ['archivedAt'] },
      { opId: 'purge-1', hlc: h.deviceHlc(), entity: 'task', entityId: 'purged', op: 'delete', fields: [], row: {} },
    ]);

    const def = await call(h, 'u-a', 'search_tasks', { query: 'needle' });
    expect(def.json.map((t: any) => t.id)).toEqual(['live']);
    expect(def.json[0].deleted).toBeUndefined();

    const withDel = await call(h, 'u-a', 'search_tasks', { query: 'needle', include_deleted: true });
    expect(withDel.json.map((t: any) => [t.id, t.deleted ?? false])).toEqual([
      ['live', false],
      ['arch', true],
      ['del-open', true],
      ['del-proj', true],
      ['del-done', true],
    ]);

    const activeDel = await call(h, 'u-a', 'search_tasks', { query: 'needle', include_deleted: true, active_only: true });
    expect(activeDel.json.map((t: any) => t.id)).toEqual(['live', 'arch', 'del-open', 'del-proj']);

    // Restoring the trashed task from the archived list restores it in place (stays in p-arch).
    const restored = await call(h, 'u-a', 'restore_task', { task_id: 'arch' });
    expect(restored.isError, restored.text).toBe(false);
    expect(restored.json).toMatchObject({ id: 'arch', project_id: 'p-arch' });
    const afterPull = await h.pull('u-a');
    const archRow = afterPull.scopes.flatMap((s) => s.rows).find((r) => r.entity === 'task' && !('gone' in r) && r.row.id === 'arch');
    expect(archRow && !('gone' in archRow) && archRow.row.projectId).toBe('p-arch');
    expect(archRow && !('gone' in archRow) && archRow.row.deletedAt).toBeUndefined();
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

  it('get_task include_deleted reads trashed tasks and archived-list tasks for members, blocks removed members and purged tasks, and keeps default unchanged', async () => {
    const h = createServerHarness();
    await seedShared(h, 'viewer');

    // Share an archived list p-arch with viewer u-b as well.
    await h.devicePush('u-a', [deviceOp(h, 'project', projectRow('p-arch'))]);
    const invArch = await createInvite(h.db, { userId: 'u-a', projectId: 'p-arch', role: 'viewer', nowMs: NOW_ISH });
    await acceptInvite(h.db, {
      code: invArch.code,
      userId: 'u-b',
      getScopeStub: (s) => h.deps('u-b').getScopeStub(s),
      nowMs: NOW_ISH,
    });

    await h.devicePush('u-a', [
      deviceOp(h, 'project', projectRow('p-purged')),
      deviceOp(h, 'task', taskRow('t-trash', 'p1', { title: 'findme trash', deletedAt: NOW_ISH })),
      deviceOp(h, 'task', taskRow('t-arch-live', 'p-arch', { title: 'findme arch live' })),
      deviceOp(h, 'task', taskRow('t-arch-del', 'p-arch', { title: 'findme arch del', deletedAt: NOW_ISH })),
      deviceOp(h, 'task', taskRow('t-purged', 'p1', { title: 'findme purged', deletedAt: NOW_ISH })),
      deviceOp(h, 'task', taskRow('t-in-purged', 'p-purged', { title: 'findme in purged' })),
      deviceOp(h, 'attachment', {
        id: 'att-trash',
        taskId: 't-trash',
        fileName: 'trash.txt',
        size: 11,
        mimeType: 'text/plain',
        createdAt: NOW_ISH,
        updatedAt: NOW_ISH,
      }),
      deviceOp(h, 'attachment', {
        id: 'att-arch-live',
        taskId: 't-arch-live',
        fileName: 'arch-live.txt',
        size: 9,
        mimeType: 'text/plain',
        createdAt: NOW_ISH,
        updatedAt: NOW_ISH,
      }),
      deviceOp(h, 'attachment', {
        id: 'att-arch-del',
        taskId: 't-arch-del',
        fileName: 'arch-del.txt',
        size: 8,
        mimeType: 'text/plain',
        createdAt: NOW_ISH,
        updatedAt: NOW_ISH,
      }),
    ]);
    await h.storage.put(attachmentObjectKey('t-trash', 'att-trash'), new TextEncoder().encode('trash-bytes'));
    await h.storage.put(attachmentObjectKey('t-arch-live', 'att-arch-live'), new TextEncoder().encode('arch-live'));
    await h.storage.put(attachmentObjectKey('t-arch-del', 'att-arch-del'), new TextEncoder().encode('arch-del'));

    // Archive p-arch and purge t-purged / p-purged.
    await h.devicePush('u-a', [
      { ...deviceOp(h, 'project', { id: 'p-arch', archivedAt: NOW_ISH }), fields: ['archivedAt'] },
      { opId: 'purge-t', hlc: h.deviceHlc(), entity: 'task', entityId: 't-purged', op: 'delete', fields: [], row: {} },
      { opId: 'purge-p', hlc: h.deviceHlc(), entity: 'project', entityId: 'p-purged', op: 'delete', fields: [], row: {} },
    ]);

    // Default get_task (without include_deleted) still returns Unknown task for trashed and archived tasks.
    const defTrash = await call(h, 'u-b', 'get_task', { project_id: 'p1', task_id: 't-trash' });
    expect(defTrash.isError).toBe(true);
    expect(defTrash.text).toContain('Unknown task_id');
    const defArch = await call(h, 'u-b', 'get_task', { project_id: 'p-arch', task_id: 't-arch-live' });
    expect(defArch.isError).toBe(true);
    expect(defArch.text).toContain('Unknown task_id');

    // Flow 1 (viewer): search_tasks(include_deleted) -> get_task(include_deleted) -> get_attachment for trashed task.
    const found = await call(h, 'u-b', 'search_tasks', { query: 'findme', include_deleted: true });
    expect(found.json.map((t: any) => t.id)).toEqual(expect.arrayContaining(['t-trash', 't-arch-del']));

    const gotTrash = await call(h, 'u-b', 'get_task', { project_id: 'p1', task_id: 't-trash', include_deleted: true });
    expect(gotTrash.isError, gotTrash.text).toBe(false);
    expect(gotTrash.json).toMatchObject({ id: 't-trash', deleted: true });
    expect(gotTrash.json.archived).toBeUndefined();
    const trashAttId = gotTrash.json.attachments[0].id as string;

    const readTrashAtt = await call(h, 'u-b', 'get_attachment', {
      project_id: 'p1',
      task_id: 't-trash',
      attachment_id: trashAttId,
    });
    expect(readTrashAtt.isError, readTrashAtt.text).toBe(false);
    expect(readTrashAtt.json.content).toBe('trash-bytes');

    // Flow 2 (viewer): archived list (both deleted task via search_tasks and non-deleted task via get_task).
    const gotArchDel = await call(h, 'u-b', 'get_task', {
      project_id: 'p-arch',
      task_id: 't-arch-del',
      include_deleted: true,
    });
    expect(gotArchDel.isError, gotArchDel.text).toBe(false);
    expect(gotArchDel.json).toMatchObject({ id: 't-arch-del', deleted: true, archived: true });
    const readArchDelAtt = await call(h, 'u-b', 'get_attachment', {
      project_id: 'p-arch',
      task_id: 't-arch-del',
      attachment_id: gotArchDel.json.attachments[0].id,
    });
    expect(readArchDelAtt.isError, readArchDelAtt.text).toBe(false);
    expect(readArchDelAtt.json.content).toBe('arch-del');

    const gotArchLive = await call(h, 'u-b', 'get_task', {
      project_id: 'p-arch',
      task_id: 't-arch-live',
      include_deleted: true,
    });
    expect(gotArchLive.isError, gotArchLive.text).toBe(false);
    expect(gotArchLive.json).toMatchObject({ id: 't-arch-live', archived: true });
    expect(gotArchLive.json.deleted).toBeUndefined();
    const readArchLiveAtt = await call(h, 'u-b', 'get_attachment', {
      project_id: 'p-arch',
      task_id: 't-arch-live',
      attachment_id: gotArchLive.json.attachments[0].id,
    });
    expect(readArchLiveAtt.isError, readArchLiveAtt.text).toBe(false);
    expect(readArchLiveAtt.json.content).toBe('arch-live');

    // Purged task, purged list, and wrong project remain blocked even with include_deleted: true.
    expect((await call(h, 'u-a', 'get_task', { project_id: 'p1', task_id: 't-purged', include_deleted: true })).isError).toBe(true);
    expect((await call(h, 'u-a', 'get_task', { project_id: 'p-purged', task_id: 't-in-purged', include_deleted: true })).isError).toBe(true);
    expect((await call(h, 'u-a', 'get_task', { project_id: 'p-arch', task_id: 't-trash', include_deleted: true })).isError).toBe(true);

    // Removed member is blocked on all three steps (search_tasks, get_task, get_attachment) for both lists.
    await removeProjectMember(h.db, {
      projectId: 'p1',
      targetUserId: 'u-b',
      requesterUserId: 'u-a',
      getScopeStub: h.getScopeStub,
    });
    await removeProjectMember(h.db, {
      projectId: 'p-arch',
      targetUserId: 'u-b',
      requesterUserId: 'u-a',
      getScopeStub: h.getScopeStub,
    });

    const removedSearch = await call(h, 'u-b', 'search_tasks', { query: 'findme', include_deleted: true });
    expect(removedSearch.json).toEqual([]);
    expect((await call(h, 'u-b', 'get_task', { project_id: 'p1', task_id: 't-trash', include_deleted: true })).isError).toBe(true);
    expect((await call(h, 'u-b', 'get_attachment', { project_id: 'p1', task_id: 't-trash', attachment_id: 'att-trash' })).isError).toBe(true);
    expect((await call(h, 'u-b', 'get_task', { project_id: 'p-arch', task_id: 't-arch-del', include_deleted: true })).isError).toBe(true);
    expect((await call(h, 'u-b', 'get_attachment', { project_id: 'p-arch', task_id: 't-arch-del', attachment_id: 'att-arch-del' })).isError).toBe(true);
  });
});
