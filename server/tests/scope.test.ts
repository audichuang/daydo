import { eq } from 'drizzle-orm';
import { drizzle } from 'drizzle-orm/d1';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import * as schema from '../db/schema';
import { compareHlc, createServerHlcClock, MAX_FUTURE_DRIFT_MS } from '../src/sync/hlc';
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
  const clock = createServerHlcClock();

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
      executeSyncPush(db, { userId, deviceId, ops, getScopeStub, clock }),
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

function serializeDbBatch(db: Harness['db']): void {
  const origBatch = db.batch.bind(db);
  let batchQueue: Promise<unknown> = Promise.resolve();
  db.batch = ((stmts: Parameters<typeof origBatch>[0]) => {
    const next = batchQueue.then(() => origBatch(stmts));
    batchQueue = next.catch(() => {});
    return next;
  }) as unknown as typeof db.batch;
}

describe('Scope DO T5a regression fixes', () => {
  it('Finding 1: recovers/writes owner membership when Batch 3 fails transiently on project creation', async () => {
    const h = createHarness();
    const userId = 'u-f1';
    await h.db.insert(schema.user).values({ id: userId, createdAt: 1_700_000_000_000 });

    const origBatch = h.db.batch.bind(h.db);
    let batchCount = 0;
    h.db.batch = (async (stmts: Parameters<typeof origBatch>[0]) => {
      batchCount += 1;
      if (batchCount === 3) {
        throw new Error('Simulated transient D1 batch 3 failure');
      }
      return origBatch(stmts);
    }) as unknown as typeof h.db.batch;

    const projOp = makeProjectOp({
      opId: 'op-p-f1',
      hlc: '1700000000001:0000:dev-a',
      id: 'p-f1',
      name: 'My List',
    });

    await expect(h.push(userId, 'dev-a', [projOp])).rejects.toThrow(
      'Simulated transient D1 batch 3 failure',
    );
    h.db.batch = origBatch;

    const homeRow = h.sqlite
      .prepare('SELECT * FROM entityHome WHERE entity = ? AND entityId = ?')
      .get('project', 'p-f1') as { scope: string } | undefined;
    expect(homeRow?.scope).toBe(`u:${userId}`);

    // Retry with same opId (twice) and then a new opId updating the list.
    const retry1 = await h.push(userId, 'dev-a', [projOp]);
    expect(retry1.results[0].status).toBe('applied');

    const retry2 = await h.push(userId, 'dev-a', [projOp]);
    expect(retry2.results[0].status).toBe('applied');

    const updateRes = await h.push(userId, 'dev-a', [
      {
        opId: 'op-p-f1-rename',
        hlc: '1700000000002:0000:dev-a',
        entity: 'project',
        entityId: 'p-f1',
        op: 'upsert',
        fields: ['name'],
        row: { id: 'p-f1', name: 'My List Renamed' },
      },
    ]);
    expect(updateRes.results[0].status).toBe('applied');

    const memberships = h.sqlite
      .prepare('SELECT role, removedAt FROM projectMembership WHERE projectId = ? AND userId = ?')
      .all('p-f1', userId) as Array<{ role: string; removedAt: number | null }>;
    expect(memberships).toEqual([{ role: 'owner', removedAt: null }]);

    const listScopesRows = h.sqlite
      .prepare('SELECT scope FROM listScopes WHERE projectId = ?')
      .all('p-f1') as Array<{ scope: string }>;
    expect(listScopesRows).toEqual([{ scope: `u:${userId}` }]);

    const pulled = await h.pull(userId);
    expect(pulled.scopes[0].rows.some((r) => 'row' in r && r.row.id === 'p-f1')).toBe(true);
  });

  it('Finding 2: concurrent first-send + resend does not delete live entityHome', async () => {
    const h = createHarness();
    const userId = 'u-f2';
    await h.db.insert(schema.user).values({ id: userId, createdAt: 1_700_000_000_000 });

    // Serialize db.batch calls with a mutex since sqliteD1 cannot nest BEGIN IMMEDIATE.
    serializeDbBatch(h.db);

    const initProj = await h.push(userId, 'dev-a', [
      makeProjectOp({ opId: 'op-p-f2', hlc: '1700000000000:0000:dev-a', id: 'p-1' }),
    ]);
    expect(initProj.results[0].status).toBe('applied');

    const taskOp = makeFullTaskOp({
      opId: 'op-t-conc',
      hlc: '1700000000001:0000:dev-a',
      id: 'task-X',
      projectId: 'p-1',
      title: 'Concurrent Task',
    });

    const [res1, res2] = await Promise.all([
      h.push(userId, 'dev-a', [taskOp]),
      h.push(userId, 'dev-a', [taskOp]),
    ]);
    expect(res1.results[0].status).toBe('applied');
    expect(res2.results[0].status).toBe('applied');

    const homeRow = h.sqlite
      .prepare('SELECT * FROM entityHome WHERE entity = ? AND entityId = ?')
      .get('task', 'task-X') as { scope: string } | undefined;
    expect(homeRow?.scope).toBe(`u:${userId}`);

    // Subsequent partial update and child item creation must succeed.
    const partialRes = await h.push(userId, 'dev-a', [
      {
        opId: 'op-t-conc-update',
        hlc: '1700000000002:0000:dev-a',
        entity: 'task',
        entityId: 'task-X',
        op: 'upsert',
        fields: ['title'],
        row: { id: 'task-X', title: 'Updated Title' },
      },
      {
        opId: 'op-ci-conc',
        hlc: '1700000000003:0000:dev-a',
        entity: 'checklistItem',
        entityId: 'ci-X',
        op: 'upsert',
        fields: ['id', 'taskId', 'title', 'status', 'sortKey', 'createdAt', 'updatedAt'],
        row: {
          id: 'ci-X',
          taskId: 'task-X',
          title: 'Subtask',
          status: 0,
          sortKey: 'i',
          createdAt: 1100,
          updatedAt: 1100,
        },
      },
    ]);
    expect(partialRes.results[0].status).toBe('applied');
    expect(partialRes.results[0].row?.title).toBe('Updated Title');
    expect(partialRes.results[1].status).toBe('applied');
  });

  it('Finding 1 (knownHome backfill & guard): backfills owner only when projectMembership has no rows', async () => {
    const h = createHarness();
    const userId = 'u-f1-backfill';
    await h.db.insert(schema.user).values({ id: userId, createdAt: 1_700_000_000_000 });

    // Simulate pre-existing partial state: entityHome bound without projectMembership.
    await h.db.insert(schema.entityHome).values({
      entity: 'project',
      entityId: 'p-orphan',
      scope: `u:${userId}`,
    });

    const backfillRes = await h.push(userId, 'dev-a', [
      makeProjectOp({ opId: 'op-p-orphan', hlc: '1700000000001:0000:dev-a', id: 'p-orphan' }),
    ]);
    expect(backfillRes.results[0].status).toBe('applied');

    const memberships = h.sqlite
      .prepare('SELECT role, removedAt FROM projectMembership WHERE projectId = ? AND userId = ?')
      .all('p-orphan', userId) as Array<{ role: string; removedAt: number | null }>;
    expect(memberships).toEqual([{ role: 'owner', removedAt: null }]);

    // Guard: if creator was removed (removedAt != null) or another owner exists, must NOT re-grant owner.
    await h.db.insert(schema.entityHome).values({
      entity: 'project',
      entityId: 'p-removed',
      scope: `u:${userId}`,
    });
    await h.db.insert(schema.projectMembership).values({
      projectId: 'p-removed',
      userId,
      role: 'editor',
      createdAt: 1000,
      removedAt: 2000,
    });

    const removedRes = await h.push(userId, 'dev-a', [
      makeProjectOp({ opId: 'op-p-removed', hlc: '1700000000002:0000:dev-a', id: 'p-removed' }),
    ]);
    expect(removedRes.results[0]).toMatchObject({ status: 'rejected', reason: 'Forbidden' });
  });

  it('Finding 2: replay returns applied/gone without rollback and rejected concurrent op preserves live entityHome', async () => {
    const h = createHarness();
    const userId = 'u-f2-class';
    await h.db.insert(schema.user).values({ id: userId, createdAt: 1_700_000_000_000 });

    await h.push(userId, 'dev-a', [
      makeProjectOp({ opId: 'op-p-class', hlc: '1700000000000:0000:dev-a', id: 'p-class' }),
    ]);

    const taskOp = makeFullTaskOp({
      opId: 'op-t-replay',
      hlc: '1700000000001:0000:dev-a',
      id: 'task-R',
      projectId: 'p-class',
    });
    const stub = h.getScopeStub(`u:${userId}`);
    const first = await stub.push({
      scope: `u:${userId}`,
      scopeUserId: userId,
      pusherUserId: userId,
      deviceId: 'dev-a',
      memberships: { 'p-class': 'owner' },
      purgedProjects: [],
      meMemberId: null,
      ops: [taskOp],
    });
    expect(first.results[0].status).toBe('applied');

    const replay = await stub.push({
      scope: `u:${userId}`,
      scopeUserId: userId,
      pusherUserId: userId,
      deviceId: 'dev-a',
      memberships: { 'p-class': 'owner' },
      purgedProjects: [],
      meMemberId: null,
      ops: [taskOp],
    });
    expect(replay.results[0].status).toBe('applied');

    // Even when gone:true (no longer a member), replay still succeeds with gone:true.
    const goneReplay = await stub.push({
      scope: `u:${userId}`,
      scopeUserId: userId,
      pusherUserId: userId,
      deviceId: 'dev-a',
      memberships: {},
      purgedProjects: [],
      meMemberId: null,
      ops: [taskOp],
    });
    expect(goneReplay.results[0]).toMatchObject({ status: 'applied', gone: true });

    // Concurrent valid create + rejected op for same task-Y: rejected op must not delete live entityHome.
    // Seed a rejected opId in the DO first so the second concurrent request gets rejected in DO.
    await stub.push({
      scope: `u:${userId}`,
      scopeUserId: userId,
      pusherUserId: userId,
      deviceId: 'dev-a',
      memberships: { 'p-class': 'owner' },
      purgedProjects: [],
      meMemberId: null,
      ops: [
        {
          opId: 'op-bad-reuse',
          hlc: 'bad-hlc',
          entity: 'task',
          entityId: 'task-other',
          op: 'upsert',
          fields: ['id'],
          row: { id: 'task-other' },
        },
      ],
    });

    serializeDbBatch(h.db);

    const validTaskY = makeFullTaskOp({
      opId: 'op-t-y-good',
      hlc: '1700000000005:0000:dev-a',
      id: 'task-Y',
      projectId: 'p-class',
    });
    const rejectedTaskY = makeFullTaskOp({
      opId: 'op-bad-reuse',
      hlc: '1700000000006:0000:dev-a',
      id: 'task-Y',
      projectId: 'p-class',
    });

    const [goodRes, badRes] = await Promise.all([
      h.push(userId, 'dev-a', [validTaskY]),
      h.push(userId, 'dev-a', [rejectedTaskY]),
    ]);
    expect(goodRes.results[0].status).toBe('applied');
    expect(badRes.results[0].status).toBe('rejected');

    const homeY = h.sqlite
      .prepare('SELECT scope FROM entityHome WHERE entity = ? AND entityId = ?')
      .get('task', 'task-Y') as { scope: string } | undefined;
    expect(homeY?.scope).toBe(`u:${userId}`);
  });

  it('Finding 1 (new): rejects full creates for ids already bound to another scope with id-in-other-scope, no gone, no listScopes, no DO call', async () => {
    const h = createHarness();
    const userA = 'u-f1-a';
    const userB = 'u-f1-b';
    await h.db.insert(schema.user).values([
      { id: userA, createdAt: 1000 },
      { id: userB, createdAt: 1000 },
    ]);

    const projA = 'proj-a';
    const projB = 'proj-b';
    const sharedProjId = 'proj-colliding';
    const sharedTaskId = 'task-colliding';
    const sharedMemberId = 'member-colliding';
    const sharedFolderId = 'folder-colliding';
    const sharedChildId = 'ci-colliding';

    const pushA = await h.push(userA, 'dev-a', [
      makeProjectOp({ opId: 'op-a-pa', hlc: '1700000000001:0000:dev-a', id: projA, name: 'A List' }),
      makeProjectOp({
        opId: 'op-a-pc',
        hlc: '1700000000002:0000:dev-a',
        id: sharedProjId,
        name: 'A Colliding List',
      }),
      {
        opId: 'op-a-mem',
        hlc: '1700000000003:0000:dev-a',
        entity: 'member',
        entityId: sharedMemberId,
        op: 'upsert',
        fields: ['id', 'name', 'initial', 'color', 'isMe', 'createdAt', 'updatedAt'],
        row: {
          id: sharedMemberId,
          name: 'Alice',
          initial: 'A',
          color: '#111111',
          isMe: true,
          createdAt: 1000,
          updatedAt: 1000,
        },
      },
      {
        opId: 'op-a-fol',
        hlc: '1700000000004:0000:dev-a',
        entity: 'folder',
        entityId: sharedFolderId,
        op: 'upsert',
        fields: ['id', 'name', 'sortKey', 'createdAt', 'updatedAt'],
        row: {
          id: sharedFolderId,
          name: 'A Folder',
          sortKey: 'i',
          createdAt: 1000,
          updatedAt: 1000,
        },
      },
      makeFullTaskOp({
        opId: 'op-a-t',
        hlc: '1700000000005:0000:dev-a',
        id: sharedTaskId,
        projectId: projA,
        title: 'A Task',
      }),
      {
        opId: 'op-a-ci',
        hlc: '1700000000006:0000:dev-a',
        entity: 'checklistItem',
        entityId: sharedChildId,
        op: 'upsert',
        fields: ['id', 'taskId', 'title', 'status', 'sortKey', 'createdAt', 'updatedAt'],
        row: {
          id: sharedChildId,
          taskId: sharedTaskId,
          title: 'A Item',
          status: 0,
          sortKey: 'i',
          createdAt: 1000,
          updatedAt: 1000,
        },
      },
    ]);
    expect(pushA.results.every((r) => r.status === 'applied')).toBe(true);

    // User B initializes their own project and task.
    const taskB = 'task-b-own';
    const setupB = await h.push(userB, 'dev-b', [
      makeProjectOp({ opId: 'op-b-pb', hlc: '1700000000010:0000:dev-b', id: projB, name: 'B List' }),
      makeFullTaskOp({
        opId: 'op-b-tb',
        hlc: '1700000000011:0000:dev-b',
        id: taskB,
        projectId: projB,
        title: 'B Own Task',
      }),
    ]);
    expect(setupB.results.every((r) => r.status === 'applied')).toBe(true);

    // Spy on Scope DO calls to ensure userA's DO is never called during B's colliding creates.
    let scopeACalls = 0;
    const spyGetScopeStub = (scope: string): ScopeStub => {
      const stub = h.getScopeStub(scope);
      if (scope !== `u:${userA}`) return stub;
      return {
        push: async (input) => {
          scopeACalls += 1;
          return stub.push(input);
        },
        pull: (input) => stub.pull(input),
        getInboxProjectId: (input) => stub.getInboxProjectId(input),
      };
    };

    const collideRes = await executeSyncPush(h.db, {
      userId: userB,
      deviceId: 'dev-b',
      getScopeStub: spyGetScopeStub,
      ops: [
        makeFullTaskOp({
          opId: 'op-b-col-task',
          hlc: '1700000000020:0000:dev-b',
          id: sharedTaskId,
          projectId: projB,
          title: 'B Colliding Task',
        }),
        makeProjectOp({
          opId: 'op-b-col-proj',
          hlc: '1700000000021:0000:dev-b',
          id: sharedProjId,
          name: 'B Colliding List',
        }),
        {
          opId: 'op-b-col-mem',
          hlc: '1700000000022:0000:dev-b',
          entity: 'member',
          entityId: sharedMemberId,
          op: 'upsert',
          fields: ['id', 'name', 'initial', 'color', 'isMe', 'createdAt', 'updatedAt'],
          row: {
            id: sharedMemberId,
            name: 'Bob',
            initial: 'B',
            color: '#222222',
            isMe: true,
            createdAt: 1000,
            updatedAt: 1000,
          },
        },
        {
          opId: 'op-b-col-fol',
          hlc: '1700000000023:0000:dev-b',
          entity: 'folder',
          entityId: sharedFolderId,
          op: 'upsert',
          fields: ['id', 'name', 'sortKey', 'createdAt', 'updatedAt'],
          row: {
            id: sharedFolderId,
            name: 'B Folder',
            sortKey: 'i',
            createdAt: 1000,
            updatedAt: 1000,
          },
        },
        {
          opId: 'op-b-col-ci',
          hlc: '1700000000024:0000:dev-b',
          entity: 'checklistItem',
          entityId: sharedChildId,
          op: 'upsert',
          fields: ['id', 'taskId', 'title', 'status', 'sortKey', 'createdAt', 'updatedAt'],
          row: {
            id: sharedChildId,
            taskId: taskB,
            title: 'B Item on B Task',
            status: 0,
            sortKey: 'i',
            createdAt: 1000,
            updatedAt: 1000,
          },
        },
        // Same-batch child referencing a task rejected with id-in-other-scope must also reject without touching u:A.
        {
          opId: 'op-b-col-child-of-col-task',
          hlc: '1700000000025:0000:dev-b',
          entity: 'checklistItem',
          entityId: 'ci-new-under-col-task',
          op: 'upsert',
          fields: ['id', 'taskId', 'title', 'status', 'sortKey', 'createdAt', 'updatedAt'],
          row: {
            id: 'ci-new-under-col-task',
            taskId: sharedTaskId,
            title: 'Child of colliding task',
            status: 0,
            sortKey: 'i',
            createdAt: 1000,
            updatedAt: 1000,
          },
        },
      ],
    });

    expect(scopeACalls).toBe(0);
    for (const r of collideRes.results) {
      expect(r).toEqual({
        opId: r.opId,
        status: 'rejected',
        reason: 'id-in-other-scope',
        row: null,
        clocks: {},
      });
      expect(Object.hasOwn(r, 'gone')).toBe(false);
    }

    // Batch 3 must NOT register listScopes(projB, u:userA).
    const bogusListScopes = h.sqlite
      .prepare('SELECT * FROM listScopes WHERE projectId = ? AND scope = ?')
      .all(projB, `u:${userA}`);
    expect(bogusListScopes).toHaveLength(0);

    // Child entityHome for ci-new-under-col-task must NOT be written.
    const orphanChildHome = h.sqlite
      .prepare('SELECT * FROM entityHome WHERE entity = ? AND entityId = ?')
      .all('checklistItem', 'ci-new-under-col-task');
    expect(orphanChildHome).toHaveLength(0);

    // Legitimate shared-list collaboration: editor B creating a child on A's task (home = u:A)
    // and replaying it must still route to u:A and succeed.
    await h.db.insert(schema.projectMembership).values({
      projectId: projA,
      userId: userB,
      role: 'editor',
      createdAt: 1000,
      removedAt: null,
    });
    const sharedChildOp = {
      opId: 'op-b-shared-ci',
      hlc: '1700000000030:0000:dev-b',
      entity: 'checklistItem',
      entityId: 'ci-shared-legit',
      op: 'upsert',
      fields: ['id', 'taskId', 'title', 'status', 'sortKey', 'createdAt', 'updatedAt'],
      row: {
        id: 'ci-shared-legit',
        taskId: sharedTaskId,
        title: 'Legit Shared Child',
        status: 0,
        sortKey: 'i',
        createdAt: 1000,
        updatedAt: 1000,
      },
    };
    const sharedFirst = await h.push(userB, 'dev-b', [sharedChildOp]);
    expect(sharedFirst.results[0].status).toBe('applied');
    const sharedReplay = await h.push(userB, 'dev-b', [sharedChildOp]);
    expect(sharedReplay.results[0].status).toBe('applied');
  });

  it('Finding 2 (new): A DO-rejected -> B creates the same project -> A finishes leaves B owner membership and entityHome intact', async () => {
    const h = createHarness();
    const userId = 'u-f2-proj-race';
    await h.db.insert(schema.user).values({ id: userId, createdAt: 1_700_000_000_000 });

    const projId = 'p-race';
    const rejectedOpId = 'op-proj-rejected-seed';
    const scopeStub = h.getScopeStub(`u:${userId}`);

    // Seed op-proj-rejected-seed as rejected in DO so Request A gets rejected by DO after D1 Batch 2.
    await scopeStub.push({
      scope: `u:${userId}`,
      scopeUserId: userId,
      pusherUserId: userId,
      deviceId: 'dev-a',
      memberships: {},
      purgedProjects: [],
      meMemberId: null,
      ops: [
        {
          opId: rejectedOpId,
          hlc: 'bad-hlc',
          entity: 'project',
          entityId: 'p-other',
          op: 'upsert',
          fields: ['id'],
          row: { id: 'p-other' },
        },
      ],
    });

    const opA = makeProjectOp({
      opId: rejectedOpId,
      hlc: '1700000000001:0000:dev-a',
      id: projId,
      name: 'From A',
    });
    const opB = makeProjectOp({
      opId: 'op-proj-valid-b',
      hlc: '1700000000002:0000:dev-b',
      id: projId,
      name: 'From B',
    });

    let bResult: Awaited<ReturnType<typeof h.push>> | null = null;
    const interleavedGetScopeStub = (scope: string): ScopeStub => {
      const real = h.getScopeStub(scope);
      return {
        pull: (input) => real.pull(input),
        getInboxProjectId: (input) => real.getInboxProjectId(input),
        push: async (input) => {
          const res = await real.push(input);
          // A's DO push just finished (rejected); before A continues to postStmts, B creates the same project.
          bResult = await h.push(userId, 'dev-b', [opB]);
          return res;
        },
      };
    };

    const aResult = await executeSyncPush(h.db, {
      userId,
      deviceId: 'dev-a',
      ops: [opA],
      getScopeStub: interleavedGetScopeStub,
    });

    expect(aResult.results[0].status).toBe('rejected');
    expect(bResult).not.toBeNull();
    expect(bResult!.results[0].status).toBe('applied');

    const homeRow = h.sqlite
      .prepare('SELECT scope FROM entityHome WHERE entity = ? AND entityId = ?')
      .get('project', projId) as { scope: string } | undefined;
    expect(homeRow?.scope).toBe(`u:${userId}`);

    const membershipRow = h.sqlite
      .prepare('SELECT role, removedAt FROM projectMembership WHERE projectId = ? AND userId = ?')
      .get(projId, userId) as { role: string; removedAt: number | null } | undefined;
    expect(membershipRow).toEqual({ role: 'owner', removedAt: null });

    const pulled = await h.pull(userId);
    expect(pulled.memberships.some((m) => m.projectId === projId && m.role === 'owner')).toBe(true);
    expect(
      pulled.scopes[0].rows.some((r) => 'row' in r && r.entity === 'project' && r.row.id === projId),
    ).toBe(true);
  });
});

