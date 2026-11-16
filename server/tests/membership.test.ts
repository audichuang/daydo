import { and, eq } from 'drizzle-orm';
import { describe, expect, it } from 'vitest';
import * as schema from '../db/schema';
import { createSessionForIdentity, type DatabaseClient } from '../src/auth/session';
import {
  acceptInvite,
  createInvite,
  removeProjectMember,
  updateProjectMemberRole,
} from '../src/sharing';
import { executeSyncPull } from '../src/sync/pull';
import { executeSyncPush } from '../src/sync/push';
import type { ScopeStub } from '../src/scope/api';
import { createScopeWorld, type ScopeWorld } from './helpers/scopeWorld';

// Pins how membership work is grouped into D1 round trips. The "permanently delete a
// list" path relies on purgedProject + membership removal + listScopes read landing in
// one batch, and every caller's batch layout must survive refactors unchanged.

const uA = 'user-a';
const uB = 'user-b';
const scopeA = `u:${uA}`;
const scopeB = `u:${uB}`;

function projectOp(opId: string, hlc: string, id: string) {
  return {
    opId,
    hlc,
    entity: 'project',
    entityId: id,
    op: 'upsert',
    fields: [
      'id',
      'name',
      'viewMode',
      'kind',
      'isInbox',
      'ownerId',
      'folderId',
      'sortKey',
      'showInSmart',
      'notifyMode',
      'createdAt',
      'updatedAt',
    ],
    row: {
      id,
      name: 'Shared',
      viewMode: 'list',
      kind: 'TASK',
      isInbox: false,
      ownerId: uA,
      folderId: null,
      sortKey: 'a0',
      showInSmart: 'all',
      notifyMode: 'all',
      createdAt: 1000,
      updatedAt: 1000,
    },
  };
}

function taskOp(opId: string, hlc: string, id: string, projectId: string) {
  return {
    opId,
    hlc,
    entity: 'task',
    entityId: id,
    op: 'upsert',
    fields: [
      'id',
      'projectId',
      'title',
      'content',
      'priority',
      'status',
      'sortKey',
      'reminders',
      'tags',
      'createdAt',
      'updatedAt',
    ],
    row: {
      id,
      projectId,
      title: id,
      content: '',
      priority: 0,
      status: 0,
      sortKey: 'a0',
      reminders: [],
      tags: [],
      createdAt: 1000,
      updatedAt: 1000,
    },
  };
}

function deleteProjectOp(opId: string, hlc: string, id: string) {
  return { opId, hlc, entity: 'project', entityId: id, op: 'delete', fields: [], row: {} };
}

async function seedUsers(h: ScopeWorld) {
  await h.db.insert(schema.user).values([
    { id: uA, name: 'Alice', createdAt: 1_700_000_000_000 },
    { id: uB, name: 'Bob', createdAt: 1_700_000_000_000 },
  ]);
}

/** A owns p-1, B joined as editor and wrote a task into p-1 from B's own scope. */
async function sharedListWorld() {
  const h = createScopeWorld();
  await seedUsers(h);
  await h.push(uA, 'dev-a', [
    projectOp('op-p1', '1700000000000:0000:dev-a', 'p-1'),
    taskOp('op-ta', '1700000000001:0000:dev-a', 't-a', 'p-1'),
  ]);
  const inv = await createInvite(h.db, { userId: uA, projectId: 'p-1', role: 'editor' });
  await acceptInvite(h.db, { code: inv.code, userId: uB, getScopeStub: h.getScopeStub });
  const pushB = await h.push(uB, 'dev-b', [taskOp('op-tb', '1700000000002:0000:dev-b', 't-b', 'p-1')]);
  expect(pushB.results[0].status).toBe('applied');
  return h;
}

async function traced(h: ScopeWorld, action: () => Promise<unknown>) {
  h.trace.reset();
  await action();
  return { batches: [...h.trace.batches], direct: h.trace.direct };
}

function failingPurgeOn(h: ScopeWorld, failing: string, isFailing: () => boolean) {
  return (scope: string): ScopeStub => {
    const real = h.getScopeStub(scope);
    if (scope !== failing) return real;
    return {
      push: (i) => real.push(i),
      pull: (i) => real.pull(i),
      getInboxProjectId: (i) => real.getInboxProjectId(i),
      getProjectInfo: (i) => real.getProjectInfo(i),
      projectMember: (i) => real.projectMember(i),
      async purgeProject(i) {
        if (isFailing()) throw new Error('Transient DO timeout');
        return real.purgeProject(i);
      },
    };
  };
}

