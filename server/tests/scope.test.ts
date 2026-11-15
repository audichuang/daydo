import { eq } from 'drizzle-orm';
import { drizzle } from 'drizzle-orm/d1';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import * as schema from '../db/schema';
import { executeSyncPull } from '../src/sync/pull';
import { executeSyncPush, type ScopeStub } from '../src/sync/push';
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

const { default: Scope, ScopeObject, shouldSplitTransaction } = await import(
  '../durable-objects/scope'
);

interface Harness {
  d1: D1Database;
  db: ReturnType<typeof createTestD1>['db'];
  sqlite: ReturnType<typeof createTestD1>['sqlite'];
  scopes: Map<string, InstanceType<typeof ScopeObject>>;
  scopeSqlites: Map<string, ReturnType<typeof createTestDoState>['sqlite']>;
  getScopeStub: (scope: string) => ScopeStub;
  push: (
    userId: string,
    deviceId: string,
    ops: unknown[],
  ) => ReturnType<typeof executeSyncPush>;
  pull: (
    userId: string,
    opts?: { cursors?: Record<string, number>; backfill?: string[]; limit?: number },
  ) => ReturnType<typeof executeSyncPull>;
}

function createHarness(syncFault: 'none' | 'split-txn' = 'none'): Harness {
  const { d1, db, sqlite } = createTestD1();
  const scopes = new Map<string, InstanceType<typeof ScopeObject>>();
  const scopeSqlites = new Map<string, ReturnType<typeof createTestDoState>['sqlite']>();

  const getScopeStub = (scope: string): ScopeStub => {
    let instance = scopes.get(scope);
    if (!instance) {
      const doState = createTestDoState();
      const ScopeClass = Scope.class as unknown as new (
        ctx: DurableObjectState,
        env: { SYNC_FAULT: 'none' | 'split-txn' },
      ) => InstanceType<typeof ScopeObject>;
      instance = new ScopeClass(doState.ctx, { SYNC_FAULT: syncFault });
      scopes.set(scope, instance);
      scopeSqlites.set(scope, doState.sqlite);
    }
    return instance as unknown as ScopeStub;
  };

  return {
    d1,
    db,
    sqlite,
    scopes,
    scopeSqlites,
    getScopeStub,
    push: (userId, deviceId, ops) =>
      executeSyncPush(db, { userId, deviceId, ops, getScopeStub }),
    pull: (userId, opts) =>
      executeSyncPull(db, {
        userId,
        cursors: opts?.cursors ?? {},
        backfill: opts?.backfill,
        limit: opts?.limit ?? 500,
        getScopeStub,
      }),
  };
}

function makeProjectOp(params: {
  opId: string;
  hlc: string;
  id: string;
  name?: string;
  ownerId?: string;
}) {
  return {
    opId: params.opId,
    hlc: params.hlc,
    entity: 'project',
    entityId: params.id,
    op: 'upsert',
    fields: [
      'id',
      'name',
      'viewMode',
      'kind',
      'isInbox',
      'ownerId',
      'sortKey',
      'showInSmart',
      'notifyMode',
      'createdAt',
      'updatedAt',
    ],
    row: {
      id: params.id,
      name: params.name ?? 'List',
      viewMode: 'list',
      kind: 'TASK',
      isInbox: false,
      ownerId: params.ownerId ?? 'm-1',
      sortKey: 'i',
      showInSmart: 'all',
      notifyMode: 'all',
      createdAt: 1000,
      updatedAt: 1000,
    },
  };
}

function makeFullTaskOp(params: {
  opId: string;
  hlc: string;
  id: string;
  projectId: string;
  title?: string;
}) {
  return {
    opId: params.opId,
    hlc: params.hlc,
    entity: 'task',
    entityId: params.id,
    op: 'upsert',
    fields: [
      'id',
      'projectId',
      'title',
      'content',
      'priority',
      'status',
      'reminders',
      'tags',
      'sortKey',
      'createdAt',
      'updatedAt',
    ],
    row: {
      id: params.id,
      projectId: params.projectId,
      title: params.title ?? 'Task',
      content: '',
      priority: 0,
      status: 0,
      reminders: [],
      tags: [],
      sortKey: 'i',
      createdAt: 1000,
      updatedAt: 1000,
    },
  };
}

