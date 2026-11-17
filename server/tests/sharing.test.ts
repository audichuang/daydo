import { and, eq } from 'drizzle-orm';
import { describe, expect, it } from 'vitest';
import * as schema from '../db/schema';
import { sha256Hex } from '../src/auth/crypto';
import {
  acceptInvite,
  createInvite,
  getInviteInfo,
  INVITE_TTL_MS,
  removeProjectMember,
  revokeInvite,
  SharingError,
  updateProjectMemberRole,
} from '../src/sharing';
import { resolveMemberId } from '../src/sync/entities';
import { executeSyncPush } from '../src/sync/push';
import type { ScopeStub } from '../src/scope/api';
import { createScopeWorld } from './helpers/scopeWorld';

function createHarness() {
  return createScopeWorld();
}

function makeMemberOp(params: {
  opId: string;
  hlc: string;
  id: string;
  name: string;
  initial?: string;
  color?: string;
  isMe?: boolean;
}) {
  return {
    opId: params.opId,
    hlc: params.hlc,
    entity: 'member',
    entityId: params.id,
    op: 'upsert',
    fields: ['id', 'name', 'initial', 'color', 'isMe', 'createdAt', 'updatedAt'],
    row: {
      id: params.id,
      name: params.name,
      initial: params.initial ?? params.name.slice(0, 1).toUpperCase(),
      color: params.color ?? '#007AFF',
      isMe: params.isMe ?? true,
      createdAt: 1000,
      updatedAt: 1000,
    },
  };
}

function makeProjectOp(params: {
  opId: string;
  hlc: string;
  id: string;
  name?: string;
  folderId?: string | null;
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
      'folderId',
      'sortKey',
      'showInSmart',
      'notifyMode',
      'createdAt',
      'updatedAt',
    ],
    row: {
      id: params.id,
      name: params.name ?? 'Shared List',
      viewMode: 'list',
      kind: 'TASK',
      isInbox: false,
      ownerId: 'u-a',
      folderId: params.folderId ?? null,
      sortKey: 'a0',
      showInSmart: 'all',
      notifyMode: 'all',
      createdAt: 1000,
      updatedAt: 1000,
    },
  };
}

function makeTaskOp(params: {
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
      'sortKey',
      'reminders',
      'tags',
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
      sortKey: 'a0',
      reminders: [],
      tags: [],
      createdAt: 1000,
      updatedAt: 1000,
    },
  };
}

function makeChecklistOp(params: {
  opId: string;
  hlc: string;
  id: string;
  taskId: string;
  title?: string;
}) {
  return {
    opId: params.opId,
    hlc: params.hlc,
    entity: 'checklistItem',
    entityId: params.id,
    op: 'upsert',
    fields: ['id', 'taskId', 'title', 'status', 'sortKey', 'createdAt', 'updatedAt'],
    row: {
      id: params.id,
      taskId: params.taskId,
      title: params.title ?? 'Subitem',
      status: 0,
      sortKey: 'a0',
      createdAt: 1000,
      updatedAt: 1000,
    },
  };
}

async function seedUsers(
  h: ReturnType<typeof createHarness>,
  users: Array<{ id: string; name?: string; initial?: string; color?: string; avatarUrl?: string | null }>,
) {
  await h.db.insert(schema.user).values(
    users.map((u) => ({
      id: u.id,
      name: u.name ?? null,
      initial: u.initial ?? null,
      color: u.color ?? null,
      avatarUrl: u.avatarUrl ?? null,
      createdAt: 1_700_000_000_000,
    })),
  );
}

