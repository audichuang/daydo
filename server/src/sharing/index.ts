import { entityHome, invite, user } from '@schema';
import { and, eq, isNull, type BatchItem } from 'void/db';
import { sha256Hex } from '../auth/crypto';
import {
  activeOwnerOf,
  inviteDetails,
  inviteWithMembership,
  joinProjections,
  joinViaInvite,
  loadProjectAccess,
  projectToHome,
  removeActiveMember,
  setActiveMemberRole,
} from '../membership';
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

  const access = await loadProjectAccess(db, {
    projectId: params.projectId,
    requesterUserId: params.userId,
  });

  if (access.purged || access.homeScope === null) {
    throw new SharingError(404, 'Project not found');
  }
  const membership = access.requester;
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

  const inviteRows = await inviteDetails(db, codeHash);

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

  const inserted = await joinViaInvite(db, { codeHash, userId: params.userId, nowMs: now });

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
    activeOwnerOf(db, projectId),
  ] as [BatchItem<'sqlite'>, ...BatchItem<'sqlite'>[]])) as [
    Array<{ scope: string }>,
    Array<{ meMemberId: string | null }>,
    Array<{ userId: string; meMemberId: string | null }>,
  ];

  const homeScope = homeRows[0]?.scope;
  if (!homeScope) {
    throw new SharingError(404, 'Project not found');
  }

  await projectToHome(
    params.getScopeStub,
    { homeScope, projectId, nowMs: now },
    joinProjections({
      joinerUserId: params.userId,
      joinerMeMemberId: userRows[0]?.meMemberId ?? null,
      joinerRole: role,
      owner: ownerRows[0],
    }),
  );

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

  const rows = await inviteWithMembership(db, codeHash, params.userId);

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

  const access = await loadProjectAccess(db, {
    projectId: params.projectId,
    requesterUserId: params.requesterUserId,
    targetUserId: params.targetUserId,
  });

  if (access.purged || access.homeScope === null) {
    throw new SharingError(404, 'Project not found');
  }
  const homeScope = access.homeScope;
  const reqMembership = access.requester;
  if (!reqMembership || reqMembership.removedAt !== null || reqMembership.role !== 'owner') {
    throw new SharingError(403, 'Only the project owner can update member roles');
  }
  const targetMembership = access.target;
  if (!targetMembership || targetMembership.removedAt !== null) {
    throw new SharingError(404, 'Member not found');
  }
  if (targetMembership.role === 'owner') {
    throw new SharingError(400, 'Cannot change the project owner role');
  }

  await setActiveMemberRole(db, {
    projectId: params.projectId,
    userId: params.targetUserId,
    role,
  });

  const now = params.nowMs ?? Date.now();
  const memberId = resolveMemberId(params.targetUserId, access.targetMeMemberId);
  await projectToHome(
    params.getScopeStub,
    { homeScope, projectId: params.projectId, nowMs: now },
    [{ memberId, role, deleted: false }],
  );

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
  const access = await loadProjectAccess(db, {
    projectId: params.projectId,
    requesterUserId: params.requesterUserId,
    targetUserId: params.targetUserId,
  });

  if (access.purged || access.homeScope === null) {
    throw new SharingError(404, 'Project not found');
  }
  const homeScope = access.homeScope;

  const isSelf = params.targetUserId === params.requesterUserId;
  const reqMembership = access.requester;
  const isOwner = Boolean(
    reqMembership && reqMembership.removedAt === null && reqMembership.role === 'owner',
  );

  if (!isSelf && !isOwner) {
    throw new SharingError(403, 'Forbidden');
  }
  if (isSelf && isOwner) {
    throw new SharingError(400, 'Project owner cannot leave the project');
  }

  const targetMembership = access.target;
  if (!targetMembership) {
    throw new SharingError(404, 'Member not found');
  }
  if (targetMembership.role === 'owner') {
    throw new SharingError(400, 'Project owner cannot be removed');
  }

  const now = params.nowMs ?? Date.now();
  if (targetMembership.removedAt === null) {
    await removeActiveMember(db, {
      projectId: params.projectId,
      userId: params.targetUserId,
      nowMs: now,
    });
  }

  const memberId = resolveMemberId(params.targetUserId, access.targetMeMemberId);
  const existingRole: InviteRole = targetMembership.role === 'editor' ? 'editor' : 'viewer';
  await projectToHome(
    params.getScopeStub,
    { homeScope, projectId: params.projectId, nowMs: now },
    [{ memberId, role: existingRole, deleted: true }],
  );

  return {
    projectId: params.projectId,
    userId: params.targetUserId,
    removed: true,
  };
}
