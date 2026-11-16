import { entityHome, invite, projectMembership, purgedProject, user } from '@schema';
import { and, eq, isNull, ne, sql, type BatchItem } from 'void/db';
import type { AppDb } from '../sync/push';

export interface MembershipState {
  role: string;
  removedAt: number | null;
}

export interface ProjectAccess {
  /** The requester's membership row, removed or not; null when there is none. */
  requester: MembershipState | null;
  /** The target user's membership row; null when absent or no target was asked for. */
  target: MembershipState | null;
  purged: boolean;
  homeScope: string | null;
  /** The target user's bound member id; null when absent or no target was asked for. */
  targetMeMemberId: string | null;
}

function membershipOf(db: AppDb, projectId: string, userId: string) {
  return db
    .select({ role: projectMembership.role, removedAt: projectMembership.removedAt })
    .from(projectMembership)
    .where(and(eq(projectMembership.projectId, projectId), eq(projectMembership.userId, userId)));
}

/**
 * Reads what an owner-only sharing action needs in one D1 batch: requester membership,
 * (optionally) target membership, purge state, project home, and target's member id.
 * Without a target the batch has 3 statements, with a target 5.
 */
export async function loadProjectAccess(
  db: AppDb,
  params: { projectId: string; requesterUserId: string; targetUserId?: string },
): Promise<ProjectAccess> {
  const { projectId, requesterUserId, targetUserId } = params;
  const purgedStmt = db
    .select({ projectId: purgedProject.projectId })
    .from(purgedProject)
    .where(eq(purgedProject.projectId, projectId));
  const homeStmt = db
    .select({ scope: entityHome.scope })
    .from(entityHome)
    .where(and(eq(entityHome.entity, 'project'), eq(entityHome.entityId, projectId)));

  if (targetUserId === undefined) {
    const [reqRows, purgedRows, homeRows] = (await db.batch([
      membershipOf(db, projectId, requesterUserId),
      purgedStmt,
      homeStmt,
    ] as [BatchItem<'sqlite'>, ...BatchItem<'sqlite'>[]])) as [
      MembershipState[],
      Array<{ projectId: string }>,
      Array<{ scope: string }>,
    ];
    return {
      requester: reqRows[0] ?? null,
      target: null,
      purged: purgedRows.length > 0,
      homeScope: homeRows[0]?.scope ?? null,
      targetMeMemberId: null,
    };
  }

  const [reqRows, targetRows, purgedRows, homeRows, targetUserRows] = (await db.batch([
    membershipOf(db, projectId, requesterUserId),
    membershipOf(db, projectId, targetUserId),
    purgedStmt,
    homeStmt,
    db.select({ meMemberId: user.meMemberId }).from(user).where(eq(user.id, targetUserId)),
  ] as [BatchItem<'sqlite'>, ...BatchItem<'sqlite'>[]])) as [
    MembershipState[],
    MembershipState[],
    Array<{ projectId: string }>,
    Array<{ scope: string }>,
    Array<{ meMemberId: string | null }>,
  ];
  return {
    requester: reqRows[0] ?? null,
    target: targetRows[0] ?? null,
    purged: purgedRows.length > 0,
    homeScope: homeRows[0]?.scope ?? null,
    targetMeMemberId: targetUserRows[0]?.meMemberId ?? null,
  };
}

/** Role change for an active non-owner member. Run on its own, as today. */
export function setActiveMemberRole(
  db: AppDb,
  params: { projectId: string; userId: string; role: 'editor' | 'viewer' },
) {
  return db
    .update(projectMembership)
    .set({ role: params.role })
    .where(
      and(
        eq(projectMembership.projectId, params.projectId),
        eq(projectMembership.userId, params.userId),
        isNull(projectMembership.removedAt),
        ne(projectMembership.role, 'owner'),
      ),
    );
}

/** Soft-removes an active non-owner member. Run on its own, as today. */
export function removeActiveMember(
  db: AppDb,
  params: { projectId: string; userId: string; nowMs: number },
) {
  return db
    .update(projectMembership)
    .set({ removedAt: params.nowMs })
    .where(
      and(
        eq(projectMembership.projectId, params.projectId),
        eq(projectMembership.userId, params.userId),
        isNull(projectMembership.removedAt),
        ne(projectMembership.role, 'owner'),
      ),
    );
}

/**
 * Upserts the joiner's membership from a valid invite in one statement and returns the
 * resulting row (empty when the invite is unusable). An owner keeps owner, an active
 * member keeps their role, and a member removed at or after the invite was created
 * cannot rejoin with it.
 */
export function joinViaInvite(
  db: AppDb,
  params: { codeHash: string; userId: string; nowMs: number },
) {
  const { codeHash, userId, nowMs: now } = params;
  return db.all<{ projectId: string; role: string }>(sql`
    INSERT INTO projectMembership (projectId, userId, role, createdAt, removedAt)
    SELECT i.projectId, ${userId}, i.role, ${now}, NULL
    FROM invite i
    WHERE i.codeHash = ${codeHash}
      AND i.revokedAt IS NULL
      AND i.expiresAt > ${now}
      AND NOT EXISTS (SELECT 1 FROM purgedProject p WHERE p.projectId = i.projectId)
      AND EXISTS (
        SELECT 1 FROM entityHome eh
        WHERE eh.entity = 'project' AND eh.entityId = i.projectId
      )
      AND NOT EXISTS (
        SELECT 1 FROM projectMembership pm
        WHERE pm.projectId = i.projectId
          AND pm.userId = ${userId}
          AND pm.removedAt IS NOT NULL
          AND pm.removedAt >= i.createdAt
      )
    ON CONFLICT (projectId, userId) DO UPDATE SET
      role = CASE
        WHEN projectMembership.role = 'owner' THEN 'owner'
        WHEN projectMembership.removedAt IS NULL THEN projectMembership.role
        ELSE excluded.role
      END,
      removedAt = NULL
    RETURNING projectId, role
  `);
}

/** Invite row by code hash with inviter name, project home, and purge marker. */
export function inviteDetails(db: AppDb, codeHash: string) {
  return db
    .select({
      projectId: invite.projectId,
      role: invite.role,
      expiresAt: invite.expiresAt,
      revokedAt: invite.revokedAt,
      inviterName: user.name,
      homeScope: entityHome.scope,
      purgedId: purgedProject.projectId,
    })
    .from(invite)
    .leftJoin(user, eq(invite.createdBy, user.id))
    .leftJoin(
      entityHome,
      and(eq(entityHome.entity, 'project'), eq(entityHome.entityId, invite.projectId)),
    )
    .leftJoin(purgedProject, eq(purgedProject.projectId, invite.projectId))
    .where(eq(invite.codeHash, codeHash));
}

/** Invite row by code hash with the requester's membership in the invite's project. */
export function inviteWithMembership(db: AppDb, codeHash: string, userId: string) {
  return db
    .select({
      projectId: invite.projectId,
      revokedAt: invite.revokedAt,
      memberRole: projectMembership.role,
      memberRemovedAt: projectMembership.removedAt,
    })
    .from(invite)
    .leftJoin(
      projectMembership,
      and(eq(projectMembership.projectId, invite.projectId), eq(projectMembership.userId, userId)),
    )
    .where(eq(invite.codeHash, codeHash));
}