describe('T5c sharing — invites, membership, permissions, backfill, and purge', () => {
  it('hashes invite codes with sha256, enforces owner-only create/revoke, expiry, reuse, and no owner downgrade', async () => {
    const h = createHarness();
    const uA = 'user-a';
    const uB = 'user-b';
    const uC = 'user-c';
    await seedUsers(h, [
      { id: uA, name: 'Alice', initial: 'A', color: '#FF0000' },
      { id: uB, name: 'Bob', initial: 'B', color: '#00FF00' },
      { id: uC, name: 'Carol', initial: 'C', color: '#0000FF' },
    ]);
    await h.push(uA, 'dev-a', [
      makeProjectOp({ opId: 'op-p1', hlc: '1700000000000:0000:dev-a', id: 'p-1', name: 'Family' }),
    ]);

    const now = 1_700_000_100_000;
    const created = await createInvite(h.db, {
      userId: uA,
      projectId: 'p-1',
      role: 'editor',
      email: 'bob@example.com',
      nowMs: now,
    });
    expect(created.url).toBe(`daydo://invite/${created.code}`);
    expect(created.expiresAt).toBe(now + INVITE_TTL_MS);
    const decoded = Buffer.from(
      created.code.replace(/-/g, '+').replace(/_/g, '/'),
      'base64',
    );
    expect(decoded.byteLength).toBe(16);

    // D1 stores only the SHA-256 hash, never the raw code.
    const storedRows = await h.db.select().from(schema.invite);
    expect(storedRows).toHaveLength(1);
    const expectedHash = await sha256Hex(created.code);
    expect(storedRows[0].codeHash).toBe(expectedHash);
    expect(storedRows[0].codeHash).not.toBe(created.code);
    expect(storedRows[0].email).toBe('bob@example.com');

    // Non-owner cannot create an invite.
    await expect(
      createInvite(h.db, { userId: uB, projectId: 'p-1', role: 'viewer', nowMs: now }),
    ).rejects.toMatchObject({ status: 403 });

    // Any logged-in user can inspect invite info.
    const info = await getInviteInfo(h.db, {
      code: created.code,
      getScopeStub: h.getScopeStub,
      nowMs: now + 1000,
    });
    expect(info).toEqual({
      projectName: 'Family',
      inviterName: 'Alice',
      role: 'editor',
      expiresAt: now + INVITE_TTL_MS,
    });

    // Unknown or expired invite returns 404.
    await expect(
      getInviteInfo(h.db, { code: 'nonexistent', getScopeStub: h.getScopeStub, nowMs: now }),
    ).rejects.toMatchObject({ status: 404 });
    await expect(
      getInviteInfo(h.db, {
        code: created.code,
        getScopeStub: h.getScopeStub,
        nowMs: now + INVITE_TTL_MS,
      }),
    ).rejects.toMatchObject({ status: 404 });
    await expect(
      acceptInvite(h.db, {
        code: created.code,
        userId: uB,
        getScopeStub: h.getScopeStub,
        nowMs: now + INVITE_TTL_MS,
      }),
    ).rejects.toMatchObject({ status: 404 });

    // B and C both accept the same reusable invite.
    const accB1 = await acceptInvite(h.db, {
      code: created.code,
      userId: uB,
      getScopeStub: h.getScopeStub,
      nowMs: now + 2000,
    });
    expect(accB1).toEqual({ projectId: 'p-1', scope: `u:${uA}`, role: 'editor' });

    // Re-accepting is idempotent.
    const accB2 = await acceptInvite(h.db, {
      code: created.code,
      userId: uB,
      getScopeStub: h.getScopeStub,
      nowMs: now + 3000,
    });
    expect(accB2).toEqual({ projectId: 'p-1', scope: `u:${uA}`, role: 'editor' });

    const accC = await acceptInvite(h.db, {
      code: created.code,
      userId: uC,
      getScopeStub: h.getScopeStub,
      nowMs: now + 4000,
    });
    expect(accC).toEqual({ projectId: 'p-1', scope: `u:${uA}`, role: 'editor' });

    // Owner accepting their own invite is never downgraded.
    const accA = await acceptInvite(h.db, {
      code: created.code,
      userId: uA,
      getScopeStub: h.getScopeStub,
      nowMs: now + 5000,
    });
    expect(accA).toEqual({ projectId: 'p-1', scope: `u:${uA}`, role: 'owner' });

    // Editor cannot revoke invite; owner can revoke.
    await expect(
      revokeInvite(h.db, { code: created.code, userId: uB, nowMs: now + 6000 }),
    ).rejects.toMatchObject({ status: 403 });

    const rev = await revokeInvite(h.db, {
      code: created.code,
      userId: uA,
      nowMs: now + 6000,
    });
    expect(rev).toEqual({ revoked: true });

    await expect(
      getInviteInfo(h.db, { code: created.code, getScopeStub: h.getScopeStub, nowMs: now + 7000 }),
    ).rejects.toMatchObject({ status: 404 });
    await expect(
      acceptInvite(h.db, {
        code: created.code,
        userId: 'user-d',
        getScopeStub: h.getScopeStub,
        nowMs: now + 7000,
      }),
    ).rejects.toMatchObject({ status: 404 });
  });

  it('enforces membership rules (owner-only updates, leave, owner cannot leave) and reconciles failed DO projections on pull', async () => {
    const h = createHarness();
    const uA = 'user-a';
    const uB = 'user-b';
    await seedUsers(h, [
      { id: uA, avatarUrl: 'https://lh3.googleusercontent.com/a/alice' },
      { id: uB },
    ]);
    await h.push(uA, 'dev-a', [
      makeProjectOp({ opId: 'op-p1', hlc: '1700000000000:0000:dev-a', id: 'p-1', name: 'Groceries' }),
    ]);

    const inv = await createInvite(h.db, {
      userId: uA,
      projectId: 'p-1',
      role: 'editor',
      nowMs: 1_700_000_000_000,
    });

    // Inject transient projection failure during acceptInvite: D1 succeeds, DO projection missed.
    const failingGetScope = (): Pick<ScopeStub, 'projectMember'> => ({
      async projectMember() {
        throw new Error('DO temporarily unreachable');
      },
    });
    const accepted = await acceptInvite(h.db, {
      code: inv.code,
      userId: uB,
      getScopeStub: failingGetScope,
      nowMs: 1_700_000_001_000,
    });
    expect(accepted.role).toBe('editor');

    // Before pull, A's DO has no projectMember row for B.
    const prePullA = await h.pull(uA);
    const scopeA = prePullA.scopes.find((s) => s.scope === `u:${uA}`)!;
    const projectedRow = scopeA.rows.find(
      (r) =>
        r.entity === 'projectMember' &&
        'row' in r &&
        r.row.memberId === resolveMemberId(uB, null),
    );
    expect(projectedRow).toMatchObject({
      entity: 'projectMember',
      row: {
        projectId: 'p-1',
        memberId: resolveMemberId(uB, null),
        role: 'editor',
      },
    });
    expect((projectedRow as unknown as { row: { deletedAt?: number } }).row.deletedAt).toBeUndefined();

    // Owner changes B to viewer; non-owner cannot update roles; owner's role cannot be changed.
    await expect(
      updateProjectMemberRole(h.db, {
        projectId: 'p-1',
        targetUserId: uB,
        requesterUserId: uB,
        role: 'editor',
        getScopeStub: h.getScopeStub,
      }),
    ).rejects.toBeInstanceOf(SharingError);

    await expect(
      updateProjectMemberRole(h.db, {
        projectId: 'p-1',
        targetUserId: uA,
        requesterUserId: uA,
        role: 'viewer',
        getScopeStub: h.getScopeStub,
      }),
    ).rejects.toMatchObject({ status: 400 });

    await updateProjectMemberRole(h.db, {
      projectId: 'p-1',
      targetUserId: uB,
      requesterUserId: uA,
      role: 'viewer',
      getScopeStub: h.getScopeStub,
      nowMs: 1_700_000_002_000,
    });

    // Owner cannot leave.
    await expect(
      removeProjectMember(h.db, {
        projectId: 'p-1',
        targetUserId: uA,
        requesterUserId: uA,
        getScopeStub: h.getScopeStub,
      }),
    ).rejects.toMatchObject({ status: 400 });

    // B leaves themselves with a failing DO projection call -> healed on A's next pull!
    const leaveRes = await removeProjectMember(h.db, {
      projectId: 'p-1',
      targetUserId: uB,
      requesterUserId: uB,
      getScopeStub: failingGetScope,
      nowMs: 1_700_000_003_000,
    });
    expect(leaveRes).toEqual({ projectId: 'p-1', userId: uB, removed: true });

    // Idempotent second removal does not fail.
    await expect(
      removeProjectMember(h.db, {
        projectId: 'p-1',
        targetUserId: uB,
        requesterUserId: uA,
        getScopeStub: h.getScopeStub,
      }),
    ).resolves.toEqual({ projectId: 'p-1', userId: uB, removed: true });

    // Next pull from A reconciles the missed soft-delete in DO.
    const afterLeaveA = await h.pull(uA, { cursors: { [`u:${uA}`]: scopeA.cursor } });
    const scopeA2 = afterLeaveA.scopes.find((s) => s.scope === `u:${uA}`)!;
    const reconciled = scopeA2.rows.find((r) => r.entity === 'projectMember');
    expect(reconciled).toMatchObject({
      entity: 'projectMember',
      row: {
        projectId: 'p-1',
        memberId: resolveMemberId(uB, null),
      },
    });
    expect((reconciled as unknown as { row: { deletedAt: number | null } }).row.deletedAt).toEqual(
      expect.any(Number),
    );
  });

  it('rejects viewer writes with current row, hides/ignores folderId for non-creators, syncs user profile into members, and supports paged backfill', async () => {
    const h = createHarness();
    const uA = 'user-a';
    const uB = 'user-b';
    await seedUsers(h, [
      { id: uA, avatarUrl: 'https://lh3.googleusercontent.com/a/alice' },
      { id: uB },
    ]);

    // A pushes meMemberId + name/initial/color, folder-a, project p-1, and 2 tasks.
    await h.push(uA, 'dev-a', [
      makeMemberOp({
        opId: 'op-ma',
        hlc: '1700000000000:0000:dev-a',
        id: 'mem-a',
        name: 'Alice Chen',
        initial: 'AC',
        color: '#AA1122',
      }),
      {
        opId: 'op-fa',
        hlc: '1700000000001:0000:dev-a',
        entity: 'folder',
        entityId: 'folder-a',
        op: 'upsert',
        fields: ['id', 'name', 'sortKey', 'createdAt', 'updatedAt'],
        row: { id: 'folder-a', name: 'Personal', sortKey: 'a0', createdAt: 1000, updatedAt: 1000 },
      },
      makeProjectOp({
        opId: 'op-p1',
        hlc: '1700000000002:0000:dev-a',
        id: 'p-1',
        name: 'Shared Trips',
        folderId: 'folder-a',
      }),
      makeTaskOp({
        opId: 'op-t1',
        hlc: '1700000000003:0000:dev-a',
        id: 't-1',
        projectId: 'p-1',
        title: 'Book flights',
      }),
    ]);

    const inv = await createInvite(h.db, { userId: uA, projectId: 'p-1', role: 'editor' });
    await acceptInvite(h.db, { code: inv.code, userId: uB, getScopeStub: h.getScopeStub });

    // Backfill p-1 for B across multiple pages (limit = 1).
    const p1Page1 = await h.pull(uB, { backfill: ['p-1'], limit: 1 });
    expect(p1Page1.memberships).toEqual([{ projectId: 'p-1', scope: `u:${uA}`, role: 'editor' }]);
    expect(p1Page1.members).toEqual([
      expect.objectContaining({
        id: 'mem-a',
        userId: uA,
        name: 'Alice Chen',
        initial: 'AC',
        color: '#AA1122',
        avatarUrl: 'https://lh3.googleusercontent.com/a/alice',
        isMe: false,
      }),
    ]);
    const collected = [...p1Page1.scopes[0].rows];
    let cursor = p1Page1.scopes[0].cursor;
    let hasMore = p1Page1.scopes[0].hasMore;
    while (hasMore) {
      const nextPage = await h.pull(uB, {
        backfill: ['p-1'],
        cursors: { [`u:${uA}`]: cursor },
        limit: 1,
      });
      collected.push(...nextPage.scopes[0].rows);
      cursor = nextPage.scopes[0].cursor;
      hasMore = nextPage.scopes[0].hasMore;
    }

    // Non-creator pull omits project.folderId.
    const pulledProjB = collected.find((r) => r.entity === 'project') as {
      row: Record<string, unknown>;
    };
    expect(Object.hasOwn(pulledProjB.row, 'folderId')).toBe(false);
    expect(pulledProjB.row.name).toBe('Shared Trips');

    // Creator pull still includes project.folderId, includes co-member userId in members,
    // and keeps userId off ordinary scope member rows.
    const pullA = await h.pull(uA);
    expect(pullA.members).toEqual([
      expect.objectContaining({
        id: resolveMemberId(uB, null),
        userId: uB,
        avatarUrl: null,
        isMe: false,
      }),
    ]);
    const pulledMemberA = pullA.scopes
      .find((s) => s.scope === `u:${uA}`)!
      .rows.find((r) => r.entity === 'member') as { row: Record<string, unknown> };
    expect(Object.hasOwn(pulledMemberA.row, 'userId')).toBe(false);
    const pulledProjA = pullA.scopes
      .find((s) => s.scope === `u:${uA}`)!
      .rows.find((r) => r.entity === 'project') as { row: Record<string, unknown> };
    expect(pulledProjA.row.folderId).toBe('folder-a');

    // Non-creator editor pushes folderId + name change -> folderId ignored, name applied!
    const edProjRes = await h.push(uB, 'dev-b', [
      {
        opId: 'op-b-proj-edit',
        hlc: '1700000000010:0000:dev-b',
        entity: 'project',
        entityId: 'p-1',
        op: 'upsert',
        fields: ['name', 'folderId'],
        row: { id: 'p-1', name: 'Family Trips', folderId: 'folder-b' },
      },
    ]);
    expect(edProjRes.results[0].status).toBe('applied');
    expect(edProjRes.results[0].row?.name).toBe('Family Trips');
    expect(Object.hasOwn(edProjRes.results[0].row!, 'folderId')).toBe(false);

    // Creator still has original folderId untouched.
    const pullA2 = await h.pull(uA, { cursors: { [`u:${uA}`]: pullA.scopes[0].cursor } });
    const pulledProjA2 = pullA2.scopes[0].rows.find((r) => r.entity === 'project') as {
      row: Record<string, unknown>;
    };
    expect(pulledProjA2.row.name).toBe('Family Trips');
    expect(pulledProjA2.row.folderId).toBe('folder-a');

    // Demote B to viewer and verify edits are rejected with current row.
    await updateProjectMemberRole(h.db, {
      projectId: 'p-1',
      targetUserId: uB,
      requesterUserId: uA,
      role: 'viewer',
      getScopeStub: h.getScopeStub,
    });

    const viewerEdit = await h.push(uB, 'dev-b', [
      {
        opId: 'op-b-viewer-task',
        hlc: '1700000000020:0000:dev-b',
        entity: 'task',
        entityId: 't-1',
        op: 'upsert',
        fields: ['title'],
        row: { id: 't-1', title: 'Hijacked' },
      },
      makeTaskOp({
        opId: 'op-b-viewer-newtask',
        hlc: '1700000000021:0000:dev-b',
        id: 't-viewer-new',
        projectId: 'p-1',
        title: 'Should Fail',
      }),
    ]);
    expect(viewerEdit.results[0]).toMatchObject({
      status: 'rejected',
      reason: 'Forbidden',
      row: { id: 't-1', title: 'Book flights' },
    });
    expect(viewerEdit.results[0].clocks.title).toBeDefined();
    expect(viewerEdit.results[1]).toMatchObject({
      status: 'rejected',
      reason: 'Forbidden',
      row: null,
    });
  });

  it('purges shared list across all listed scopes and retries failed scope purges on next pull', async () => {
    const h = createHarness();
    const uA = 'user-a';
    const uB = 'user-b';
    await seedUsers(h, [
      { id: uA, avatarUrl: 'https://lh3.googleusercontent.com/a/alice' },
      { id: uB },
    ]);

    await h.push(uA, 'dev-a', [
      makeProjectOp({ opId: 'op-p1', hlc: '1700000000000:0000:dev-a', id: 'p-1', name: 'To Purge' }),
      makeTaskOp({
        opId: 'op-t-a',
        hlc: '1700000000001:0000:dev-a',
        id: 't-a',
        projectId: 'p-1',
        title: 'Task A',
      }),
    ]);

    const inv = await createInvite(h.db, { userId: uA, projectId: 'p-1', role: 'editor' });
    await acceptInvite(h.db, { code: inv.code, userId: uB, getScopeStub: h.getScopeStub });

    // B creates a task + child in p-1 (lives in B's scope).
    await h.push(uB, 'dev-b', [
      makeTaskOp({
        opId: 'op-t-b',
        hlc: '1700000000002:0000:dev-b',
        id: 't-b',
        projectId: 'p-1',
        title: 'Task B',
      }),
      makeChecklistOp({
        opId: 'op-c-b',
        hlc: '1700000000003:0000:dev-b',
        id: 'c-b',
        taskId: 't-b',
        title: 'Item B',
      }),
    ]);

    // Simulate transient failure on B's scope during owner project delete.
    let failB = true;
    const flakyGetScope = (scope: string): ScopeStub => {
      const real = h.getScopeStub(scope);
      if (scope !== `u:${uB}`) return real;
      return {
        push: (i) => real.push(i),
        pull: (i) => real.pull(i),
        getInboxProjectId: (i) => real.getInboxProjectId(i),
        getProjectInfo: (i) => real.getProjectInfo(i),
        getAttachmentInfo: (i) => real.getAttachmentInfo(i),
        projectMember: (i) => real.projectMember(i),
        async purgeProject(i) {
          if (failB) {
            throw new Error('Transient DO timeout on B');
          }
          return real.purgeProject(i);
        },
      };
    };

    const delRes = await executeSyncPush(h.db, {
      userId: uA,
      deviceId: 'dev-a',
      getScopeStub: flakyGetScope,
      ops: [
        {
          opId: 'op-p-del',
          hlc: '1700000000010:0000:dev-a',
          entity: 'project',
          entityId: 'p-1',
          op: 'delete',
          fields: [],
          row: {},
        },
      ],
    });
    expect(delRes.results[0].status).toBe('applied');

    // A's scope was removed from listScopes, while B's scope remains pending purge in D1.
    const remainingScopes = await h.db
      .select()
      .from(schema.listScopes)
      .where(eq(schema.listScopes.projectId, 'p-1'));
    expect(remainingScopes.map((r) => r.scope)).toEqual([`u:${uB}`]);

    // Now B recovers and pulls -> pull retries purgeProject on B's scope and cleans up listScopes!
    failB = false;
    const pullB = await h.pull(uB);
    expect(pullB.memberships).toEqual([]);

    const afterRetryScopes = await h.db
      .select()
      .from(schema.listScopes)
      .where(and(eq(schema.listScopes.projectId, 'p-1'), eq(schema.listScopes.scope, `u:${uB}`)));
    expect(afterRetryScopes).toEqual([]);

    // Later writes targeting p-1 are rejected.
    const writeAfterPurge = await h.push(uB, 'dev-b', [
      makeTaskOp({
        opId: 'op-t-late',
        hlc: '1700000000020:0000:dev-b',
        id: 't-late',
        projectId: 'p-1',
        title: 'Late Task',
      }),
    ]);
    expect(writeAfterPurge.results[0]).toMatchObject({
      status: 'rejected',
      reason: 'Project is purged',
    });
  });

  it('executes earlier move ops before permanent-delete purge in the same batch and preserves order for later ops', async () => {
    const h = createHarness();
    const uA = 'user-a';
    await seedUsers(h, [{ id: uA }]);

    const setup = await h.push(uA, 'dev-a', [
      makeProjectOp({ opId: 'op-p1', hlc: '1700000000000:0000:dev-a', id: 'p-1', name: 'Old' }),
      makeProjectOp({ opId: 'op-p2', hlc: '1700000000001:0000:dev-a', id: 'p-2', name: 'Keep' }),
      makeProjectOp({ opId: 'op-p3', hlc: '1700000000002:0000:dev-a', id: 'p-3', name: 'Other' }),
      makeTaskOp({
        opId: 'op-t1',
        hlc: '1700000000003:0000:dev-a',
        id: 't-1',
        projectId: 'p-1',
        title: 'Saved Task',
      }),
    ]);
    expect(setup.results.every((r) => r.status === 'applied')).toBe(true);

    // Batch: [move t-1 to p-2, delete p-1] -> move must run before p-1 is purged.
    const moveThenDelete = await h.push(uA, 'dev-a', [
      {
        opId: 'op-move-t1',
        hlc: '1700000000010:0000:dev-a',
        entity: 'task',
        entityId: 't-1',
        op: 'upsert',
        fields: ['projectId', 'updatedAt'],
        row: { id: 't-1', projectId: 'p-2', updatedAt: 2000 },
      },
      {
        opId: 'op-del-p1',
        hlc: '1700000000011:0000:dev-a',
        entity: 'project',
        entityId: 'p-1',
        op: 'delete',
        fields: [],
        row: {},
      },
    ]);
    expect(moveThenDelete.results[0]).toMatchObject({
      status: 'applied',
      row: { id: 't-1', projectId: 'p-2' },
    });
    expect(moveThenDelete.results[0].row?.purgedAt).toBeUndefined();
    expect(moveThenDelete.results[1].status).toBe('applied');
    expect(moveThenDelete.results[1].row?.purgedAt).toEqual(expect.any(Number));

    // Confirm t-1 survived in p-2 after p-1 purge.
    const afterPull = await h.pull(uA);
    const scopeARows = afterPull.scopes.find((s) => s.scope === `u:${uA}`)!.rows;
    const taskRow = scopeARows.find(
      (r) => r.entity === 'task' && 'row' in r && r.row.id === 't-1',
    ) as { row: Record<string, unknown> } | undefined;
    expect(taskRow?.row.projectId).toBe('p-2');
    expect(taskRow?.row.purgedAt).toBeUndefined();

    // Reverse order in same batch: [delete p-2, move t-1 (in p-2) to p-3] -> delete runs first, move is rejected.
    const deleteThenMove = await h.push(uA, 'dev-a', [
      {
        opId: 'op-del-p2',
        hlc: '1700000000020:0000:dev-a',
        entity: 'project',
        entityId: 'p-2',
        op: 'delete',
        fields: [],
        row: {},
      },
      {
        opId: 'op-move-t1-late',
        hlc: '1700000000021:0000:dev-a',
        entity: 'task',
        entityId: 't-1',
        op: 'upsert',
        fields: ['projectId', 'updatedAt'],
        row: { id: 't-1', projectId: 'p-3', updatedAt: 3000 },
      },
    ]);
    expect(deleteThenMove.results[0].status).toBe('applied');
    expect(deleteThenMove.results[1]).toMatchObject({
      status: 'rejected',
      reason: 'Project is purged',
    });
  });

  it('keeps existing active role when re-accepting an invite or accepting a different-role invite link', async () => {
    const h = createHarness();
    const uA = 'user-a';
    const uB = 'user-b';
    const uC = 'user-c';
    await seedUsers(h, [{ id: uA }, { id: uB }, { id: uC }]);

    await h.push(uA, 'dev-a', [
      makeProjectOp({ opId: 'op-p1', hlc: '1700000000000:0000:dev-a', id: 'p-1', name: 'Family' }),
    ]);

    const editorInv = await createInvite(h.db, {
      userId: uA,
      projectId: 'p-1',
      role: 'editor',
      nowMs: 1_700_000_000_000,
    });
    const viewerInv = await createInvite(h.db, {
      userId: uA,
      projectId: 'p-1',
      role: 'viewer',
      nowMs: 1_700_000_000_100,
    });

    // B accepts editor invite, then owner downgrades B to viewer.
    await acceptInvite(h.db, {
      code: editorInv.code,
      userId: uB,
      getScopeStub: h.getScopeStub,
      nowMs: 1_700_000_001_000,
    });
    await updateProjectMemberRole(h.db, {
      projectId: 'p-1',
      targetUserId: uB,
      requesterUserId: uA,
      role: 'viewer',
      getScopeStub: h.getScopeStub,
      nowMs: 1_700_000_002_000,
    });

    // Re-accepting the same editor invite must NOT promote B back to editor.
    const reAcceptB = await acceptInvite(h.db, {
      code: editorInv.code,
      userId: uB,
      getScopeStub: h.getScopeStub,
      nowMs: 1_700_000_003_000,
    });
    expect(reAcceptB.role).toBe('viewer');

    // C accepts editor invite, then accepts a viewer invite -> must stay editor.
    await acceptInvite(h.db, {
      code: editorInv.code,
      userId: uC,
      getScopeStub: h.getScopeStub,
      nowMs: 1_700_000_004_000,
    });
    const acceptViewerLinkC = await acceptInvite(h.db, {
      code: viewerInv.code,
      userId: uC,
      getScopeStub: h.getScopeStub,
      nowMs: 1_700_000_005_000,
    });
    expect(acceptViewerLinkC.role).toBe('editor');

    // Verify D1 memberships remain viewer for B and editor for C.
    const d1Rows = await h.db
      .select({ userId: schema.projectMembership.userId, role: schema.projectMembership.role })
      .from(schema.projectMembership)
      .where(eq(schema.projectMembership.projectId, 'p-1'));
    expect(Object.fromEntries(d1Rows.map((r) => [r.userId, r.role]))).toEqual({
      [uA]: 'owner',
      [uB]: 'viewer',
      [uC]: 'editor',
    });

    // After B is removed (removedAt != NULL), an invite created before removal fails (404),
    // while a new invite created after removal grants the new invite's role (editor).
    await removeProjectMember(h.db, {
      projectId: 'p-1',
      targetUserId: uB,
      requesterUserId: uA,
      getScopeStub: h.getScopeStub,
      nowMs: 1_700_000_006_000,
    });
    await expect(
      acceptInvite(h.db, {
        code: editorInv.code,
        userId: uB,
        getScopeStub: h.getScopeStub,
        nowMs: 1_700_000_007_000,
      }),
    ).rejects.toMatchObject({ status: 404, message: 'Invite not found' });

    const newEditorInv = await createInvite(h.db, {
      userId: uA,
      projectId: 'p-1',
      role: 'editor',
      nowMs: 1_700_000_007_000,
    });
    const rejoinB = await acceptInvite(h.db, {
      code: newEditorInv.code,
      userId: uB,
      getScopeStub: h.getScopeStub,
      nowMs: 1_700_000_008_000,
    });
    expect(rejoinB.role).toBe('editor');
  });

  it('blocks removed or departed members from rejoining via invites created before or at removal, while allowing new invites', async () => {
    const h = createHarness();
    const uA = 'user-a';
    const uB = 'user-b';
    const uC = 'user-c';
    await seedUsers(h, [{ id: uA }, { id: uB }, { id: uC }]);

    await h.push(uA, 'dev-a', [
      makeProjectOp({ opId: 'op-p1', hlc: '1700000000000:0000:dev-a', id: 'p-1', name: 'Shared' }),
    ]);

    const oldInv = await createInvite(h.db, {
      userId: uA,
      projectId: 'p-1',
      role: 'editor',
      nowMs: 1_700_000_000_000,
    });
    const sameMsInv = await createInvite(h.db, {
      userId: uA,
      projectId: 'p-1',
      role: 'editor',
      nowMs: 1_700_000_005_000,
    });

    await acceptInvite(h.db, {
      code: oldInv.code,
      userId: uB,
      getScopeStub: h.getScopeStub,
      nowMs: 1_700_000_001_000,
    });
    await acceptInvite(h.db, {
      code: oldInv.code,
      userId: uC,
      getScopeStub: h.getScopeStub,
      nowMs: 1_700_000_001_500,
    });

    // Owner removes B at 1_700_000_005_000; C leaves at 1_700_000_006_000.
    await removeProjectMember(h.db, {
      projectId: 'p-1',
      targetUserId: uB,
      requesterUserId: uA,
      getScopeStub: h.getScopeStub,
      nowMs: 1_700_000_005_000,
    });
    await removeProjectMember(h.db, {
      projectId: 'p-1',
      targetUserId: uC,
      requesterUserId: uC,
      getScopeStub: h.getScopeStub,
      nowMs: 1_700_000_006_000,
    });

    // B cannot rejoin with oldInv (createdAt < removedAt) or sameMsInv (createdAt === removedAt).
    await expect(
      acceptInvite(h.db, {
        code: oldInv.code,
        userId: uB,
        getScopeStub: h.getScopeStub,
        nowMs: 1_700_000_007_000,
      }),
    ).rejects.toMatchObject({ status: 404, message: 'Invite not found' });
    await expect(
      acceptInvite(h.db, {
        code: sameMsInv.code,
        userId: uB,
        getScopeStub: h.getScopeStub,
        nowMs: 1_700_000_007_100,
      }),
    ).rejects.toMatchObject({ status: 404, message: 'Invite not found' });

    // C (who left) cannot rejoin with oldInv either.
    await expect(
      acceptInvite(h.db, {
        code: oldInv.code,
        userId: uC,
        getScopeStub: h.getScopeStub,
        nowMs: 1_700_000_007_200,
      }),
    ).rejects.toMatchObject({ status: 404, message: 'Invite not found' });

    // Verify B and C remain removed in D1.
    const removedRows = await h.db
      .select({
        userId: schema.projectMembership.userId,
        removedAt: schema.projectMembership.removedAt,
      })
      .from(schema.projectMembership)
      .where(eq(schema.projectMembership.projectId, 'p-1'));
    expect(Object.fromEntries(removedRows.map((r) => [r.userId, r.removedAt]))).toEqual({
      [uA]: null,
      [uB]: 1_700_000_005_000,
      [uC]: 1_700_000_006_000,
    });

    // A new invite created after removal works normally.
    const freshInv = await createInvite(h.db, {
      userId: uA,
      projectId: 'p-1',
      role: 'viewer',
      nowMs: 1_700_000_008_000,
    });
    const rejoinedB = await acceptInvite(h.db, {
      code: freshInv.code,
      userId: uB,
      getScopeStub: h.getScopeStub,
      nowMs: 1_700_000_009_000,
    });
    expect(rejoinedB).toEqual({ projectId: 'p-1', scope: `u:${uA}`, role: 'viewer' });
  });

  it('projects and reconciles owner projectMember on acceptInvite and new-device backfill for both A and B', async () => {
    const h = createHarness();
    const uA = 'user-a';
    const uB = 'user-b';
    await seedUsers(h, [
      { id: uA, avatarUrl: 'https://lh3.googleusercontent.com/a/alice' },
      { id: uB },
    ]);

    // A pushes meMemberId, shared project p-1, private project p-2, and an App-sent projectMember (rejected).
    const pushA = await h.push(uA, 'dev-a', [
      makeMemberOp({ opId: 'op-ma', hlc: '1700000000000:0000:dev-a', id: 'mem-a', name: 'Alice' }),
      makeProjectOp({ opId: 'op-p1', hlc: '1700000000001:0000:dev-a', id: 'p-1', name: 'Shared' }),
      makeProjectOp({ opId: 'op-p2', hlc: '1700000000002:0000:dev-a', id: 'p-2', name: 'Private' }),
      {
        opId: 'op-pm-app',
        hlc: '1700000000003:0000:dev-a',
        entity: 'projectMember',
        entityId: 'p-1:mem-a',
        op: 'upsert',
        fields: ['projectId', 'memberId', 'role', 'createdAt', 'updatedAt'],
        row: {
          projectId: 'p-1',
          memberId: 'mem-a',
          role: 'owner',
          createdAt: 1000,
          updatedAt: 1000,
        },
      },
    ]);
    expect(pushA.results[0].status).toBe('applied');
    expect(pushA.results[1].status).toBe('applied');
    expect(pushA.results[2].status).toBe('applied');
    expect(pushA.results[3].status).toBe('rejected');

    await h.push(uB, 'dev-b', [
      makeMemberOp({ opId: 'op-mb', hlc: '1700000000004:0000:dev-b', id: 'mem-b', name: 'Bob' }),
    ]);

    const inv = await createInvite(h.db, {
      userId: uA,
      projectId: 'p-1',
      role: 'editor',
      nowMs: 1_700_000_010_000,
    });
    await acceptInvite(h.db, {
      code: inv.code,
      userId: uB,
      getScopeStub: h.getScopeStub,
      nowMs: 1_700_000_011_000,
    });

    // acceptInvite itself must have projected BOTH owner (mem-a) and editor (mem-b) into A's DO.
    const directScopePull = await h.getScopeStub(`u:${uA}`).pull({
      scope: `u:${uA}`,
      scopeUserId: uA,
      requesterUserId: uB,
      since: 0,
      limit: 100,
      memberships: { 'p-1': 'editor' },
      backfillProjectIds: ['p-1'],
      meMemberId: null,
    });
    const directMembers = directScopePull.rows
      .filter((r) => r.entity === 'projectMember' && 'row' in r)
      .map((r) => (r as { row: Record<string, unknown> }).row);
    expect(directMembers).toEqual(
      expect.arrayContaining([
        expect.objectContaining({ projectId: 'p-1', memberId: 'mem-a', role: 'owner' }),
        expect.objectContaining({ projectId: 'p-1', memberId: 'mem-b', role: 'editor' }),
      ]),
    );

    // New-device backfill of p-1 for B returns owner (mem-a) and editor (mem-b).
    const backfillB = await h.pull(uB, { backfill: ['p-1'] });
    const membersB = backfillB.scopes
      .find((s) => s.scope === `u:${uA}`)!
      .rows.filter((r) => r.entity === 'projectMember' && 'row' in r)
      .map((r) => (r as { row: Record<string, unknown> }).row);
    expect(membersB).toEqual(
      expect.arrayContaining([
        expect.objectContaining({ projectId: 'p-1', memberId: 'mem-a', role: 'owner' }),
        expect.objectContaining({ projectId: 'p-1', memberId: 'mem-b', role: 'editor' }),
      ]),
    );

    // New-device backfill of p-1 (shared) and p-2 (unshared) for A returns owner row too via reconcile.
    const backfillA = await h.pull(uA, { backfill: ['p-1', 'p-2'] });
    const membersA = backfillA.scopes
      .find((s) => s.scope === `u:${uA}`)!
      .rows.filter((r) => r.entity === 'projectMember' && 'row' in r)
      .map((r) => (r as { row: Record<string, unknown> }).row);
    expect(membersA).toEqual(
      expect.arrayContaining([
        expect.objectContaining({ projectId: 'p-1', memberId: 'mem-a', role: 'owner' }),
        expect.objectContaining({ projectId: 'p-1', memberId: 'mem-b', role: 'editor' }),
        expect.objectContaining({ projectId: 'p-2', memberId: 'mem-a', role: 'owner' }),
      ]),
    );
  });
});
