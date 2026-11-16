import { user } from '@schema';
import { eq, type BatchItem } from 'void/db';
import type { ScopePullResponse } from '../../durable-objects/scope';
import {
  activeForUser,
  activeMembersAmong,
  collectProjectHomes,
  collectProjectIds,
  decodeActiveMembers,
  decodeActiveRoles,
  decodeListScopes,
  listScopesAmong,
  planPullMembers,
  projectHomesAmong,
  purgedAmong,
  retryPendingPurges,
  type ActiveMemberRow,
  type PullMemberRow,
} from '../membership';
import type { MembershipRole } from './entities';
import { chunkArray, type AppDb, type ScopeStub } from './push';
import { scopeOwnerId, userScope } from './scopeName';

export type { PullMemberRow };

export interface PullMembershipItem {
  projectId: string;
  scope: string;
  role: MembershipRole;
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
    activeForUser(db, userId),
  ])) as [Array<{ meMemberId: string | null }>, Array<{ projectId: string; role: string }>];

  const meMemberId =
    userRows[0] && typeof userRows[0].meMemberId === 'string' ? userRows[0].meMemberId : null;

  const membershipMap = decodeActiveRoles(membershipRows);
  const memberProjectIds = Object.keys(membershipMap);

  const projectHomeMap = new Map<string, string>();
  const listScopeRows: Array<{ projectId: string; scope: string }> = [];
  const purgedIds = new Set<string>();
  const coMemberRows: ActiveMemberRow[] = [];

  if (memberProjectIds.length > 0) {
    const stmts: BatchItem<'sqlite'>[] = [];
    const chunks = chunkArray(memberProjectIds, 50);
    for (const chunk of chunks) {
      stmts.push(listScopesAmong(db, chunk));
    }
    for (const chunk of chunks) {
      stmts.push(projectHomesAmong(db, chunk));
    }
    for (const chunk of chunks) {
      stmts.push(purgedAmong(db, chunk));
    }
    for (const chunk of chunks) {
      stmts.push(activeMembersAmong(db, chunk));
    }
    const batchResults = (await db.batch(
      stmts as [BatchItem<'sqlite'>, ...BatchItem<'sqlite'>[]],
    )) as Array<Array<Record<string, unknown>>>;

    const c = chunks.length;
    for (let i = 0; i < c; i += 1) {
      listScopeRows.push(...decodeListScopes(batchResults[i]));
    }
    for (let i = c; i < c * 2; i += 1) {
      collectProjectHomes(batchResults[i], projectHomeMap);
    }
    for (let i = c * 2; i < c * 3; i += 1) {
      collectProjectIds(batchResults[i], purgedIds);
    }
    for (let i = c * 3; i < batchResults.length; i += 1) {
      coMemberRows.push(...decodeActiveMembers(batchResults[i]));
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
  const { members, expectedMembersByHomeScope } = planPullMembers({
    userId,
    activeMembers: coMemberRows,
    purgedIds,
    relevantProjectIds,
    projectHomeMap,
  });

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
  await retryPendingPurges(db, { scopeChunks: chunkArray(orderedScopes, 50), getScopeStub });

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
