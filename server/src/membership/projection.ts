import type { ExpectedProjectMember } from '../../durable-objects/scope';
import { resolveMemberId, type MembershipRole } from '../sync/entities';
import type { ScopeStub } from '../sync/push';
import type { ActiveMemberRow } from './statements';

// D1 projectMembership is the source of truth; each list's home Scope keeps a
// projectMember projection of it. Sharing actions project right after the D1 write
// (best effort), and every pull hands the home Scope the expected member set so a
// missed projection is repaired there.

export interface MemberProjection {
  memberId: string;
  role: MembershipRole;
  deleted: boolean;
}

/** Projects membership changes into the list's home Scope, one call per projection. */
export async function projectToHome(
  getScopeStub: (scope: string) => Pick<ScopeStub, 'projectMember'>,
  params: { homeScope: string; projectId: string; nowMs: number },
  projections: readonly MemberProjection[],
): Promise<void> {
  for (const proj of projections) {
    try {
      await getScopeStub(params.homeScope).projectMember({
        projectId: params.projectId,
        memberId: proj.memberId,
        role: proj.role,
        deleted: proj.deleted,
        nowMs: params.nowMs,
      });
    } catch {
      // D1 membership is committed; missed projections are healed on the next pull.
    }
  }
}

/**
 * Projections after a user joins through an invite: the active owner (so the home
 * Scope always knows its owner) and the joiner, unless the joiner is that owner.
 */
export function joinProjections(params: {
  joinerUserId: string;
  joinerMeMemberId: string | null;
  joinerRole: MembershipRole;
  owner: { userId: string; meMemberId: string | null } | undefined;
}): MemberProjection[] {
  const { joinerUserId, joinerMeMemberId, joinerRole, owner } = params;
  const projections: MemberProjection[] = [];
  if (owner) {
    projections.push({
      memberId: resolveMemberId(owner.userId, owner.meMemberId ?? null),
      role: 'owner',
      deleted: false,
    });
  }
  if (!owner || owner.userId !== joinerUserId) {
    projections.push({
      memberId: resolveMemberId(joinerUserId, joinerMeMemberId),
      role: joinerRole,
      deleted: false,
    });
  }
  return projections;
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

/**
 * From active co-member rows, builds the puller's member directory (everyone but the
 * puller, sorted by member id) and, per home scope, the expected members of each
 * relevant list that the home Scope reconciles its projection against.
 */
export function planPullMembers(params: {
  userId: string;
  activeMembers: readonly ActiveMemberRow[];
  purgedIds: ReadonlySet<string>;
  relevantProjectIds: readonly string[];
  projectHomeMap: ReadonlyMap<string, string>;
}): {
  members: PullMemberRow[];
  expectedMembersByHomeScope: Map<string, Record<string, ExpectedProjectMember[]>>;
} {
  const { userId, activeMembers, purgedIds, relevantProjectIds, projectHomeMap } = params;
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
  for (const r of activeMembers) {
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
  return { members, expectedMembersByHomeScope };
}