describe('Scope DO child-after-task-purge', () => {
  let h: Harness;
  const userId = 'u-1';
  const projectId = 'p-1';
  const now = 1_700_000_000_000;

  beforeEach(async () => {
    h = createHarness();
    await h.db.insert(schema.user).values({ id: userId, createdAt: now });
    await h.push(userId, 'dev-a', [
      makeProjectOp({ opId: 'op-p-init', hlc: '1700000000000:0000:dev-a', id: projectId }),
    ]);
  });

  it('tombstones late-arriving checklistItem, attachment, and comment when parent task was already purged', async () => {
    const taskId = 'task-purged-1';
    const purgeRes = await h.push(userId, 'dev-a', [
      makeFullTaskOp({
        opId: 'op-t-create',
        hlc: '1700000000001:0000:dev-a',
        id: taskId,
        projectId,
      }),
      {
        opId: 'op-t-purge',
        hlc: '1700000000002:0000:dev-a',
        entity: 'task',
        entityId: taskId,
        op: 'delete',
        fields: [],
        row: {},
      },
    ]);
    expect(purgeRes.results.every((r) => r.status === 'applied')).toBe(true);

    const lateChildrenRes = await h.push(userId, 'dev-b', [
      {
        opId: 'op-c-1',
        hlc: '1700000000003:0000:dev-b',
        entity: 'checklistItem',
        entityId: 'ci-1',
        op: 'upsert',
        fields: ['id', 'taskId', 'title', 'status', 'sortKey', 'createdAt', 'updatedAt'],
        row: {
          id: 'ci-1',
          taskId,
          title: 'Orphan item',
          status: 0,
          sortKey: 'i',
          createdAt: 1100,
          updatedAt: 1100,
        },
      },
      {
        opId: 'op-a-1',
        hlc: '1700000000004:0000:dev-b',
        entity: 'attachment',
        entityId: 'att-1',
        op: 'upsert',
        fields: ['id', 'taskId', 'fileName', 'size', 'mimeType', 'createdAt', 'updatedAt'],
        row: {
          id: 'att-1',
          taskId,
          fileName: 'a.txt',
          size: 10,
          mimeType: 'text/plain',
          createdAt: 1100,
          updatedAt: 1100,
        },
      },
      {
        opId: 'op-m-1',
        hlc: '1700000000005:0000:dev-b',
        entity: 'comment',
        entityId: 'com-1',
        op: 'upsert',
        fields: ['id', 'taskId', 'authorId', 'body', 'createdAt', 'updatedAt'],
        row: {
          id: 'com-1',
          taskId,
          authorId: 'm-1',
          body: 'Orphan comment',
          createdAt: 1100,
          updatedAt: 1100,
        },
      },
    ]);

    for (const r of lateChildrenRes.results) {
      expect(r.status).toBe('applied');
      expect(typeof r.row?.purgedAt).toBe('number');
    }

    const pulled = await h.pull(userId);
    for (const item of pulled.scopes[0].rows) {
      if (
        'row' in item &&
        (item.entity === 'checklistItem' ||
          item.entity === 'attachment' ||
          item.entity === 'comment')
      ) {
        expect(typeof item.row.purgedAt).toBe('number');
      }
    }
  });

  it('tombstones child upsert appearing after task delete in the same batch', async () => {
    const taskId = 'task-same-batch';
    const res = await h.push(userId, 'dev-a', [
      {
        opId: 'op-del-1',
        hlc: '1700000000001:0000:dev-a',
        entity: 'task',
        entityId: taskId,
        op: 'delete',
        fields: [],
        row: {},
      },
      {
        opId: 'op-ci-after',
        hlc: '1700000000002:0000:dev-b',
        entity: 'checklistItem',
        entityId: 'ci-after',
        op: 'upsert',
        fields: ['id', 'taskId', 'title', 'status', 'sortKey', 'createdAt', 'updatedAt'],
        row: {
          id: 'ci-after',
          taskId,
          title: 'Same batch after delete',
          status: 0,
          sortKey: 'i',
          createdAt: 1100,
          updatedAt: 1100,
        },
      },
    ]);

    expect(res.results[1].status).toBe('applied');
    expect(typeof res.results[1].row?.purgedAt).toBe('number');
  });

  it('old taskId losing the merge must not tombstone', async () => {
    const batch1 = await h.push(userId, 'dev-a', [
      makeFullTaskOp({
        opId: 'op-t-a',
        hlc: '1700000000001:0000:dev-a',
        id: 'task-A',
        projectId,
        title: 'Task A (live)',
      }),
      makeFullTaskOp({
        opId: 'op-t-b',
        hlc: '1700000000002:0000:dev-a',
        id: 'task-B',
        projectId,
        title: 'Task B (to purge)',
      }),
      {
        opId: 'op-ci-1',
        hlc: '1700000000010:0000:dev-a',
        entity: 'checklistItem',
        entityId: 'ci-1',
        op: 'upsert',
        fields: ['id', 'taskId', 'title', 'status', 'sortKey', 'createdAt', 'updatedAt'],
        row: {
          id: 'ci-1',
          taskId: 'task-A',
          title: 'Live item',
          status: 0,
          sortKey: 'i',
          createdAt: 1000,
          updatedAt: 1000,
        },
      },
      {
        opId: 'op-t-b-del',
        hlc: '1700000000011:0000:dev-a',
        entity: 'task',
        entityId: 'task-B',
        op: 'delete',
        fields: [],
        row: {},
      },
    ]);
    expect(batch1.results.every((r) => r.status === 'applied')).toBe(true);

    // Changing taskId of an existing child is rejected with current row & clocks.
    const batch2 = await h.push(userId, 'dev-b', [
      {
        opId: 'op-ci-1-change-task',
        hlc: '1700000000005:0000:dev-b',
        entity: 'checklistItem',
        entityId: 'ci-1',
        op: 'upsert',
        fields: ['taskId'],
        row: { taskId: 'task-B' },
      },
    ]);
    expect(batch2.results[0].status).toBe('rejected');
    expect(batch2.results[0].row?.taskId).toBe('task-A');
    expect(batch2.results[0].row?.purgedAt ?? null).toBeNull();
  });
});

