import { drizzle } from 'drizzle-orm/d1';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import * as schema from '../db/schema';
import { pullUserRows } from '../src/sync/db';
import { createTestD1 } from './sqliteD1';

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

const { default: Writer, shouldBypassWriterQueue } = await import('../durable-objects/writer');

function makeWriter(d1: D1Database, writerQueue: 'on' | 'off' = 'on') {
  const WriterClass = Writer.class as unknown as new (
    ctx: unknown,
    env: { DB: D1Database; WRITER_QUEUE: 'on' | 'off' },
  ) => {
    push: (input: { userId: string; deviceId: string; ops: unknown[] }) => Promise<{
      results: Array<{
        opId: string;
        status: 'applied' | 'rejected';
        reason?: string;
        row: Record<string, unknown> | null;
        clocks: Record<string, string>;
      }>;
      serverSeq: number;
    }>;
  };
  return new WriterClass({}, { DB: d1, WRITER_QUEUE: writerQueue });
}

describe('Writer child-after-task-purge (Finding 1)', () => {
  let d1: D1Database;
  let db: ReturnType<typeof createTestD1>['db'];
  const userId = 'u-1';
  const now = 1_700_000_000_000;

  beforeEach(async () => {
    const setup = createTestD1();
    d1 = setup.d1;
    db = setup.db;
    await db.insert(schema.user).values({ id: userId, createdAt: now });
  });

  it('tombstones late-arriving checklistItem, attachment, and comment when parent task was already purged', async () => {
    const writer = makeWriter(d1);
    const taskId = 'task-purged-1';

    // Device A creates and purges task T.
    const purgeRes = await writer.push({
      userId,
      deviceId: 'dev-a',
      ops: [
        {
          opId: 'op-t-create',
          hlc: '1700000000001:0000:dev-a',
          entity: 'task',
          entityId: taskId,
          op: 'upsert',
          fields: ['id', 'projectId', 'title', 'sortKey', 'createdAt', 'updatedAt'],
          row: {
            id: taskId,
            projectId: 'p-1',
            title: 'Task',
            sortKey: 'i',
            createdAt: 1000,
            updatedAt: 1000,
          },
        },
        {
          opId: 'op-t-purge',
          hlc: '1700000000002:0000:dev-a',
          entity: 'task',
          entityId: taskId,
          op: 'delete',
          fields: [],
          row: {},
        },
      ],
    });
    expect(purgeRes.results.every((r) => r.status === 'applied')).toBe(true);

    // Device B (offline) pushes new child rows under already-purged task T.
    const lateChildrenRes = await writer.push({
      userId,
      deviceId: 'dev-b',
      ops: [
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
      ],
    });

    for (const r of lateChildrenRes.results) {
      expect(r.status).toBe('applied');
      expect(typeof r.row?.purgedAt).toBe('number');
    }

    const pulled = await pullUserRows(db, { userId, since: 0, limit: 100 });
    for (const item of pulled.rows) {
      if (
        item.entity === 'checklistItem' ||
        item.entity === 'attachment' ||
        item.entity === 'comment'
      ) {
        expect(typeof item.row.purgedAt).toBe('number');
      }
    }
  });

  it('tombstones child upsert appearing after task delete in the same batch', async () => {
    const writer = makeWriter(d1);
    const taskId = 'task-same-batch';

    const res = await writer.push({
      userId,
      deviceId: 'dev-a',
      ops: [
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
      ],
    });

    expect(res.results[1].status).toBe('applied');
    expect(typeof res.results[1].row?.purgedAt).toBe('number');
  });
});

describe('Writer member isMe computation (Finding 2)', () => {
  it('computes isMe boolean on push, replay, and pull per user account', async () => {
    const setup = createTestD1();
    const userA = 'user-a';
    const userB = 'user-b';
    await setup.db.insert(schema.user).values([
      { id: userA, createdAt: 1000 },
      { id: userB, createdAt: 1000 },
    ]);

    const writer = makeWriter(setup.d1);
    const pushA = await writer.push({
      userId: userA,
      deviceId: 'dev-a',
      ops: [
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
      ],
    });

    expect(pushA.results[0].row?.isMe).toBe(true);
    expect(pushA.results[1].row?.isMe).toBe(false);

    // Replay returns computed isMe as well.
    const replayA = await writer.push({
      userId: userA,
      deviceId: 'dev-a',
      ops: [
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
      ],
    });
    expect(replayA.results[0].row?.isMe).toBe(true);

    // Pull for userA returns isMe: true for mem-a and false for mem-kid.
    const pullA = await pullUserRows(setup.db, { userId: userA, since: 0, limit: 100 });
    const pulledMe = pullA.rows.find((r) => r.entity === 'member' && r.row.id === 'mem-a');
    const pulledKid = pullA.rows.find((r) => r.entity === 'member' && r.row.id === 'mem-kid');
    expect(pulledMe?.row.isMe).toBe(true);
    expect(pulledKid?.row.isMe).toBe(false);

    // Another user B pushing their own member gets isMe: true for mem-b only.
    const pushB = await writer.push({
      userId: userB,
      deviceId: 'dev-b',
      ops: [
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
      ],
    });
    expect(pushB.results[0].row?.isMe).toBe(true);
  });
});

