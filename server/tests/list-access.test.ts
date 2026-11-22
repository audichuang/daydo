import { describe, expect, it } from 'vitest';
import { canManageLifecycle, snapshotRole, type Snapshot } from '../src/serverops/snapshot';
import {
  canManageListLifecycle,
  canRead,
  childListId,
  hasWriteRole,
  isOwner,
  isOwnerOnlyEntity,
  listWriteDenial,
  OWNER_ONLY_ENTITIES,
  roleCanWrite,
} from '../src/sync/access';
import { ENTITY_NAMES, type EntityName, type MembershipRole } from '../src/sync/entities';
import { REJECT_REASON, rejectedResult } from '../src/sync/rejectReason';

describe('OWNER_ONLY_ENTITIES / isOwnerOnlyEntity', () => {
  it('defines the exact owner-only entity set', () => {
    expect([...OWNER_ONLY_ENTITIES]).toEqual(['member', 'folder', 'tag']);
  });

  it.each<[EntityName, boolean]>([
    ['member', true],
    ['folder', true],
    ['tag', true],
    ['project', false],
    ['projectMember', false],
    ['projectInvite', false],
    ['task', false],
    ['checklistItem', false],
    ['attachment', false],
    ['comment', false],
  ])('%s → %s', (entity, expected) => {
    expect(isOwnerOnlyEntity(entity)).toBe(expected);
  });

  it('covers every EntityName', () => {
    const ownerOnly = ENTITY_NAMES.filter((e) => isOwnerOnlyEntity(e));
    expect(ownerOnly).toEqual(['member', 'folder', 'tag']);
  });
});

describe('childListId', () => {
  it.each<[string, string | null | undefined, string | null | undefined, string]>([
    ['uses parent task list when present', 'p-parent', 'p-stored', 'p-parent'],
    ['keeps empty string from a list-less parent tombstone over stored projectId', '', 'p-stored', ''],
    ['falls back to stored projectId when parent is missing (null)', null, 'p-stored', 'p-stored'],
    ['falls back to stored projectId when parent is missing (undefined)', undefined, 'p-stored', 'p-stored'],
    ['returns empty string when both parent and stored projectId are absent', null, undefined, ''],
    ['returns empty string when parent is null and stored projectId is null', null, null, ''],
    ['returns parent list when stored projectId is omitted', 'p-parent', undefined, 'p-parent'],
  ])('%s', (_label, parentProjectId, storedProjectId, expected) => {
    expect(childListId(parentProjectId, storedProjectId)).toBe(expected);
  });
});

describe('canRead', () => {
  it.each<[MembershipRole | undefined, boolean]>([
    ['owner', true],
    ['editor', true],
    ['viewer', true],
    [undefined, false],
  ])('%s → %s, from a record or a Map', (role, expected) => {
    const memberships: Record<string, MembershipRole> = role ? { p: role } : {};
    expect(canRead(memberships, 'p')).toBe(expected);
    expect(canRead(new Map(Object.entries(memberships)), 'p')).toBe(expected);
  });

  it('is false for an empty project id', () => {
    expect(canRead({ p: 'owner' }, '')).toBe(false);
    expect(canRead(new Map([['p', 'owner']]), '')).toBe(false);
  });
});

describe('single-role checks', () => {
  it.each<[MembershipRole | null | undefined, boolean, boolean, boolean]>([
    ['owner', true, true, true],
    ['editor', true, false, false],
    ['viewer', false, false, false],
    [null, false, false, false],
    [undefined, false, false, false],
  ])('role %s → write=%s, owner=%s, lifecycle=%s', (role, canWrite, owner, lifecycle) => {
    expect(roleCanWrite(role)).toBe(canWrite);
    expect(isOwner(role)).toBe(owner);
    expect(canManageListLifecycle(role)).toBe(lifecycle);
  });
});

describe('snapshotRole / canManageLifecycle', () => {
  const snap = {
    memberships: new Map<string, MembershipRole>([
      ['po', 'owner'],
      ['pe', 'editor'],
      ['pv', 'viewer'],
    ]),
  } as Snapshot;

  it.each<[string, MembershipRole | undefined, boolean]>([
    ['po', 'owner', true],
    ['pe', 'editor', false],
    ['pv', 'viewer', false],
    ['p-none', undefined, false],
  ])('%s → role=%s, lifecycle=%s', (projectId, expectedRole, expectedLifecycle) => {
    expect(snapshotRole(snap, projectId)).toBe(expectedRole);
    expect(canManageLifecycle(snap, projectId)).toBe(expectedLifecycle);
  });
});

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

describe('REJECT_REASON / rejectedResult', () => {
  it('exports the exact fixed push reject reason wire strings', () => {
    expect(Object.values(REJECT_REASON).sort()).toEqual([
      'Child taskId cannot be changed',
      'Forbidden',
      'Malformed op',
      'Project deletion must be purged via D1',
      'Project is purged',
      'id-in-other-scope',
      'unknown-row',
    ]);
  });

  it('builds a rejected PushOpResult with optional row, clocks, and gone', () => {
    const minimal = rejectedResult('op-1', REJECT_REASON.FORBIDDEN);
    expect(minimal).toEqual({
      opId: 'op-1',
      status: 'rejected',
      reason: 'Forbidden',
      row: null,
      clocks: {},
    });
    expect('gone' in minimal).toBe(false);

    const withRow = rejectedResult('op-2', REJECT_REASON.PROJECT_PURGED, { id: 'p1' }, { name: '1:0:a' });
    expect(withRow).toEqual({
      opId: 'op-2',
      status: 'rejected',
      reason: 'Project is purged',
      row: { id: 'p1' },
      clocks: { name: '1:0:a' },
    });
    expect('gone' in withRow).toBe(false);

    const withGone = rejectedResult('op-3', REJECT_REASON.FORBIDDEN, null, {}, true);
    expect(withGone).toEqual({
      opId: 'op-3',
      status: 'rejected',
      reason: 'Forbidden',
      row: null,
      clocks: {},
      gone: true,
    });

    const withGoneFalse = rejectedResult('op-4', REJECT_REASON.UNKNOWN_ROW, null, {}, false);
    expect('gone' in withGoneFalse).toBe(false);
  });
});