async function listScopesOf(h: ScopeWorld, projectId: string) {
  const rows = await h.db
    .select({ scope: schema.listScopes.scope })
    .from(schema.listScopes)
    .where(eq(schema.listScopes.projectId, projectId));
  return rows.map((r) => r.scope).sort();
}

describe('membership D1 batch layout', () => {
  it('new list push: context batch, entityHome + owner claim batch, listScopes batch', async () => {
    const h = createScopeWorld();
    await seedUsers(h);
    const trace = await traced(h, () =>
      h.push(uA, 'dev-a', [
        projectOp('op-p1', '1700000000000:0000:dev-a', 'p-1'),
        taskOp('op-t1', '1700000000001:0000:dev-a', 't-1', 'p-1'),
      ]),
    );
    expect(trace).toEqual({ batches: [4, 3, 3], direct: 0 });
    const owners = await h.db
      .select({ userId: schema.projectMembership.userId, role: schema.projectMembership.role })
      .from(schema.projectMembership);
    expect(owners).toEqual([{ userId: uA, role: 'owner' }]);
    expect(await listScopesOf(h, 'p-1')).toEqual([scopeA]);
  });

  it('owner deletes a shared list: purge batch stays atomic, listScopes cleanup is one statement', async () => {
    const h = await sharedListWorld();
    expect(await listScopesOf(h, 'p-1')).toEqual([scopeA, scopeB]);
    const trace = await traced(h, () =>
      h.push(uA, 'dev-a', [deleteProjectOp('op-del', '1700000000010:0000:dev-a', 'p-1')]),
    );
    expect(trace).toEqual({ batches: [4, 3], direct: 1 });
    expect(await listScopesOf(h, 'p-1')).toEqual([]);
  });

  it('pull: membership batch, per-chunk project batch, pending-purge check batch', async () => {
    const h = await sharedListWorld();
    const trace = await traced(h, () => h.pull(uA));
    expect(trace).toEqual({ batches: [2, 4, 1], direct: 0 });
  });

  it('pull retries a failed scope purge and clears the confirmed listScopes row in one batch', async () => {
    const h = await sharedListWorld();
    let failB = true;
    const res = await executeSyncPush(h.db, {
      userId: uA,
      deviceId: 'dev-a',
      ops: [deleteProjectOp('op-del', '1700000000010:0000:dev-a', 'p-1')],
      getScopeStub: failingPurgeOn(h, scopeB, () => failB),
    });
    expect(res.results[0].status).toBe('applied');
    expect(await listScopesOf(h, 'p-1')).toEqual([scopeB]);

    failB = false;
    const trace = await traced(h, () => h.pull(uB));
    expect(trace).toEqual({ batches: [2, 1, 1], direct: 0 });
    expect(await listScopesOf(h, 'p-1')).toEqual([]);
  });

  it('pull retry sends one delete per (project, scope) when two scopes of one list are pending', async () => {
    const h = createScopeWorld();
    const uC = 'user-c';
    const scopeC = `u:${uC}`;
    await seedUsers(h);
    await h.db.insert(schema.user).values({ id: uC, name: 'Cara', createdAt: 1_700_000_000_000 });
    await h.push(uA, 'dev-a', [
      projectOp('op-p1', '1700000000000:0000:dev-a', 'p-1'),
      projectOp('op-p2', '1700000000001:0000:dev-a', 'p-2'),
    ]);
    // B and C join both lists, so A's pull targets scopes B and C through the live list p-2.
    for (const [projectId, userId] of [['p-1', uB], ['p-1', uC], ['p-2', uB], ['p-2', uC]] as const) {
      const inv = await createInvite(h.db, { userId: uA, projectId, role: 'editor' });
      await acceptInvite(h.db, { code: inv.code, userId, getScopeStub: h.getScopeStub });
    }
    // A member's scope joins listScopes once it holds a task of the list.
    let n = 0;
    for (const [projectId, userId] of [['p-1', uB], ['p-1', uC], ['p-2', uB], ['p-2', uC]] as const) {
      const t = `t-${userId}-${projectId}`;
      const pushed = await h.push(userId, `dev-${userId}`, [
        taskOp(`op-${t}`, `170000000010${n++}:0000:dev-${userId}`, t, projectId),
      ]);
      expect(pushed.results[0].status).toBe('applied');
    }
    expect(await listScopesOf(h, 'p-1')).toEqual([scopeA, scopeB, scopeC]);
    let failing = true;
    const flaky = (scope: string): ScopeStub => {
      const real = h.getScopeStub(scope);
      if (scope !== scopeB && scope !== scopeC) return real;
      return {
        push: (i) => real.push(i),
        pull: (i) => real.pull(i),
        getInboxProjectId: (i) => real.getInboxProjectId(i),
        getProjectInfo: (i) => real.getProjectInfo(i),
        projectMember: (i) => real.projectMember(i),
        async purgeProject(i) {
          if (failing) throw new Error('Transient DO timeout');
          return real.purgeProject(i);
        },
      };
    };
    const res = await executeSyncPush(h.db, {
      userId: uA,
      deviceId: 'dev-a',
      ops: [deleteProjectOp('op-del', '1700000000010:0000:dev-a', 'p-1')],
      getScopeStub: flaky,
    });
    expect(res.results[0].status).toBe('applied');
    expect(await listScopesOf(h, 'p-1')).toEqual([scopeB, scopeC]);

    failing = false;
    const trace = await traced(h, () =>
      executeSyncPull(h.db, { userId: uA, cursors: {}, limit: 500, getScopeStub: h.getScopeStub }),
    );
    // The last batch is the retry's cleanup: two statements, not one inArray delete for p-1.
    expect(trace.batches.at(-1)).toBe(2);
    expect(await listScopesOf(h, 'p-1')).toEqual([]);
    expect(await listScopesOf(h, 'p-2')).toContain(scopeB);
  });

  it('createInvite reads requester membership, purge state, and home in one batch', async () => {
    const h = createScopeWorld();
    await seedUsers(h);
    await h.push(uA, 'dev-a', [projectOp('op-p1', '1700000000000:0000:dev-a', 'p-1')]);
    const trace = await traced(h, () =>
      createInvite(h.db, { userId: uA, projectId: 'p-1', role: 'viewer' }),
    );
    expect(trace).toEqual({ batches: [3], direct: 1 });
  });

  it('acceptInvite: one membership upsert, then one read batch for projections', async () => {
    const h = createScopeWorld();
    await seedUsers(h);
    await h.push(uA, 'dev-a', [projectOp('op-p1', '1700000000000:0000:dev-a', 'p-1')]);
    const inv = await createInvite(h.db, { userId: uA, projectId: 'p-1', role: 'editor' });
    const trace = await traced(h, () =>
      acceptInvite(h.db, { code: inv.code, userId: uB, getScopeStub: h.getScopeStub }),
    );
    expect(trace).toEqual({ batches: [3], direct: 1 });
    const rows = await h.db
      .select({ role: schema.projectMembership.role })
      .from(schema.projectMembership)
      .where(
        and(eq(schema.projectMembership.projectId, 'p-1'), eq(schema.projectMembership.userId, uB)),
      );
    expect(rows).toEqual([{ role: 'editor' }]);
  });

  it('updateProjectMemberRole: one five-query access batch, then one update', async () => {
    const h = await sharedListWorld();
    const trace = await traced(h, () =>
      updateProjectMemberRole(h.db, {
        projectId: 'p-1',
        targetUserId: uB,
        requesterUserId: uA,
        role: 'viewer',
        getScopeStub: h.getScopeStub,
      }),
    );
    expect(trace).toEqual({ batches: [5], direct: 1 });
  });

  it('removeProjectMember: one five-query access batch, then one update', async () => {
    const h = await sharedListWorld();
    const trace = await traced(h, () =>
      removeProjectMember(h.db, {
        projectId: 'p-1',
        targetUserId: uB,
        requesterUserId: uA,
        getScopeStub: h.getScopeStub,
      }),
    );
    expect(trace).toEqual({ batches: [5], direct: 1 });
  });

  it('login reads the user row and active memberships in one batch', async () => {
    const h = await sharedListWorld();
    const database = h.db as unknown as DatabaseClient;
    await h.db.insert(schema.identity).values({ provider: 'apple', sub: 'sub-b', userId: uB, email: null });
    const trace = await traced(h, () =>
      createSessionForIdentity(database, {
        provider: 'apple',
        sub: 'sub-b',
        email: null,
        deviceId: 'dev-b2',
        jwtSecret: 'unit-test-jwt-secret-32-bytes-minimum',
        getScopeStub: h.getScopeStub,
      }),
    );
    expect(trace).toEqual({ batches: [2, 2], direct: 1 });
  });
});
