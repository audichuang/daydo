import { describe, expect, it } from 'vitest';
import { scopeOwnerId, userScope } from '../src/sync/scopeName';

describe('scopeName', () => {
  it('userScope prefixes the user id', () => {
    expect(userScope('abc')).toBe('u:abc');
  });

  it('scopeOwnerId strips the user prefix and leaves project scopes alone', () => {
    expect(scopeOwnerId('u:abc')).toBe('abc');
    expect(scopeOwnerId('proj-1')).toBe('proj-1');
    expect(scopeOwnerId(userScope('x'))).toBe('x');
  });
});
