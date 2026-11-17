import { entityHome, listScopes, projectMembership, purgedProject, user } from '@schema';
import { and, eq, inArray, isNull, sql } from 'void/db';
import type { MembershipRole } from '../sync/entities';
import type { AppDb } from '../sync/push';

// Statement builders return un-awaited queries so callers can place them in the same
// db.batch() as today; decoders turn that batch slot's rows back into values.
// Builders that take id lists expect one chunk: callers keep their own chunking.

export type BatchRows = ReadonlyArray<Record<string, unknown>>;

export function asMembershipRole(raw: unknown): MembershipRole | null {
  return raw === 'owner' || raw === 'editor' || raw === 'viewer' ? raw : null;
}

/** Every membership row of a user, including removed ones (push context). */
export function forUser(db: AppDb, userId: string) {
  return db
    .select({
      projectId: projectMembership.projectId,
      role: projectMembership.role,
      removedAt: projectMembership.removedAt,
    })
    .from(projectMembership)
    .where(eq(projectMembership.userId, userId));
}

export function decodeForUser(rows: BatchRows): {
  memberships: Record<string, MembershipRole>;
  removedOwnerProjects: Set<string>;
} {
  const memberships: Record<string, MembershipRole> = {};
  const removedOwnerProjects = new Set<string>();
  for (const row of rows) {
    const role = row.role;
    if (row.removedAt === null || row.removedAt === undefined) {
      const active = asMembershipRole(role);
      if (active) {
        memberships[String(row.projectId)] = active;
      }
    } else if (role === 'owner') {
      removedOwnerProjects.add(String(row.projectId));
    }
  }
  return { memberships, removedOwnerProjects };
}

/** A user's active (not removed) memberships with their role. */
export function activeForUser(db: AppDb, userId: string) {
  return db
    .select({ projectId: projectMembership.projectId, role: projectMembership.role })
    .from(projectMembership)
    .where(and(eq(projectMembership.userId, userId), isNull(projectMembership.removedAt)));
}

export function decodeActiveRoles(rows: BatchRows): Record<string, MembershipRole> {
  const roles: Record<string, MembershipRole> = {};
  for (const row of rows) {
    const role = asMembershipRole(row.role);
    if (role) {
      roles[String(row.projectId)] = role;
    }
  }
  return roles;
}

/** Ids of the projects a user can currently read (login sync state). */
export function activeProjectIds(db: AppDb, userId: string) {
  return db
    .select({ projectId: projectMembership.projectId })
    .from(projectMembership)
    .where(and(eq(projectMembership.userId, userId), isNull(projectMembership.removedAt)));
}

export function decodeProjectIds(rows: BatchRows): string[] {
  return rows.map((r) => String(r.projectId));
}

/**
 * Makes the pusher the owner of a project it just homed in its own scope, unless the
 * project was purged or already has any membership row.
 */
export function claimOwner(
  db: AppDb,
  params: { projectId: string; userId: string; pusherScope: string; nowMs: number },
) {
  const { projectId: pid, userId, pusherScope, nowMs } = params;
  return db
    .insert(projectMembership)
    .select(
      sql`SELECT ${pid}, ${userId}, 'owner', ${nowMs}, NULL WHERE EXISTS (SELECT 1 FROM entityHome WHERE entity = 'project' AND entityId = ${pid} AND scope = ${pusherScope}) AND NOT EXISTS (SELECT 1 FROM purgedProject WHERE projectId = ${pid}) AND NOT EXISTS (SELECT 1 FROM projectMembership WHERE projectId = ${pid})`,
    )
    .onConflictDoNothing();
}

/** Records that `scope` holds rows of a list, only for an active owner/editor of an unpurged list. */
export function registerListScope(
  db: AppDb,
  params: { projectId: string; scope: string; userId: string },
) {
  const { projectId, scope, userId } = params;
  return db
    .insert(listScopes)
    .select(
      sql`SELECT ${projectId}, ${scope} WHERE NOT EXISTS (SELECT 1 FROM purgedProject WHERE projectId = ${projectId}) AND EXISTS (SELECT 1 FROM projectMembership WHERE projectId = ${projectId} AND userId = ${userId} AND removedAt IS NULL AND role IN ('owner', 'editor'))`,
    )
    .onConflictDoNothing();
}

/** Which of `projectIds` (one chunk) are purged. */
export function purgedAmong(db: AppDb, projectIds: string[]) {
  return db
    .select({ projectId: purgedProject.projectId })
    .from(purgedProject)
    .where(inArray(purgedProject.projectId, projectIds));
}

export function collectProjectIds(rows: BatchRows, into: Set<string>): void {
  for (const row of rows) {
    into.add(String(row.projectId));
  }
}

/** Scopes that hold rows of `projectIds` (one chunk). */
export function listScopesAmong(db: AppDb, projectIds: string[]) {
  return db
    .select({ projectId: listScopes.projectId, scope: listScopes.scope })
    .from(listScopes)
    .where(inArray(listScopes.projectId, projectIds));
}

export function decodeListScopes(rows: BatchRows): Array<{ projectId: string; scope: string }> {
  return rows.map((r) => ({ projectId: String(r.projectId), scope: String(r.scope) }));
}

/** Home scope of each project in `projectIds` (one chunk). */
export function projectHomesAmong(db: AppDb, projectIds: string[]) {
  return db
    .select({ entityId: entityHome.entityId, scope: entityHome.scope })
    .from(entityHome)
    .where(and(eq(entityHome.entity, 'project'), inArray(entityHome.entityId, projectIds)));
}

export function collectProjectHomes(rows: BatchRows, into: Map<string, string>): void {
  for (const r of rows) {
    into.set(String(r.entityId), String(r.scope));
  }
}

export interface ActiveMemberRow {
  projectId: string;
  memberUserId: string;
  role: string;
  meMemberId: string | null;
  name: string | null;
  initial: string | null;
  color: string | null;
  avatarUrl: string | null;
  createdAt: number;
}

/** Active members of `projectIds` (one chunk) with their profile. */
export function activeMembersAmong(db: AppDb, projectIds: string[]) {
  return db
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
    .where(and(inArray(projectMembership.projectId, projectIds), isNull(projectMembership.removedAt)));
}

export function decodeActiveMembers(rows: BatchRows): ActiveMemberRow[] {
  return rows.map((r) => ({
    projectId: String(r.projectId),
    memberUserId: String(r.memberUserId),
    role: String(r.role),
    meMemberId: typeof r.meMemberId === 'string' ? r.meMemberId : null,
    name: typeof r.name === 'string' ? r.name : null,
    initial: typeof r.initial === 'string' ? r.initial : null,
    color: typeof r.color === 'string' ? r.color : null,
    avatarUrl: typeof r.avatarUrl === 'string' && r.avatarUrl.length > 0 ? r.avatarUrl : null,
    createdAt: Number(r.createdAt),
  }));
}

/** The active owner of a project with the owner's bound member id. */
export function activeOwnerOf(db: AppDb, projectId: string) {
  return db
    .select({ userId: projectMembership.userId, meMemberId: user.meMemberId })
    .from(projectMembership)
    .leftJoin(user, eq(projectMembership.userId, user.id))
    .where(
      and(
        eq(projectMembership.projectId, projectId),
        eq(projectMembership.role, 'owner'),
        isNull(projectMembership.removedAt),
      ),
    );
}
