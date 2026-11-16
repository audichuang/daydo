// Naming of per-user sync scopes. A user's own scope is `u:<userId>`; project scopes use the bare project id.
const USER_SCOPE_PREFIX = 'u:';

export function userScope(userId: string): string {
  return `${USER_SCOPE_PREFIX}${userId}`;
}

// Inverse of userScope; scopes without the prefix (project scopes) are returned unchanged.
export function scopeOwnerId(scope: string): string {
  return scope.startsWith(USER_SCOPE_PREFIX) ? scope.slice(USER_SCOPE_PREFIX.length) : scope;
}
