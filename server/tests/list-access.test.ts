import { describe, expect, it } from 'vitest';
import { hasWriteRole, listWriteDenial } from '../src/sync/access';
import type { MembershipRole } from '../src/sync/entities';

describe('listWriteDenial', () => {
  const memberships: Record<string, MembershipRole> = { po: 'owner', pe: 'editor', pv: 'viewer' };
  const purgedSet = new Set(['po-gone']);

  it.each([
    ['po', null],
    ['pe', null],
    ['pv', 'Forbidden'],
    ['p-none', 'Forbidden'],
    ['', 'Forbidden'],
  ] as const)('role check for %s → %s', (projectId, expected) => {
    expect(listWriteDenial(projectId, { memberships, purgedSet })).toBe(expected);
  });

  it('reports a purged list before any role, even for its owner', () => {
    expect(
      listWriteDenial('po-gone', { memberships: { ...memberships, 'po-gone': 'owner' }, purgedSet }),
    ).toBe('Project is purged');
  });

  it('reads roles from a Map the same way as from a record', () => {
    const map = new Map(Object.entries(memberships));
    for (const id of ['po', 'pe', 'pv', 'p-none']) {
      expect(listWriteDenial(id, { memberships: map, purgedSet: new Set() })).toBe(
        listWriteDenial(id, { memberships, purgedSet: new Set() }),
      );
    }
  });
});

describe('hasWriteRole', () => {
  it.each([
    ['owner', true],
    ['editor', true],
    ['viewer', false],
    [undefined, false],
  ] as const)('%s → %s, from a record or a Map', (role, expected) => {
    const memberships: Record<string, MembershipRole> = role ? { p: role } : {};
    expect(hasWriteRole(memberships, 'p')).toBe(expected);
    expect(hasWriteRole(new Map(Object.entries(memberships)), 'p')).toBe(expected);
  });
});
