import { entityHome, listScopes, projectMembership, user } from '@schema';
import { and, eq, inArray, isNull, type BatchItem } from 'void/db';
import type { ScopePullResponse } from '../../durable-objects/scope';
import type { MembershipRole } from './entities';
import { chunkArray, type AppDb, type ScopeStub } from './push';

export interface PullMembershipItem {
  projectId: string;
  scope: string;
  role: MembershipRole;
}

export interface PullResponse {
  scopes: ScopePullResponse[];
  memberships: PullMembershipItem[];
  members: unknown[];
}

export async function executeSyncPull(
  db: AppDb,
  params: {
    userId: string;
    cursors: Record<string, number>;
    backfill?: string[];
    limit: number;
    getScopeStub: (scope: string) => Pick<ScopeStub, 'pull'>;
  },
): Promise<PullResponse> {
  const { userId, cursors, backfill, limit, getScopeStub } = params;
  const userScope = `u:${userId}`;

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
    const batchResults = (await db.batch(
      stmts as [BatchItem<'sqlite'>, ...BatchItem<'sqlite'>[]],
    )) as Array<Array<Record<string, unknown>>>;

    for (let i = 0; i < chunks.length; i += 1) {
      for (const r of batchResults[i]) {
        listScopeRows.push({
          projectId: String(r.projectId),
          scope: String(r.scope),
        });
      }
    }
    for (let i = chunks.length; i < batchResults.length; i += 1) {
      for (const r of batchResults[i]) {
        projectHomeMap.set(String(r.entityId), String(r.scope));
      }
    }
  }

  const memberships: PullMembershipItem[] = memberProjectIds.map((projectId) => ({
    projectId,
    scope: projectHomeMap.get(projectId) ?? userScope,
    role: membershipMap[projectId],
  }));

  const isBackfill = Array.isArray(backfill) && backfill.length > 0;
  const authorizedBackfill = isBackfill
    ? Array.from(new Set(backfill.filter((pid) => Boolean(membershipMap[pid]))))
    : undefined;

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
    targetScopes.add(userScope);
    for (const row of listScopeRows) {
      targetScopes.add(row.scope);
    }
    for (const home of projectHomeMap.values()) {
      targetScopes.add(home);
    }
  }

  const orderedScopes = Array.from(targetScopes).sort();
  const scopes = await Promise.all(
    orderedScopes.map((scope) => {
      const scopeUserId = scope.startsWith('u:') ? scope.slice(2) : scope;
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
      });
    }),
  );

  return {
    scopes,
    memberships,
    members: [],
  };
}