describe('Scope DO T5b serverTime & inbox RPC', () => {
  it('returns monotonic HLC serverTime >= assigned and clamped batch HLCs even at fixed wall clock', async () => {
    const fixedNow = 1_750_000_000_000;
    const nowSpy = vi.spyOn(Date, 'now').mockReturnValue(fixedNow);
    try {
      const h = createHarness();
      const userId = 'u-srv-time';
      await h.db.insert(schema.user).values({ id: userId, createdAt: fixedNow });

      const empty1 = await h.push(userId, 'zzz-dev', []);
      const empty2 = await h.push(userId, 'zzz-dev', []);
      expect(empty1.serverTime).toMatch(/^\d{13}:\d{4}:server$/);
      expect(compareHlc(empty2.serverTime, empty1.serverTime)).toBe(1);

      // Push project + task with unclamped future-within-5m HLC and deviceId > 'server'
      const futureWithinLimit = `${fixedNow + 60_000}:0005:zzz-dev`;
      const p1 = await h.push(userId, 'zzz-dev', [
        makeProjectOp({
          opId: 'op-st-p1',
          hlc: `${fixedNow}:0000:zzz-dev`,
          id: 'p-st',
        }),
        makeFullTaskOp({
          opId: 'op-st-t1',
          hlc: futureWithinLimit,
          id: 't-st-1',
          projectId: 'p-st',
          title: 'Future within drift',
        }),
      ]);
      expect(p1.results.every((r) => r.status === 'applied')).toBe(true);
      expect(compareHlc(p1.serverTime, futureWithinLimit)).toBeGreaterThanOrEqual(0);
      expect(compareHlc(p1.serverTime, empty2.serverTime)).toBe(1);

      // Next push at the exact same fixedNow (with an older/clamped HLC) must stay strictly > p1.serverTime.
      const tooFarFuture = `${fixedNow + MAX_FUTURE_DRIFT_MS + 60_000}:0000:zzz-dev`;
      const p2 = await h.push(userId, 'zzz-dev', [
        makeFullTaskOp({
          opId: 'op-st-t2',
          hlc: tooFarFuture,
          id: 't-st-2',
          projectId: 'p-st',
          title: 'Clamped',
        }),
      ]);
      expect(p2.results[0].status).toBe('applied');
      const clampedClock = p2.results[0].clocks.title;
      expect(compareHlc(clampedClock, tooFarFuture)).toBe(-1);
      expect(compareHlc(p2.serverTime, clampedClock)).toBeGreaterThanOrEqual(0);
      expect(compareHlc(p2.serverTime, p1.serverTime)).toBe(1);
    } finally {
      nowSpy.mockRestore();
    }
  });

  it('getInboxProjectId returns readable inbox id and ignores non-inbox or unreadable lists', async () => {
    const h = createHarness();
    const userId = 'u-inbox-rpc';
    await h.db.insert(schema.user).values({ id: userId, createdAt: 1000 });

    const stub = h.getScopeStub(`u:${userId}`);
    expect(await stub.getInboxProjectId({ readableProjectIds: [] })).toBeNull();

    await h.push(userId, 'dev-a', [
      makeProjectOp({ opId: 'op-reg', hlc: '1700000000001:0000:dev-a', id: 'p-regular', name: 'Work' }),
      {
        opId: 'op-inbox',
        hlc: '1700000000002:0000:dev-a',
        entity: 'project',
        entityId: 'p-inbox',
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
          id: 'p-inbox',
          name: 'Inbox',
          viewMode: 'list',
          kind: 'TASK',
          isInbox: true,
          ownerId: 'm-1',
          sortKey: 'a',
          showInSmart: 'all',
          notifyMode: 'all',
          createdAt: 1000,
          updatedAt: 1000,
        },
      },
    ]);

    expect(await stub.getInboxProjectId({ readableProjectIds: ['p-regular'] })).toBeNull();
    expect(await stub.getInboxProjectId({ readableProjectIds: ['p-regular', 'p-inbox'] })).toBe(
      'p-inbox',
    );
  });
});