describe('Scope DO member isMe computation', () => {
  it('computes isMe on push, replay, pull, and stale-HLC binding', async () => {
    const h = createHarness();
    const userA = 'user-a';
    const userB = 'user-b';
    await h.db.insert(schema.user).values([
      { id: userA, createdAt: 1000 },
      { id: userB, createdAt: 1000 },
    ]);

    const pushA = await h.push(userA, 'dev-a', [
      {
        opId: 'op-me-a',
        hlc: '1700000000001:0000:dev-a',
        entity: 'member',
        entityId: 'mem-a',
        op: 'upsert',
        fields: ['id', 'name', 'initial', 'color', 'isMe', 'createdAt', 'updatedAt'],
        row: {
          id: 'mem-a',
          name: 'Alice',
          initial: 'A',
          color: '#9BB8FF',
          isMe: true,
          createdAt: 1000,
          updatedAt: 1000,
        },
      },
      {
        opId: 'op-other-a',
        hlc: '1700000000002:0000:dev-a',
        entity: 'member',
        entityId: 'mem-kid',
        op: 'upsert',
        fields: ['id', 'name', 'initial', 'color', 'isMe', 'createdAt', 'updatedAt'],
        row: {
          id: 'mem-kid',
          name: 'Kid',
          initial: 'K',
          color: '#FFB89B',
          isMe: false,
          createdAt: 1000,
          updatedAt: 1000,
        },
      },
    ]);
    expect(pushA.results[0].row?.isMe).toBe(true);
    expect(pushA.results[1].row?.isMe).toBe(false);

    const pullA = await h.pull(userA);
    const rowsA = pullA.scopes[0].rows;
    expect(
      rowsA.find((r) => 'row' in r && r.entity === 'member' && r.row.id === 'mem-a'),
    ).toMatchObject({ row: { isMe: true } });
    expect(
      rowsA.find((r) => 'row' in r && r.entity === 'member' && r.row.id === 'mem-kid'),
    ).toMatchObject({ row: { isMe: false } });

    // Simulate unbound meMemberId -> replay re-binds and bumps serverSeq.
    await h.db.update(schema.user).set({ meMemberId: null }).where(eq(schema.user.id, userA));
    const pullBefore = await h.pull(userA);
    const cursorBefore = pullBefore.scopes[0].cursor;

    const replay = await h.push(userA, 'dev-a', [
      {
        opId: 'op-me-a',
        hlc: '1700000000001:0000:dev-a',
        entity: 'member',
        entityId: 'mem-a',
        op: 'upsert',
        fields: ['id', 'name', 'initial', 'color', 'isMe', 'createdAt', 'updatedAt'],
        row: {
          id: 'mem-a',
          name: 'Alice',
          initial: 'A',
          color: '#9BB8FF',
          isMe: true,
          createdAt: 1000,
          updatedAt: 1000,
        },
      },
    ]);
    expect(replay.results[0].row?.isMe).toBe(true);

    const pullAfter = await h.pull(userA, { cursors: { [`u:${userA}`]: cursorBefore } });
    expect(pullAfter.scopes[0].rows).toHaveLength(1);
    const updatedMem = pullAfter.scopes[0].rows[0];
    expect('row' in updatedMem && updatedMem.row.isMe).toBe(true);

    // User B member stays isolated.
    const pushB = await h.push(userB, 'dev-b', [
      {
        opId: 'op-me-b',
        hlc: '1700000000003:0000:dev-b',
        entity: 'member',
        entityId: 'mem-b',
        op: 'upsert',
        fields: ['id', 'name', 'initial', 'color', 'isMe', 'createdAt', 'updatedAt'],
        row: {
          id: 'mem-b',
          name: 'Bob',
          initial: 'B',
          color: '#9BFFB8',
          isMe: true,
          createdAt: 1000,
          updatedAt: 1000,
        },
      },
    ]);
    expect(pushB.results[0].row?.isMe).toBe(true);
  });
});

