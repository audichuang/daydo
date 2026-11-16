import { drizzle } from 'drizzle-orm/d1';
import { eq } from 'drizzle-orm';
import { describe, expect, it, vi } from 'vitest';
import * as schema from '../db/schema';
import { serverClock } from '../src/sync/serverClock';
import { acceptInvite, createInvite } from '../src/sharing';
import { createServerHlcClock } from '../src/sync/hlc';
import { executeSyncPush, type ScopeStub } from '../src/sync/push';
import { loadSnapshot } from '../src/serverops/snapshot';
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

function createHarness() {
  const { d1, db } = createTestD1();
  const scopes = new Map<string, InstanceType<typeof ScopeObject>>();
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
    return instance as unknown as ScopeStub;
  };
  let seq = 0;
  const hlc = () => `${1_700_000_000_000 + seq++}:0000:dev-a`;
  return {
    d1,
    db,
    getScopeStub,
    hlc,
    push: (userId: string, ops: unknown[]) =>
      executeSyncPush(db, { userId, deviceId: 'dev-a', ops, getScopeStub, clock }),
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

  it('pages past limit=1000 within one scope and returns every row', async () => {
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
    const snap = await loadSnapshot(h.db, 'u-a', h.getScopeStub);
    const elapsed = performance.now() - started;
    console.log(`loadSnapshot ${total} tasks: ${elapsed.toFixed(0)} ms (getScopeStub calls: ${pulls.mock.calls.length})`);

    const tasks = snap.rows('task');
    expect(tasks).toHaveLength(total);
    expect(new Set(tasks.map((t) => t.row.id)).size).toBe(total);
    expect(snap.liveTasks()).toHaveLength(total);
  }, 120_000);
});
