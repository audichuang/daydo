import { entityHome, listScopes, projectMembership, purgedProject, user } from '@schema';
import { and, eq, inArray, isNull, type BatchItem } from 'void/db';
import type { ExpectedProjectMember, ScopePullResponse } from '../../durable-objects/scope';
import { resolveMemberId, type MembershipRole } from './entities';
import { chunkArray, type AppDb, type ScopeStub } from './push';
import { scopeOwnerId, userScope } from './scopeName';

export interface PullMembershipItem {
  projectId: string;
  scope: string;
  role: MembershipRole;
}

export interface PullMemberRow {
  id: string;
  userId: string;
  name: string;
  initial: string;
  color: string;
  avatarUrl: string | null;
  isMe: false;
  createdAt: number;
  updatedAt: number;
}

export interface PullResponse {
  scopes: ScopePullResponse[];
  memberships: PullMembershipItem[];
  members: PullMemberRow[];
}

export async function executeSyncPull(
  db: AppDb,
  params: {
    userId: string;
    cursors: Record<string, number>;
    backfill?: string[];
    limit: number;
    getScopeStub: (scope: string) => Pick<ScopeStub, 'pull' | 'purgeProject'>;
  },
): Promise<PullResponse> {
  const { userId, cursors, backfill, limit, getScopeStub } = params;
  const ownScope = userScope(userId);

  const [userRows, membershipRows] = (await db.batch([
    db.select({ meMemberId: user.meMemberId }).from(user).where(eq(user.id, userId)),
    db
      .select({ projectId: projectMembership.projectId, role: projectMembership.role })
      .from(projectMembership)
      .where(and(eq(projectMembership.userId, userId), isNull(projectMembership.removedAt))),
  ])) as [Array<{ meMemberId: string | null }>, Array<{ projectId: string; role: string }>];

  const meMemberId =
    userRows[0] && typeof userRows[0].meMemberId === 'string' ? userRows[0].meMemberId : null;

  const membershipMap: Record<string, MembershipRole> = {};
  for (const r of membershipRows) {
    if (r.role === 'owner' || r.role === 'editor' || r.role === 'viewer') {
      membershipMap[r.projectId] = r.role;
    }
  }
  const memberProjectIds = Object.keys(membershipMap);

  const projectHomeMap = new Map<string, string>();
  const listScopeRows: Array<{ projectId: string; scope: string }> = [];
  const purgedIds = new Set<string>();
  const coMemberRows: Array<{
    projectId: string;
    memberUserId: string;
    role: string;
    meMemberId: string | null;
    name: string | null;
    initial: string | null;
    color: string | null;
    avatarUrl: string | null;
    createdAt: number;
  }> = [];

  if (memberProjectIds.length > 0) {
    const stmts: BatchItem<'sqlite'>[] = [];
    const chunks = chunkArray(memberProjectIds, 50);
    for (const chunk of chunks) {
      stmts.push(
        db
          .select({ projectId: listScopes.projectId, scope: listScopes.scope })
          .from(listScopes)
          .where(inArray(listScopes.projectId, chunk)),
      );
    }
    for (const chunk of chunks) {
      stmts.push(
        db
          .select({ entityId: entityHome.entityId, scope: entityHome.scope })
          .from(entityHome)
          .where(and(eq(entityHome.entity, 'project'), inArray(entityHome.entityId, chunk))),
      );
    }
    for (const chunk of chunks) {
      stmts.push(
        db
          .select({ projectId: purgedProject.projectId })
          .from(purgedProject)
          .where(inArray(purgedProject.projectId, chunk)),
      );
    }
    for (const chunk of chunks) {
      stmts.push(
        db
          .select({
            projectId: projectMembership.projectId,
            memberUserId: projectMembership.userId,
            role: projectMembership.role,
            meMemberId: user.meMemberId,
            name: user.name,
            initial: user.initial,
            color: user.color,
            avatarUrl: user.avatarUrl,
            createdAt: user.createdAt,
          })
          .from(projectMembership)
          .innerJoin(user, eq(projectMembership.userId, user.id))
          .where(and(inArray(projectMembership.projectId, chunk), isNull(projectMembership.removedAt))),
      );
    }
    const batchResults = (await db.batch(
      stmts as [BatchItem<'sqlite'>, ...BatchItem<'sqlite'>[]],
    )) as Array<Array<Record<string, unknown>>>;

    const c = chunks.length;
    for (let i = 0; i < c; i += 1) {
      for (const r of batchResults[i]) {
        listScopeRows.push({
          projectId: String(r.projectId),
          scope: String(r.scope),
        });
      }
    }
    for (let i = c; i < c * 2; i += 1) {
      for (const r of batchResults[i]) {
        projectHomeMap.set(String(r.entityId), String(r.scope));
      }
    }
    for (let i = c * 2; i < c * 3; i += 1) {
      for (const r of batchResults[i]) {
        purgedIds.add(String(r.projectId));
      }
    }
    for (let i = c * 3; i < batchResults.length; i += 1) {
      for (const r of batchResults[i]) {
        coMemberRows.push({
          projectId: String(r.projectId),
          memberUserId: String(r.memberUserId),
          role: String(r.role),
          meMemberId: typeof r.meMemberId === 'string' ? r.meMemberId : null,
          name: typeof r.name === 'string' ? r.name : null,
          initial: typeof r.initial === 'string' ? r.initial : null,
          color: typeof r.color === 'string' ? r.color : null,
          avatarUrl: typeof r.avatarUrl === 'string' && r.avatarUrl.length > 0 ? r.avatarUrl : null,
          createdAt: Number(r.createdAt),
        });
      }
    }
  }

  for (const pid of purgedIds) {
    delete membershipMap[pid];
  }
  const activeProjectIds = Object.keys(membershipMap);

  const memberships: PullMembershipItem[] = activeProjectIds.map((projectId) => ({
    projectId,
    scope: projectHomeMap.get(projectId) ?? ownScope,
    role: membershipMap[projectId],
  }));

  const isBackfill = Array.isArray(backfill) && backfill.length > 0;
  const authorizedBackfill = isBackfill
    ? Array.from(new Set(backfill.filter((pid) => Boolean(membershipMap[pid]))))
    : undefined;

  const relevantProjectIds = isBackfill ? authorizedBackfill! : activeProjectIds;
  const relevantSet = new Set(relevantProjectIds);

  const expectedMembersByHomeScope = new Map<string, Record<string, ExpectedProjectMember[]>>();
  for (const pid of relevantProjectIds) {
    const home = projectHomeMap.get(pid);
    if (!home) continue;
    let map = expectedMembersByHomeScope.get(home);
    if (!map) {
      map = {};
      expectedMembersByHomeScope.set(home, map);
    }
    map[pid] = [];
  }

  const membersByUserId = new Map<string, PullMemberRow>();
  for (const r of coMemberRows) {
    if (purgedIds.has(r.projectId)) continue;
    const memberId = resolveMemberId(r.memberUserId, r.meMemberId);
    if (r.memberUserId !== userId && !membersByUserId.has(r.memberUserId)) {
      membersByUserId.set(r.memberUserId, {
        id: memberId,
        userId: r.memberUserId,
        name: r.name ?? '',
        initial: r.initial ?? '',
        color: r.color ?? '',
        avatarUrl: r.avatarUrl,
        isMe: false,
        createdAt: r.createdAt,
        updatedAt: r.createdAt,
      });
    }
    if (
      relevantSet.has(r.projectId) &&
      (r.role === 'owner' || r.role === 'editor' || r.role === 'viewer')
    ) {
      const home = projectHomeMap.get(r.projectId);
      if (home) {
        const expected = expectedMembersByHomeScope.get(home);
        if (expected && expected[r.projectId]) {
          expected[r.projectId].push({ memberId, role: r.role });
        }
      }
    }
  }
  const members = Array.from(membersByUserId.values()).sort((a, b) => a.id.localeCompare(b.id));

  const targetScopes = new Set<string>();
  if (isBackfill) {
    const backfillSet = new Set(authorizedBackfill);
    for (const row of listScopeRows) {
      if (backfillSet.has(row.projectId)) {
        targetScopes.add(row.scope);
      }
    }
    for (const pid of authorizedBackfill!) {
      const home = projectHomeMap.get(pid);
      if (home) targetScopes.add(home);
    }
  } else {
    targetScopes.add(ownScope);
    for (const row of listScopeRows) {
      if (purgedIds.has(row.projectId)) continue;
      targetScopes.add(row.scope);
    }
    for (const pid of activeProjectIds) {
      const home = projectHomeMap.get(pid);
      if (home) targetScopes.add(home);
    }
  }

  const orderedScopes = Array.from(targetScopes).sort();
  if (orderedScopes.length > 0) {
    const scopeChunks = chunkArray(orderedScopes, 50);
    const pendingPurges: Array<{ projectId: string; scope: string; purgedAt: number }> = [];
    const purgeCheckResults = (await db.batch(
      scopeChunks.map((chunk) =>
        db
          .select({
            projectId: listScopes.projectId,
            scope: listScopes.scope,
            purgedAt: purgedProject.purgedAt,
          })
          .from(listScopes)
          .innerJoin(purgedProject, eq(listScopes.projectId, purgedProject.projectId))
          .where(inArray(listScopes.scope, chunk)),
      ) as unknown as [BatchItem<'sqlite'>, ...BatchItem<'sqlite'>[]],
    )) as Array<Array<{ projectId: string; scope: string; purgedAt: number }>>;

    for (const rows of purgeCheckResults) {
      for (const r of rows) {
        pendingPurges.push({
          projectId: String(r.projectId),
          scope: String(r.scope),
          purgedAt: Number(r.purgedAt),
        });
      }
    }

    if (pendingPurges.length > 0) {
      const purgeSettled = await Promise.allSettled(
        pendingPurges.map((p) =>
          getScopeStub(p.scope).purgeProject({ projectId: p.projectId, purgedAt: p.purgedAt }),
        ),
      );
      const succeeded = pendingPurges.filter((_, idx) => purgeSettled[idx].status === 'fulfilled');
      if (succeeded.length > 0) {
        await db.batch(
          succeeded.map((p) =>
            db
              .delete(listScopes)
              .where(and(eq(listScopes.projectId, p.projectId), eq(listScopes.scope, p.scope))),
          ) as unknown as [BatchItem<'sqlite'>, ...BatchItem<'sqlite'>[]],
        );
      }
    }
  }

  const scopes = await Promise.all(
    orderedScopes.map((scope) => {
      const scopeUserId = scopeOwnerId(scope);
      const since = Object.hasOwn(cursors, scope) ? cursors[scope] : 0;
      return getScopeStub(scope).pull({
        scope,
        scopeUserId,
        requesterUserId: userId,
        since,
        limit,
        memberships: membershipMap,
        backfillProjectIds: authorizedBackfill,
        meMemberId,
        expectedProjectMembers: expectedMembersByHomeScope.get(scope),
      });
    }),
  );

  return {
    scopes,
    memberships,
    members,
  };
}