describe('Scope DO SYNC_FAULT=split-txn production guard', () => {
  it('only enables split-txn when isDev is true', () => {
    expect(shouldSplitTransaction('split-txn', false)).toBe(false);
    expect(shouldSplitTransaction('none', false)).toBe(false);
    expect(shouldSplitTransaction(undefined, false)).toBe(false);
    expect(shouldSplitTransaction('split-txn', true)).toBe(true);
    expect(shouldSplitTransaction('none', true)).toBe(false);
  });

  it('refuses split-txn and runs inside transactionSync when allowFaultInjection is false', async () => {
    const doState = createTestDoState();
    const ScopeClass = Scope.class as unknown as new (
      ctx: DurableObjectState,
      env: { SYNC_FAULT: 'none' | 'split-txn' },
      allowFaultInjection?: boolean,
    ) => InstanceType<typeof ScopeObject>;
    const scope = new ScopeClass(doState.ctx, { SYNC_FAULT: 'split-txn' }, false);

    const origDev = import.meta.env.DEV;
    import.meta.env.DEV = false;
    try {
      const responses = await Promise.all(
        Array.from({ length: 5 }, (_, i) =>
          scope.push({
            scope: 'u:u1',
            scopeUserId: 'u1',
            pusherUserId: 'u1',
            deviceId: 'dev-q',
            memberships: { 'p-1': 'owner' },
            purgedProjects: [],
            meMemberId: null,
            ops: [
              makeFullTaskOp({
                opId: `op-q-${i}`,
                hlc: `170000000000${i}:0000:dev-q`,
                id: `task-q-${i}`,
                projectId: 'p-1',
                title: `Task ${i}`,
              }),
            ],
          }),
        ),
      );
      const seqs = responses.map((r) => r.serverSeq);
      expect(new Set(seqs).size).toBe(5);
    } finally {
      import.meta.env.DEV = origDev;
    }
  });
});

