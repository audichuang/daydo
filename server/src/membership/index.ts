// Project membership, list scopes, and purged lists: the D1 tables that decide who can
// see which list and which scopes hold its rows. Everything outside this module reaches
// those tables through the statement builders, loaders, and actions exported here.
// entityHome binding stays in sync/push; this module only reads a list's home scope.

export {
  activeForUser,
  activeMembersAmong,
  activeOwnerOf,
  activeProjectIds,
  asMembershipRole,
  claimOwner,
  collectProjectHomes,
  collectProjectIds,
  decodeActiveMembers,
  decodeActiveRoles,
  decodeForUser,
  decodeListScopes,
  decodeProjectIds,
  forUser,
  listScopesAmong,
  projectHomesAmong,
  purgedAmong,
  registerListScope,
  type ActiveMemberRow,
  type BatchRows,
} from './statements';
export {
  inviteDetails,
  inviteWithMembership,
  joinViaInvite,
  loadProjectAccess,
  removeActiveMember,
  requesterRoleOf,
  setActiveMemberRole,
  type MembershipState,
  type ProjectAccess,
} from './access';
export { purgeProject, retryPendingPurges } from './purge';
export {
  joinProjections,
  planPullMembers,
  projectToHome,
  type MemberProjection,
  type PullMemberRow,
} from './projection';
