import type { EntityName, MembershipRole } from './entities';

/** Entities that belong solely to the scope owner and are never shared across lists. */
export const OWNER_ONLY_ENTITIES = ['member', 'folder', 'tag'] as const;
export type OwnerOnlyEntity = (typeof OWNER_ONLY_ENTITIES)[number];

const OWNER_ONLY_ENTITY_SET: ReadonlySet<EntityName> = new Set(OWNER_ONLY_ENTITIES);

/** Whether `entity` is owner-only (only the scope owner may read or write it). */
export function isOwnerOnlyEntity(entity: EntityName): entity is OwnerOnlyEntity {
  return OWNER_ONLY_ENTITY_SET.has(entity);
}

/** A child row's list: its parent task's current list when present, else the row's stored projectId. */
export function childListId(
  parentProjectId: string | null | undefined,
  storedProjectId?: string | null,
): string {
  return parentProjectId ?? storedProjectId ?? '';
}

/** A user's role per project id, as a plain record (push input) or a map (snapshot). */
export type RoleLookup =
  | Readonly<Record<string, MembershipRole>>
  | ReadonlyMap<string, MembershipRole>;

export interface ListAccess {
  memberships: RoleLookup;
  /** Projects permanently deleted; writes into them are refused whatever the role. */
  purgedSet: ReadonlySet<string>;
}

export type ListWriteDenial = 'Project is purged' | 'Forbidden';

export function roleOf(memberships: RoleLookup, projectId: string): MembershipRole | undefined {
  return memberships instanceof Map
    ? memberships.get(projectId)
    : (memberships as Readonly<Record<string, MembershipRole>>)[projectId];
}

/** Whether the user holds any membership role on `projectId` (owner, editor or viewer). */
export function canRead(memberships: RoleLookup, projectId: string): boolean {
  return roleOf(memberships, projectId) !== undefined;
}

/** Whether a single membership role is the list owner. */
export function isOwner(role: MembershipRole | null | undefined): boolean {
  return role === 'owner';
}

/** Whether a single membership role grants write access (owner or editor); ignores purge. */
export function roleCanWrite(role: MembershipRole | null | undefined): boolean {
  return role === 'owner' || role === 'editor';
}

/** Whether a role may change a list's lifecycle (trash, restore, archive, unarchive, delete). */
export function canManageListLifecycle(role: MembershipRole | null | undefined): boolean {
  return isOwner(role);
}

/** Whether the user's role on `projectId` lets them write into it (owner or editor); ignores purge. */
export function hasWriteRole(memberships: RoleLookup, projectId: string): boolean {
  return roleCanWrite(roleOf(memberships, projectId));
}

/**
 * Why a write landing in list `projectId` is refused, or null when it is allowed: a purged list
 * refuses everyone, otherwise only owners and editors may write. The Scope DO is the authority;
 * the D1 planner and server-side writers use the same rule to fail early.
 */
export function listWriteDenial(projectId: string, access: ListAccess): ListWriteDenial | null {
  if (access.purgedSet.has(projectId)) return 'Project is purged';
  if (!hasWriteRole(access.memberships, projectId)) return 'Forbidden';
  return null;
}