describe('Scope DO T5a rules', () => {
  it('rejects prototype-chain keys per-op without failing valid ops in the same batch', async () => {
    const h = createHarness();
    const userId = 'u-proto';
    await h.db.insert(schema.user).values({ id: userId, createdAt: 1_700_000_000_000 });
    await h.push(userId, 'dev-a', [
      makeProjectOp({ opId: 'op-p-proto', hlc: '1700000000000:0000:dev-a', id: 'p-1' }),
    ]);

    const res = await h.push(userId, 'dev-a', [
      {
        opId: 'op-poison-constructor',
        hlc: '1700000000001:0000:dev-a',
        entity: 'member',
        entityId: 'm-1',
        op: 'upsert',
        fields: ['constructor'],
        row: { constructor: 'x' },
      },
      {
        opId: 'op-poison-tostring',
        hlc: '1700000000002:0000:dev-a',
        entity: 'task',
        entityId: 't-proto',
        op: 'upsert',
        fields: ['toString'],
        row: {},
      },
      makeFullTaskOp({
        opId: 'op-valid-task',
        hlc: '1700000000003:0000:dev-a',
        id: 't-good',
        projectId: 'p-1',
        title: 'Survives',
      }),
    ]);

    expect(res.results).toHaveLength(3);
    expect(res.results[0]).toMatchObject({ opId: 'op-poison-constructor', status: 'rejected' });
    expect(res.results[1]).toMatchObject({ opId: 'op-poison-tostring', status: 'rejected' });
    expect(res.results[2]).toMatchObject({ opId: 'op-valid-task', status: 'applied' });
  });

  it('rejects projectMember/projectInvite ops and project delete/archive ops via sync', async () => {
    const h = createHarness();
    const userId = 'u-pol';
    await h.db.insert(schema.user).values({ id: userId, createdAt: 1_700_000_000_000 });
    const createProj = await h.push(userId, 'dev-a', [
      makeProjectOp({ opId: 'op-p1', hlc: '1700000000000:0000:dev-a', id: 'p-1', name: 'Work' }),
    ]);
    expect(createProj.results[0].status).toBe('applied');

    const res = await h.push(userId, 'dev-a', [
      {
        opId: 'op-pm',
        hlc: '1700000000001:0000:dev-a',
        entity: 'projectMember',
        entityId: 'p-1:m-1',
        op: 'upsert',
        fields: ['projectId', 'memberId', 'role', 'createdAt', 'updatedAt'],
        row: {
          projectId: 'p-1',
          memberId: 'm-1',
          role: 'owner',
          createdAt: 1000,
          updatedAt: 1000,
        },
      },
      {
        opId: 'op-pi',
        hlc: '1700000000002:0000:dev-a',
        entity: 'projectInvite',
        entityId: 'inv-1',
        op: 'upsert',
        fields: ['id', 'projectId', 'email', 'role', 'status', 'createdAt', 'updatedAt'],
        row: {
          id: 'inv-1',
          projectId: 'p-1',
          email: 'a@b.com',
          role: 'editor',
          status: 'pending',
          createdAt: 1000,
          updatedAt: 1000,
        },
      },
      {
        opId: 'op-p-softdel',
        hlc: '1700000000003:0000:dev-a',
        entity: 'project',
        entityId: 'p-1',
        op: 'upsert',
        fields: ['deletedAt'],
        row: { id: 'p-1', deletedAt: 2000 },
      },
      {
        opId: 'op-p-archive',
        hlc: '1700000000004:0000:dev-a',
        entity: 'project',
        entityId: 'p-1',
        op: 'upsert',
        fields: ['archivedAt'],
        row: { id: 'p-1', archivedAt: 2000 },
      },
      {
        opId: 'op-p-harddel',
        hlc: '1700000000005:0000:dev-a',
        entity: 'project',
        entityId: 'p-1',
        op: 'delete',
        fields: [],
        row: {},
      },
      {
        opId: 'op-p-rename',
        hlc: '1700000000006:0000:dev-a',
        entity: 'project',
        entityId: 'p-1',
        op: 'upsert',
        fields: ['name'],
        row: { id: 'p-1', name: 'Work Renamed' },
      },
    ]);

    expect(res.results[0].status).toBe('rejected');
    expect(res.results[1].status).toBe('rejected');
    expect(res.results[2]).toMatchObject({
      status: 'rejected',
      row: { id: 'p-1', name: 'Work' },
    });
    expect(res.results[3]).toMatchObject({
      status: 'rejected',
      row: { id: 'p-1', name: 'Work' },
    });
    expect(res.results[4]).toMatchObject({
      status: 'rejected',
      row: { id: 'p-1', name: 'Work' },
    });
    expect(res.results[5]).toMatchObject({
      status: 'applied',
      row: { id: 'p-1', name: 'Work Renamed' },
    });
  });

  it('rejects partial upsert to unknown row without creating entityHome, listScopes, or DO row', async () => {
    const h = createHarness();
    const userId = 'u-unknown';
    await h.db.insert(schema.user).values({ id: userId, createdAt: 1_700_000_000_000 });
    await h.push(userId, 'dev-a', [
      makeProjectOp({ opId: 'op-p1', hlc: '1700000000000:0000:dev-a', id: 'p-1' }),
    ]);

    const res = await h.push(userId, 'dev-a', [
      {
        opId: 'op-partial-missing',
        hlc: '1700000000001:0000:dev-a',
        entity: 'task',
        entityId: 't-missing',
        op: 'upsert',
        fields: ['title'],
        row: { id: 't-missing', title: 'Ghost' },
      },
      {
        opId: 'op-child-unknown-parent',
        hlc: '1700000000002:0000:dev-a',
        entity: 'checklistItem',
        entityId: 'ci-orphan',
        op: 'upsert',
        fields: ['id', 'taskId', 'title', 'status', 'sortKey', 'createdAt', 'updatedAt'],
        row: {
          id: 'ci-orphan',
          taskId: 't-missing',
          title: 'Orphan',
          status: 0,
          sortKey: 'i',
          createdAt: 1000,
          updatedAt: 1000,
        },
      },
    ]);

    expect(res.results[0]).toMatchObject({
      status: 'rejected',
      reason: 'unknown-row',
      row: null,
      clocks: {},
    });
    expect(res.results[1]).toMatchObject({
      status: 'rejected',
      reason: 'unknown-row',
      row: null,
      clocks: {},
    });

    const homeRows = h.sqlite.prepare('SELECT * FROM entityHome WHERE entityId IN (?, ?)').all('t-missing', 'ci-orphan');
    expect(homeRows).toHaveLength(0);

    const pulled = await h.pull(userId);
    expect(pulled.scopes[0].rows).toHaveLength(1); // Only p-1
  });

  it('moves task between lists, updates children projectId, bumps serverSeqs, and writes departure rows', async () => {
    const h = createHarness();
    const userId = 'u-move';
    await h.db.insert(schema.user).values({ id: userId, createdAt: 1_700_000_000_000 });

    const setupPush = await h.push(userId, 'dev-a', [
      makeProjectOp({ opId: 'op-p1', hlc: '1700000000001:0000:dev-a', id: 'p-1', name: 'L1' }),
      makeProjectOp({ opId: 'op-p2', hlc: '1700000000002:0000:dev-a', id: 'p-2', name: 'L2' }),
      makeFullTaskOp({ opId: 'op-t1', hlc: '1700000000003:0000:dev-a', id: 't-1', projectId: 'p-1' }),
      {
        opId: 'op-ci1',
        hlc: '1700000000004:0000:dev-a',
        entity: 'checklistItem',
        entityId: 'ci-1',
        op: 'upsert',
        fields: ['id', 'taskId', 'title', 'status', 'sortKey', 'createdAt', 'updatedAt'],
        row: {
          id: 'ci-1',
          taskId: 't-1',
          title: 'Sub',
          status: 0,
          sortKey: 'i',
          createdAt: 1000,
          updatedAt: 1000,
        },
      },
      {
        opId: 'op-att1',
        hlc: '1700000000005:0000:dev-a',
        entity: 'attachment',
        entityId: 'att-1',
        op: 'upsert',
        fields: ['id', 'taskId', 'fileName', 'size', 'mimeType', 'createdAt', 'updatedAt'],
        row: {
          id: 'att-1',
          taskId: 't-1',
          fileName: 'a.txt',
          size: 5,
          mimeType: 'text/plain',
          createdAt: 1000,
          updatedAt: 1000,
        },
      },
      {
        opId: 'op-com1',
        hlc: '1700000000006:0000:dev-a',
        entity: 'comment',
        entityId: 'com-1',
        op: 'upsert',
        fields: ['id', 'taskId', 'authorId', 'body', 'createdAt', 'updatedAt'],
        row: {
          id: 'com-1',
          taskId: 't-1',
          authorId: 'm-1',
          body: 'hi',
          createdAt: 1000,
          updatedAt: 1000,
        },
      },
    ]);
    expect(setupPush.results.every((r) => r.status === 'applied')).toBe(true);

    const beforePull = await h.pull(userId);
    const cursorBefore = beforePull.scopes[0].cursor;

    const moveRes = await h.push(userId, 'dev-a', [
      {
        opId: 'op-move',
        hlc: '1700000000010:0000:dev-a',
        entity: 'task',
        entityId: 't-1',
        op: 'upsert',
        fields: ['projectId', 'updatedAt'],
        row: { id: 't-1', projectId: 'p-2', updatedAt: 2000 },
      },
    ]);
    expect(moveRes.results[0].status).toBe('applied');
    expect(moveRes.results[0].row?.projectId).toBe('p-2');

    // Incremental pull returns task and all 3 children with new serverSeq > cursorBefore.
    const afterPull = await h.pull(userId, { cursors: { [`u:${userId}`]: cursorBefore } });
    const movedEntities = afterPull.scopes[0].rows.map((r) => r.entity);
    expect(movedEntities).toEqual(['task', 'checklistItem', 'attachment', 'comment']);

    // Verify departure rows were written for p-1 and requester who only has p-1 sees gone:true.
    const scopeStub = h.getScopeStub(`u:${userId}`);
    const p1OnlyPull = await scopeStub.pull({
      scope: `u:${userId}`,
      scopeUserId: userId,
      requesterUserId: 'viewer-of-p1',
      since: cursorBefore,
      limit: 100,
      memberships: { 'p-1': 'viewer' },
      meMemberId: null,
    });
    expect(p1OnlyPull.rows).toHaveLength(4);
    for (const r of p1OnlyPull.rows) {
      expect('gone' in r && r.gone).toBe(true);
    }
  });

  it('rejects new/moved rows targeting a purgedProject in D1', async () => {
    const h = createHarness();
    const userId = 'u-purged-proj';
    await h.db.insert(schema.user).values({ id: userId, createdAt: 1_700_000_000_000 });
    await h.db.insert(schema.purgedProject).values({ projectId: 'p-dead', purgedAt: 5000 });

    const res = await h.push(userId, 'dev-a', [
      makeProjectOp({ opId: 'op-p-dead', hlc: '1700000000001:0000:dev-a', id: 'p-dead' }),
      makeFullTaskOp({
        opId: 'op-t-dead',
        hlc: '1700000000002:0000:dev-a',
        id: 't-dead',
        projectId: 'p-dead',
      }),
    ]);
    expect(res.results[0].status).toBe('rejected');
    expect(res.results[1].status).toBe('rejected');
    expect(h.sqlite.prepare('SELECT * FROM listScopes WHERE projectId = ?').all('p-dead')).toHaveLength(0);
  });

  it('allows duplicate tag names across different users without entityHome and filters pull by membership', async () => {
    const h = createHarness();
    await h.db.insert(schema.user).values([
      { id: 'u-a', createdAt: 1000 },
      { id: 'u-b', createdAt: 1000 },
    ]);

    const tagOp = (opId: string, hlc: string) => ({
      opId,
      hlc,
      entity: 'tag',
      entityId: 'urgent',
      op: 'upsert',
      fields: ['name', 'label', 'sortKey', 'createdAt', 'updatedAt'],
      row: { name: 'urgent', label: 'Urgent', sortKey: 'i', createdAt: 1000, updatedAt: 1000 },
    });

    const pushA = await h.push('u-a', 'dev-a', [tagOp('op-tag-a', '1700000000001:0000:dev-a')]);
    const pushB = await h.push('u-b', 'dev-b', [tagOp('op-tag-b', '1700000000002:0000:dev-b')]);
    expect(pushA.results[0].status).toBe('applied');
    expect(pushB.results[0].status).toBe('applied');
    expect(h.sqlite.prepare('SELECT * FROM entityHome WHERE entity = ?').all('tag')).toHaveLength(0);

    // Even inside u-a's scope, a task in a list u-a is NOT a member of is filtered out of u-a's pull.
    await h.push('u-a', 'dev-a', [
      makeProjectOp({ opId: 'op-pa', hlc: '1700000000003:0000:dev-a', id: 'p-a' }),
      makeFullTaskOp({
        opId: 'op-ta',
        hlc: '1700000000004:0000:dev-a',
        id: 't-a',
        projectId: 'p-a',
      }),
    ]);
    await h.db
      .update(schema.projectMembership)
      .set({ removedAt: 9999 })
      .where(eq(schema.projectMembership.projectId, 'p-a'));

    const pullA = await h.pull('u-a');
    expect(pullA.scopes[0].rows.map((r) => r.entity)).toEqual(['tag']);
  });
});