describe('Writer WRITER_QUEUE production guard (Finding 4)', () => {
  it('only allows WRITER_QUEUE=off bypass when isDev is true', () => {
    expect(shouldBypassWriterQueue('off', false)).toBe(false);
    expect(shouldBypassWriterQueue('on', false)).toBe(false);
    expect(shouldBypassWriterQueue(undefined, false)).toBe(false);
    expect(shouldBypassWriterQueue('off', true)).toBe(true);
    expect(shouldBypassWriterQueue('on', true)).toBe(false);
  });

  it('refuses WRITER_QUEUE=off and serializes writes when not in dev mode', async () => {
    const setup = createTestD1();
    const userId = 'user-q';
    await setup.db.insert(schema.user).values({ id: userId, createdAt: 1000 });

    // Wrap D1 with a small async delay so unserialized concurrent batches interleave and collide on seq.
    const slowD1 = new Proxy(setup.d1, {
      get(target, prop, receiver) {
        if (prop === 'withSession') {
          return (...args: unknown[]) => {
            const session = (target.withSession as (...a: unknown[]) => D1DatabaseSession)(...args);
            return new Proxy(session, {
              get(sTarget, sProp, sReceiver) {
                if (sProp === 'batch') {
                  return async (stmts: D1PreparedStatement[]) => {
                    await new Promise((r) => setTimeout(r, 10));
                    return sTarget.batch(stmts);
                  };
                }
                return Reflect.get(sTarget, sProp, sReceiver);
              },
            });
          };
        }
        return Reflect.get(target, prop, receiver);
      },
    });

    const origDev = import.meta.env.DEV;
    import.meta.env.DEV = false;
    try {
      const WriterClass = Writer.class as unknown as new (
        ctx: unknown,
        env: { DB: D1Database; WRITER_QUEUE: 'on' | 'off' },
        allowQueueBypass?: boolean,
      ) => {
        push: (input: { userId: string; deviceId: string; ops: unknown[] }) => Promise<{
          results: Array<{ status: string }>;
          serverSeq: number;
        }>;
      };
      const writer = new WriterClass({}, { DB: slowD1, WRITER_QUEUE: 'off' }, false);

      const responses = await Promise.all(
        Array.from({ length: 5 }, (_, i) =>
          writer.push({
            userId,
            deviceId: 'dev-q',
            ops: [
              {
                opId: `op-q-${i}`,
                hlc: `170000000000${i}:0000:dev-q`,
                entity: 'task',
                entityId: `task-q-${i}`,
                op: 'upsert',
                fields: ['id', 'projectId', 'title', 'sortKey', 'createdAt', 'updatedAt'],
                row: {
                  id: `task-q-${i}`,
                  projectId: 'p-1',
                  title: `Task ${i}`,
                  sortKey: 'i',
                  createdAt: 1000,
                  updatedAt: 1000,
                },
              },
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

describe('Writer prototype-chain field poison batch resilience (Finding 5)', () => {
  it('rejects ops with prototype-chain keys per-op without failing valid ops in the same batch', async () => {
    const setup = createTestD1();
    const userId = 'u-proto-1';
    await setup.db.insert(schema.user).values({ id: userId, createdAt: 1_700_000_000_000 });

    const writer = makeWriter(setup.d1);
    const res = await writer.push({
      userId,
      deviceId: 'dev-a',
      ops: [
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
        {
          opId: 'op-valid-task',
          hlc: '1700000000003:0000:dev-a',
          entity: 'task',
          entityId: 't-good',
          op: 'upsert',
          fields: ['id', 'projectId', 'title', 'sortKey', 'createdAt', 'updatedAt'],
          row: {
            id: 't-good',
            projectId: 'p-1',
            title: 'Survives poison op',
            sortKey: 'i',
            createdAt: 1000,
            updatedAt: 1000,
          },
        },
      ],
    });

    expect(res.results).toHaveLength(3);
    expect(res.results[0]).toMatchObject({ opId: 'op-poison-constructor', status: 'rejected' });
    expect(res.results[1]).toMatchObject({ opId: 'op-poison-tostring', status: 'rejected' });
    expect(res.results[2]).toMatchObject({ opId: 'op-valid-task', status: 'applied' });

    const appliedRows = setup.sqlite
      .prepare('SELECT opId, status FROM op_applied WHERE userId = ? ORDER BY opId')
      .all(userId) as Array<{ opId: string; status: string }>;
    expect(appliedRows).toEqual([
      { opId: 'op-poison-constructor', status: 'rejected' },
      { opId: 'op-poison-tostring', status: 'rejected' },
      { opId: 'op-valid-task', status: 'applied' },
    ]);
  });
});
