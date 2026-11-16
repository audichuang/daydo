import type { MembershipRole } from './entities';

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

/** Whether the user's role on `projectId` lets them write into it (owner or editor); ignores purge. */
export function hasWriteRole(memberships: RoleLookup, projectId: string): boolean {
  const role = roleOf(memberships, projectId);
  return role === 'owner' || role === 'editor';
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
