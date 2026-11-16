import { describe, expect, it } from 'vitest';
import { authorizeOp, type AuthorizeOpInput } from '../src/scope/authorize';
import type { MembershipRole, StoredEntityState, ValidatedOp } from '../src/sync/entities';

const HLC = '1700000000000:0000:dev-a';

function op(
  entity: ValidatedOp['entity'],
  entityId: string,
  row: Record<string, unknown> = {},
  kind: ValidatedOp['op'] = 'upsert',
): ValidatedOp {
  return { opId: `op-${entityId}`, hlc: HLC, entity, entityId, op: kind, fields: Object.keys(row), row };
}

function state(row: Record<string, unknown>, extra: Partial<StoredEntityState> = {}): StoredEntityState {
  return { row, clocks: {}, purgedAt: null, serverSeq: 1, ...extra };
}

const MEMBERSHIPS: Record<string, MembershipRole> = {
  pOwn: 'owner',
  pEdit: 'editor',
  pView: 'viewer',
  pGone: 'owner',
};
const TASKS: Record<string, StoredEntityState> = {
  tOwn: state({ id: 'tOwn', projectId: 'pOwn' }),
  tView: state({ id: 'tView', projectId: 'pView' }),
  tGone: state({ id: 'tGone', projectId: 'pGone' }),
  tLost: state({ id: 'tLost', projectId: '' }, { purgedAt: 5 }),
};

function run(
  o: ValidatedOp,
  existing: StoredEntityState | null,
  isScopeOwner = true,
): ReturnType<typeof authorizeOp> {
  const input: AuthorizeOpInput = {
    op: o,
    existing,
    isScopeOwner,
    access: { memberships: MEMBERSHIPS, purgedSet: new Set(['pGone']) },
    getTask: (id) => TASKS[id] ?? null,
  };
  return authorizeOp(input);
}

const reasonOf = (r: ReturnType<typeof authorizeOp>) => (r.ok ? null : r.reason);

describe('authorizeOp', () => {
  it.each<[string, ValidatedOp, StoredEntityState | null, boolean, string | null]>([
    ['owner-only tag by a guest', op('tag', 'work'), null, false, 'Forbidden'],
    ['owner-only member by the owner', op('member', 'm1'), null, true, null],
    ['viewer edits a list', op('project', 'pView', { name: 'x' }), state({ id: 'pView' }), true, 'Forbidden'],
    ['editor renames a list', op('project', 'pEdit', { name: 'x' }), state({ id: 'pEdit' }), true, null],
    ['editor archives a list', op('project', 'pEdit', { archivedAt: 9 }), state({ id: 'pEdit', archivedAt: null }), true, 'Forbidden'],
    ['owner archives a list', op('project', 'pOwn', { archivedAt: 9 }), state({ id: 'pOwn', archivedAt: null }), true, null],
    ['editor resends the same archivedAt', op('project', 'pEdit', { archivedAt: 9 }), state({ id: 'pEdit', archivedAt: 9 }), true, null],
    ['upsert into a purged list', op('project', 'pGone', { name: 'x' }), state({ id: 'pGone' }), true, 'Project is purged'],
    ['editor deletes a list', op('project', 'pEdit', {}, 'delete'), state({ id: 'pEdit' }), true, 'Forbidden'],
    ['owner deletes before D1 purge', op('project', 'pOwn', {}, 'delete'), state({ id: 'pOwn' }), true, 'Project deletion must be purged via D1'],
    ['owner delete replay after purge', op('project', 'pGone', {}, 'delete'), state({ id: 'pGone' }), true, null],
    ['new task in a viewer list', op('task', 'tNew', { projectId: 'pView' }), null, true, 'Forbidden'],
    ['new task in a purged list', op('task', 'tNew', { projectId: 'pGone' }), null, true, 'Project is purged'],
    ['guest deletes an unknown task', op('task', 'tNew', {}, 'delete'), null, false, 'Forbidden'],
    ['editor moves a task to a viewer list', op('task', 'tOwn', { projectId: 'pView' }), TASKS.tOwn, true, 'Forbidden'],
    ['task move into a purged list', op('task', 'tOwn', { projectId: 'pGone' }), TASKS.tOwn, true, 'Project is purged'],
    ['owner replays onto a list-less tombstone', op('task', 'tLost', { title: 'x' }), TASKS.tLost, true, null],
    ['guest replays onto a list-less tombstone', op('task', 'tLost', { title: 'x' }), TASKS.tLost, false, 'Forbidden'],
    ['child moved to another task', op('checklistItem', 'c1', { taskId: 'tView' }), state({ id: 'c1', taskId: 'tOwn' }), true, 'Child taskId cannot be changed'],
    ['child of a task in a viewer list', op('checklistItem', 'c1', { title: 'x' }), state({ id: 'c1', taskId: 'tView' }), true, 'Forbidden'],
    ['child of a task in a purged list', op('checklistItem', 'c1', { title: 'x' }), state({ id: 'c1', taskId: 'tGone' }), true, 'Project is purged'],
    ['new child of an unknown task', op('checklistItem', 'c2', { taskId: 'tMissing' }), null, true, 'unknown-row'],
    ['new child under a list-less task tombstone', op('checklistItem', 'c2', { taskId: 'tLost' }), null, true, null],
  ])('%s', (_name, o, existing, isScopeOwner, expected) => {
    expect(reasonOf(run(o, existing, isScopeOwner))).toBe(expected);
  });

  it("returns the child's parent task and its current list", () => {
    const res = run(op('comment', 'cm1', { taskId: 'tOwn' }), null);
    expect(res).toEqual({ ok: true, parentTask: TASKS.tOwn, childProjectId: 'pOwn' });
  });

  it("falls back to the child's stored list when its parent task is gone", () => {
    const res = run(
      op('attachment', 'a1', { fileName: 'x' }),
      state({ id: 'a1', taskId: 'tMissing' }, { projectId: 'pEdit' }),
    );
    expect(res).toEqual({ ok: true, parentTask: null, childProjectId: 'pEdit' });
  });
});
