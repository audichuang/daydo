import { entityHome, invite, projectMembership, purgedProject, user } from '@schema';
import { and, eq, isNull, ne, sql, type BatchItem } from 'void/db';
import { sha256Hex } from '../auth/crypto';
import { resolveMemberId, type MembershipRole } from '../sync/entities';
import type { AppDb, ScopeStub } from '../sync/push';

export const INVITE_TTL_MS = 7 * 24 * 60 * 60 * 1000;

export class SharingError extends Error {
  readonly status: number;

  constructor(status: number, message: string) {
    super(message);
    this.status = status;
  }
}

export function generateInviteCode(): string {
  const bytes = new Uint8Array(16);
  crypto.getRandomValues(bytes);
  let binary = '';
  for (const byte of bytes) {
    binary += String.fromCharCode(byte);
  }
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

export type InviteRole = 'editor' | 'viewer';

export function parseInviteRole(raw: unknown): InviteRole | null {
  return raw === 'editor' || raw === 'viewer' ? raw : null;
}

export async function createInvite(
  db: AppDb,
  params: {
    userId: string;
    projectId: string;
    role: unknown;
    email?: unknown;
    nowMs?: number;
  },
): Promise<{ code: string; url: string; expiresAt: number }> {
  const role = parseInviteRole(params.role);
  if (!role) {
    throw new SharingError(400, 'role must be editor or viewer');
  }

  let email: string | null = null;
  if (params.email !== undefined && params.email !== null) {
    if (typeof params.email !== 'string') {
      throw new SharingError(400, 'email must be a string');
    }
    const trimmed = params.email.trim();
    email = trimmed.length > 0 ? trimmed : null;
  }

  const [membershipRows, purgedRows, homeRows] = (await db.batch([
    db
      .select({ role: projectMembership.role, removedAt: projectMembership.removedAt })
      .from(projectMembership)
      .where(
        and(
          eq(projectMembership.projectId, params.projectId),
          eq(projectMembership.userId, params.userId),
        ),
      ),
    db
      .select({ projectId: purgedProject.projectId })
      .from(purgedProject)
      .where(eq(purgedProject.projectId, params.projectId)),
    db
      .select({ scope: entityHome.scope })
      .from(entityHome)
      .where(and(eq(entityHome.entity, 'project'), eq(entityHome.entityId, params.projectId))),
  ] as [BatchItem<'sqlite'>, ...BatchItem<'sqlite'>[]])) as [
    Array<{ role: string; removedAt: number | null }>,
    Array<{ projectId: string }>,
    Array<{ scope: string }>,
  ];

  if (purgedRows.length > 0 || homeRows.length === 0) {
    throw new SharingError(404, 'Project not found');
  }
  const membership = membershipRows[0];
  if (!membership || membership.removedAt !== null || membership.role !== 'owner') {
    throw new SharingError(403, 'Only the project owner can create invites');
  }

  const now = params.nowMs ?? Date.now();
  const expiresAt = now + INVITE_TTL_MS;
  const code = generateInviteCode();
  const codeHash = await sha256Hex(code);

  await db.insert(invite).values({
    codeHash,
    projectId: params.projectId,
    role,
    email,
    createdBy: params.userId,
    createdAt: now,
    expiresAt,
    revokedAt: null,
  });

  return {
    code,
    url: `daydo://invite/${code}`,
    expiresAt,
  };
}

export async function getInviteInfo(
  db: AppDb,
  params: {
    code: string;
    getScopeStub: (scope: string) => Pick<ScopeStub, 'getProjectInfo'>;
    nowMs?: number;
  },
): Promise<{
  projectName: string;
  inviterName: string;
  role: InviteRole;
  expiresAt: number;
}> {
  if (!params.code) {
    throw new SharingError(404, 'Invite not found');
  }
  const now = params.nowMs ?? Date.now();
  const codeHash = await sha256Hex(params.code);

  const inviteRows = await db
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

  const row = inviteRows[0];
  if (
    !row ||
    row.revokedAt !== null ||
    row.expiresAt <= now ||
    row.purgedId !== null ||
    !row.homeScope
  ) {
    throw new SharingError(404, 'Invite not found');
  }

  const projectInfo = await params.getScopeStub(row.homeScope).getProjectInfo({
    projectId: row.projectId,
  });
  if (!projectInfo || projectInfo.purgedAt !== null) {
    throw new SharingError(404, 'Invite not found');
  }

  return {
    projectName: projectInfo.name,
    inviterName: row.inviterName ?? '',
    role: row.role === 'editor' ? 'editor' : 'viewer',
    expiresAt: Number(row.expiresAt),
  };
}

export async function acceptInvite(
  db: AppDb,
  params: {
    code: string;
    userId: string;
    getScopeStub: (scope: string) => Pick<ScopeStub, 'projectMember'>;
    nowMs?: number;
  },
): Promise<{
  projectId: string;
  scope: string;
  role: MembershipRole;
}> {
  if (!params.code) {
    throw new SharingError(404, 'Invite not found');
  }
  const now = params.nowMs ?? Date.now();
  const codeHash = await sha256Hex(params.code);

  const inserted = (await db.all(sql`
    INSERT INTO projectMembership (projectId, userId, role, createdAt, removedAt)
    SELECT i.projectId, ${params.userId}, i.role, ${now}, NULL
    FROM invite i
    WHERE i.codeHash = ${codeHash}
      AND i.revokedAt IS NULL
      AND i.expiresAt > ${now}
      AND NOT EXISTS (SELECT 1 FROM purgedProject p WHERE p.projectId = i.projectId)
      AND EXISTS (
        SELECT 1 FROM entityHome eh
        WHERE eh.entity = 'project' AND eh.entityId = i.projectId
      )
    ON CONFLICT (projectId, userId) DO UPDATE SET
      role = CASE
        WHEN projectMembership.role = 'owner' THEN 'owner'
        WHEN projectMembership.removedAt IS NULL THEN projectMembership.role
        ELSE excluded.role
      END,
      removedAt = NULL
    RETURNING projectId, role
  `)) as Array<{ projectId: string; role: string }>;

  if (inserted.length === 0) {
    throw new SharingError(404, 'Invite not found');
  }

  const projectId = String(inserted[0].projectId);
  const roleRaw = String(inserted[0].role);
  const role: MembershipRole =
    roleRaw === 'owner' ? 'owner' : roleRaw === 'editor' ? 'editor' : 'viewer';

  const [homeRows, userRows, ownerRows] = (await db.batch([
    db
      .select({ scope: entityHome.scope })
      .from(entityHome)
      .where(and(eq(entityHome.entity, 'project'), eq(entityHome.entityId, projectId))),
    db.select({ meMemberId: user.meMemberId }).from(user).where(eq(user.id, params.userId)),
    db
      .select({ userId: projectMembership.userId, meMemberId: user.meMemberId })
      .from(projectMembership)
      .leftJoin(user, eq(projectMembership.userId, user.id))
      .where(
        and(
          eq(projectMembership.projectId, projectId),
          eq(projectMembership.role, 'owner'),
          isNull(projectMembership.removedAt),
        ),
      ),
  ] as [BatchItem<'sqlite'>, ...BatchItem<'sqlite'>[]])) as [
    Array<{ scope: string }>,
    Array<{ meMemberId: string | null }>,
    Array<{ userId: string; meMemberId: string | null }>,
  ];

  const homeScope = homeRows[0]?.scope;
  if (!homeScope) {
    throw new SharingError(404, 'Project not found');
  }

  const projections: Array<{ memberId: string; role: MembershipRole }> = [];
  const ownerRow = ownerRows[0];
  if (ownerRow) {
    projections.push({
      memberId: resolveMemberId(ownerRow.userId, ownerRow.meMemberId ?? null),
      role: 'owner',
    });
  }
  if (!ownerRow || ownerRow.userId !== params.userId) {
    projections.push({
      memberId: resolveMemberId(params.userId, userRows[0]?.meMemberId ?? null),
      role,
    });
  }
  for (const proj of projections) {
    try {
      await params.getScopeStub(homeScope).projectMember({
        projectId,
        memberId: proj.memberId,
        role: proj.role,
        deleted: false,
        nowMs: now,
      });
    } catch {
      // D1 membership is committed; missed projections are healed on the next pull.
    }
  }

  return {
    projectId,
    scope: homeScope,
    role,
  };
}

export async function revokeInvite(
  db: AppDb,
  params: {
    code: string;
    userId: string;
    nowMs?: number;
  },
): Promise<{ revoked: true }> {
  if (!params.code) {
    throw new SharingError(404, 'Invite not found');
  }
  const now = params.nowMs ?? Date.now();
  const codeHash = await sha256Hex(params.code);

  const rows = await db
    .select({
      projectId: invite.projectId,
      revokedAt: invite.revokedAt,
      memberRole: projectMembership.role,
      memberRemovedAt: projectMembership.removedAt,
    })
    .from(invite)
    .leftJoin(
      projectMembership,
      and(
        eq(projectMembership.projectId, invite.projectId),
        eq(projectMembership.userId, params.userId),
      ),
    )
    .where(eq(invite.codeHash, codeHash));

  const row = rows[0];
  if (!row) {
    throw new SharingError(404, 'Invite not found');
  }
  if (row.memberRemovedAt !== null || row.memberRole !== 'owner') {
    throw new SharingError(403, 'Only the project owner can revoke invites');
  }

  if (row.revokedAt === null) {
    await db
      .update(invite)
      .set({ revokedAt: now })
      .where(and(eq(invite.codeHash, codeHash), isNull(invite.revokedAt)));
  }

  return { revoked: true };
}

export async function updateProjectMemberRole(
  db: AppDb,
  params: {
    projectId: string;
    targetUserId: string;
    requesterUserId: string;
    role: unknown;
    getScopeStub: (scope: string) => Pick<ScopeStub, 'projectMember'>;
    nowMs?: number;
  },
): Promise<{ projectId: string; userId: string; role: InviteRole }> {
  const role = parseInviteRole(params.role);
  if (!role) {
    throw new SharingError(400, 'role must be editor or viewer');
  }

  const [reqRows, targetRows, purgedRows, homeRows, targetUserRows] = (await db.batch([
    db
      .select({ role: projectMembership.role, removedAt: projectMembership.removedAt })
      .from(projectMembership)
      .where(
        and(
          eq(projectMembership.projectId, params.projectId),
          eq(projectMembership.userId, params.requesterUserId),
        ),
      ),
    db
      .select({ role: projectMembership.role, removedAt: projectMembership.removedAt })
      .from(projectMembership)
      .where(
        and(
          eq(projectMembership.projectId, params.projectId),
          eq(projectMembership.userId, params.targetUserId),
        ),
      ),
    db
      .select({ projectId: purgedProject.projectId })
      .from(purgedProject)
      .where(eq(purgedProject.projectId, params.projectId)),
    db
      .select({ scope: entityHome.scope })
      .from(entityHome)
      .where(and(eq(entityHome.entity, 'project'), eq(entityHome.entityId, params.projectId))),
    db
      .select({ meMemberId: user.meMemberId })
      .from(user)
      .where(eq(user.id, params.targetUserId)),
  ] as [BatchItem<'sqlite'>, ...BatchItem<'sqlite'>[]])) as [
    Array<{ role: string; removedAt: number | null }>,
    Array<{ role: string; removedAt: number | null }>,
    Array<{ projectId: string }>,
    Array<{ scope: string }>,
    Array<{ meMemberId: string | null }>,
  ];

  if (purgedRows.length > 0 || homeRows.length === 0) {
    throw new SharingError(404, 'Project not found');
  }
  const reqMembership = reqRows[0];
  if (!reqMembership || reqMembership.removedAt !== null || reqMembership.role !== 'owner') {
    throw new SharingError(403, 'Only the project owner can update member roles');
  }
  const targetMembership = targetRows[0];
  if (!targetMembership || targetMembership.removedAt !== null) {
    throw new SharingError(404, 'Member not found');
  }
  if (targetMembership.role === 'owner') {
    throw new SharingError(400, 'Cannot change the project owner role');
  }

  await db
    .update(projectMembership)
    .set({ role })
    .where(
      and(
        eq(projectMembership.projectId, params.projectId),
        eq(projectMembership.userId, params.targetUserId),
        isNull(projectMembership.removedAt),
        ne(projectMembership.role, 'owner'),
      ),
    );

  const now = params.nowMs ?? Date.now();
  const memberId = resolveMemberId(params.targetUserId, targetUserRows[0]?.meMemberId ?? null);
  try {
    await params.getScopeStub(homeRows[0].scope).projectMember({
      projectId: params.projectId,
      memberId,
      role,
      deleted: false,
      nowMs: now,
    });
  } catch {
    // D1 membership is committed; missed projections are healed on the next pull.
  }

  return {
    projectId: params.projectId,
    userId: params.targetUserId,
    role,
  };
}

export async function removeProjectMember(
  db: AppDb,
  params: {
    projectId: string;
    targetUserId: string;
    requesterUserId: string;
    getScopeStub: (scope: string) => Pick<ScopeStub, 'projectMember'>;
    nowMs?: number;
  },
): Promise<{ projectId: string; userId: string; removed: true }> {
  const [reqRows, targetRows, purgedRows, homeRows, targetUserRows] = (await db.batch([
    db
      .select({ role: projectMembership.role, removedAt: projectMembership.removedAt })
      .from(projectMembership)
      .where(
        and(
          eq(projectMembership.projectId, params.projectId),
          eq(projectMembership.userId, params.requesterUserId),
        ),
      ),
    db
      .select({ role: projectMembership.role, removedAt: projectMembership.removedAt })
      .from(projectMembership)
      .where(
        and(
          eq(projectMembership.projectId, params.projectId),
          eq(projectMembership.userId, params.targetUserId),
        ),
      ),
    db
      .select({ projectId: purgedProject.projectId })
      .from(purgedProject)
      .where(eq(purgedProject.projectId, params.projectId)),
    db
      .select({ scope: entityHome.scope })
      .from(entityHome)
      .where(and(eq(entityHome.entity, 'project'), eq(entityHome.entityId, params.projectId))),
    db
      .select({ meMemberId: user.meMemberId })
      .from(user)
      .where(eq(user.id, params.targetUserId)),
  ] as [BatchItem<'sqlite'>, ...BatchItem<'sqlite'>[]])) as [
    Array<{ role: string; removedAt: number | null }>,
    Array<{ role: string; removedAt: number | null }>,
    Array<{ projectId: string }>,
    Array<{ scope: string }>,
    Array<{ meMemberId: string | null }>,
  ];

  if (purgedRows.length > 0 || homeRows.length === 0) {
    throw new SharingError(404, 'Project not found');
  }

  const isSelf = params.targetUserId === params.requesterUserId;
  const reqMembership = reqRows[0];
  const isOwner = Boolean(
    reqMembership && reqMembership.removedAt === null && reqMembership.role === 'owner',
  );

  if (!isSelf && !isOwner) {
    throw new SharingError(403, 'Forbidden');
  }
  if (isSelf && isOwner) {
    throw new SharingError(400, 'Project owner cannot leave the project');
  }

  const targetMembership = targetRows[0];
  if (!targetMembership) {
    throw new SharingError(404, 'Member not found');
  }
  if (targetMembership.role === 'owner') {
    throw new SharingError(400, 'Project owner cannot be removed');
  }

  const now = params.nowMs ?? Date.now();
  if (targetMembership.removedAt === null) {
    await db
      .update(projectMembership)
      .set({ removedAt: now })
      .where(
        and(
          eq(projectMembership.projectId, params.projectId),
          eq(projectMembership.userId, params.targetUserId),
          isNull(projectMembership.removedAt),
          ne(projectMembership.role, 'owner'),
        ),
      );
  }

  const memberId = resolveMemberId(params.targetUserId, targetUserRows[0]?.meMemberId ?? null);
  const existingRole: InviteRole = targetMembership.role === 'editor' ? 'editor' : 'viewer';
  try {
    await params.getScopeStub(homeRows[0].scope).projectMember({
      projectId: params.projectId,
      memberId,
      role: existingRole,
      deleted: true,
      nowMs: now,
    });
  } catch {
    // D1 membership is committed; missed projections are healed on the next pull.
  }

  return {
    projectId: params.projectId,
    userId: params.targetUserId,
    removed: true,
  };
}
