import { eq } from 'drizzle-orm';
import { describe, expect, it, vi } from 'vitest';
import * as schema from '../db/schema';
import { serverClock } from '../src/sync/serverClock';
import { acceptInvite, createInvite } from '../src/sharing';
import { loadSnapshot } from '../src/serverops/snapshot';
import { MAX_PULL_PAGE_CHARS } from '../src/scope/pull';
import { createScopeWorld } from './helpers/scopeWorld';

function createHarness() {
  const { d1, db, getScopeStub, push } = createScopeWorld();
  let seq = 0;
  const hlc = () => `${1_700_000_000_000 + seq++}:0000:dev-a`;
  return {
    d1,
    db,
    getScopeStub,
    hlc,
    push: (userId: string, ops: unknown[]) => push(userId, 'dev-a', ops),
  };
}

type Harness = ReturnType<typeof createHarness>;

const PROJECT_FIELDS = [
  'id', 'name', 'viewMode', 'kind', 'isInbox', 'ownerId', 'folderId', 'sortKey',
  'showInSmart', 'notifyMode', 'createdAt', 'updatedAt', 'archivedAt', 'deletedAt',
];
const TASK_FIELDS = [
  'id', 'projectId', 'title', 'content', 'priority', 'status', 'sortKey', 'reminders',
  'tags', 'createdAt', 'updatedAt', 'deletedAt',
];

function projectOp(h: Harness, id: string, extra: Record<string, unknown> = {}) {
  return {
    opId: `op-${id}-${h.hlc()}`,
    hlc: h.hlc(),
    entity: 'project',
    entityId: id,
    op: 'upsert',
    fields: PROJECT_FIELDS.filter((f) => f in { ...baseProject(id), ...extra }),
    row: { ...baseProject(id), ...extra },
  };
}

function baseProject(id: string): Record<string, unknown> {
  return {
    id, name: id, viewMode: 'list', kind: 'TASK', isInbox: false, ownerId: 'u-a',
    folderId: null, sortKey: 'a0', showInSmart: 'all', notifyMode: 'all',
    createdAt: 1000, updatedAt: 1000,
  };
}

function taskOp(h: Harness, id: string, projectId: string, extra: Record<string, unknown> = {}) {
  const row = {
    id, projectId, title: id, content: '', priority: 0, status: 0, sortKey: 'a0',
    reminders: [], tags: [], createdAt: 1000, updatedAt: 1000, ...extra,
  };
  return {
    opId: `op-${id}-${h.hlc()}`,
    hlc: h.hlc(),
    entity: 'task',
    entityId: id,
    op: 'upsert',
    fields: TASK_FIELDS.filter((f) => f in row),
    row,
  };
}

function deleteOp(h: Harness, entity: string, id: string) {
  return {
    opId: `op-del-${id}-${h.hlc()}`,
    hlc: h.hlc(),
    entity,
    entityId: id,
    op: 'delete',
    fields: [],
    row: {},
  };
}

async function seedUsers(h: Harness, ids: string[]) {
  await h.db.insert(schema.user).values(
    ids.map((id) => ({ id, name: id, initial: id[0], color: '#007AFF', avatarUrl: null, createdAt: 1_700_000_000_000 })),
  );
}

describe('M9a serverClock', () => {
  it('is a shared singleton that ticks monotonically', () => {
    const a = serverClock.tick(1_700_000_000_000);
    const b = serverClock.tick(1_700_000_000_000);
    expect(b > a).toBe(true);
  });
});

describe('M9a loadSnapshot', () => {
  it('returns an empty snapshot for an account with no data', async () => {
    const h = createHarness();
    await seedUsers(h, ['u-a']);
    const snap = await loadSnapshot(h.db, 'u-a', h.getScopeStub);
    expect(snap.rows('task')).toEqual([]);
    expect(snap.liveTasks()).toEqual([]);
    expect(snap.liveProjects()).toEqual([]);
    expect(snap.inboxProjectId).toBeNull();
    expect(snap.meMemberId).toBeNull();
    expect(snap.canWrite('nope')).toBe(false);
  });

  it('keeps raw trashed rows and tombstones but hides them from liveTasks', async () => {
    const h = createHarness();
    await seedUsers(h, ['u-a']);
    await h.db.update(schema.user).set({ meMemberId: 'm-1' }).where(eq(schema.user.id, 'u-a'));
    const res = await h.push('u-a', [
      projectOp(h, 'inbox', { isInbox: true }),
      projectOp(h, 'p-live'),
      projectOp(h, 'p-archived', { archivedAt: 5 }),
      taskOp(h, 't-live', 'p-live'),
      taskOp(h, 't-trash', 'p-live', { deletedAt: 9 }),
      taskOp(h, 't-purged', 'p-live'),
      taskOp(h, 't-in-archived', 'p-archived'),
    ]);
    expect(res.results.every((r) => r.status === 'applied')).toBe(true);
    const res2 = await h.push('u-a', [deleteOp(h, 'task', 't-purged')]);
    expect(res2.results[0].status).toBe('applied');

    const snap = await loadSnapshot(h.db, 'u-a', h.getScopeStub);
    expect(snap.meMemberId).toBe('m-1');
    expect(snap.inboxProjectId).toBe('inbox');
    expect(snap.rows('task').map((r) => r.row.id).sort()).toEqual(
      ['t-in-archived', 't-live', 't-purged', 't-trash'],
    );
    expect(snap.findRow('task', 't-trash')?.row.deletedAt).toBe(9);
    expect(snap.findRow('task', 't-purged')?.row.purgedAt).toBeTypeOf('number');
    expect(Object.keys(snap.findRow('task', 't-live')!.clocks).length).toBeGreaterThan(0);
    expect(snap.liveTasks().map((r) => r.row.id)).toEqual(['t-live']);
    expect(snap.liveProjects().map((r) => r.row.id).sort()).toEqual(['inbox', 'p-live']);
  });

  it('reports roles from a shared list and canWrite follows the role', async () => {
    const h = createHarness();
    await seedUsers(h, ['u-a', 'u-b']);
    await h.push('u-a', [projectOp(h, 'p-shared'), taskOp(h, 't-1', 'p-shared')]);
    const invite = await createInvite(h.db, {
      userId: 'u-a', projectId: 'p-shared', role: 'viewer', nowMs: 1_700_000_100_000,
    });
    await acceptInvite(h.db, {
      code: invite.code, userId: 'u-b', getScopeStub: h.getScopeStub, nowMs: 1_700_000_100_001,
    });

    const b = await loadSnapshot(h.db, 'u-b', h.getScopeStub);
    expect(b.memberships.get('p-shared')).toBe('viewer');
    expect(b.canWrite('p-shared')).toBe(false);
    expect(b.liveTasks().map((r) => r.row.id)).toEqual(['t-1']);
    expect(b.inboxProjectId).toBeNull();

    const a = await loadSnapshot(h.db, 'u-a', h.getScopeStub);
    expect(a.memberships.get('p-shared')).toBe('owner');
    expect(a.canWrite('p-shared')).toBe(true);
  });

  it('pages past the page limit within one scope and returns every row', async () => {
    const h = createHarness();
    await seedUsers(h, ['u-a']);
    const total = 1600;
    await h.push('u-a', [projectOp(h, 'p-big')]);
    for (let i = 0; i < total; i += 200) {
      const ops = [];
      for (let j = i; j < Math.min(i + 200, total); j += 1) {
        ops.push(taskOp(h, `t-${j}`, 'p-big', { status: j % 3 === 0 ? 2 : 0 }));
      }
      const r = await h.push('u-a', ops);
      expect(r.results.every((x) => x.status === 'applied')).toBe(true);
    }

    const pulls = vi.spyOn(h, 'getScopeStub');
    const started = performance.now();
    const snap = await loadSnapshot(h.db, 'u-a', h.getScopeStub, 500);
    const elapsed = performance.now() - started;
    console.log(`loadSnapshot ${total} tasks: ${elapsed.toFixed(0)} ms (getScopeStub calls: ${pulls.mock.calls.length})`);

    // 1601 rows (project + tasks) at 500 per page: 4 pages.
    expect(pulls.mock.calls).toHaveLength(4);
    const tasks = snap.rows('task');
    expect(tasks).toHaveLength(total);
    expect(new Set(tasks.map((t) => t.row.id)).size).toBe(total);
    expect(snap.liveTasks()).toHaveLength(total);

    // The default page size fits this account in a single round trip.
    pulls.mockClear();
    const single = await loadSnapshot(h.db, 'u-a', h.getScopeStub);
    expect(pulls.mock.calls).toHaveLength(1);
    expect(single.rows('task')).toHaveLength(total);
  }, 120_000);

  it('ends a page early when rows are large, so one RPC page stays under the size budget', async () => {
    const h = createHarness();
    await seedUsers(h, ['u-a']);
    const total = 400;
    const content = 'x'.repeat(25_000); // 400 x 25k chars exceeds MAX_PULL_PAGE_CHARS
    await h.push('u-a', [projectOp(h, 'p-long')]);
    for (let i = 0; i < total; i += 50) {
      const ops = [];
      for (let j = i; j < Math.min(i + 50, total); j += 1) {
        ops.push(taskOp(h, `t-${j}`, 'p-long', { content }));
      }
      const r = await h.push('u-a', ops);
      expect(r.results.every((x) => x.status === 'applied')).toBe(true);
    }

    const pageChars: number[] = [];
    const getScopeStub = (scope: string) => {
      const stub = h.getScopeStub(scope);
      return {
        pull: async (input: Parameters<typeof stub.pull>[0]) => {
          const res = await stub.pull(input);
          pageChars.push(res.rows.reduce((n, r) => n + JSON.stringify(r).length, 0));
          return res;
        },
        purgeProject: stub.purgeProject.bind(stub),
      };
    };
    const snap = await loadSnapshot(h.db, 'u-a', getScopeStub);

    expect(pageChars.length).toBeGreaterThan(1);
    for (const c of pageChars) expect(c).toBeLessThanOrEqual(MAX_PULL_PAGE_CHARS);
    const tasks = snap.rows('task');
    expect(tasks).toHaveLength(total);
    expect(new Set(tasks.map((t) => t.row.id)).size).toBe(total);
    expect(tasks.every((t) => t.row.content === content)).toBe(true);
  }, 120_000);
});
