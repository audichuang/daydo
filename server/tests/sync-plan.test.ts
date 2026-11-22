import { eq } from 'drizzle-orm';
import { describe, expect, it } from 'vitest';
import { listScopes, projectMembership } from '../db/schema';
import { toEnvelope, type OpEnvelope } from '../src/sync/envelope';
import { newRowPreconditionDenial } from '../src/sync/newRow';
import { applyPushPlan } from '../src/sync/push/apply';
import { loadPushContext } from '../src/sync/push/context';
import { collectPushLookups } from '../src/sync/push/parse';
import {
  planPushBatch,
  type NewEntityHomeEntry,
  type PlanPushContext,
  type PushPlan,
} from '../src/sync/push/plan';
import type { ScopePushInput } from './helpers/scopeWorld';
import {
  createServerHarness,
  deviceOp,
  projectRow,
  seedUser,
  taskRow,
} from './helpers/serverHarness';

const HLC = '1700000000000:0001:dev-a';

function ctx(overrides: Partial<PlanPushContext> = {}): PlanPushContext {
  return {
    knownHome: new Map<string, string>(),
    purgedSet: new Set<string>(),
    memberships: {},
    removedOwnerProjects: new Set<string>(),
    ...overrides,
  };
}

function fullProjectOp(opId: string, id: string, extra: Record<string, unknown> = {}) {
  const row = projectRow(id, extra);
  return {
    opId,
    hlc: HLC,
    entity: 'project',
    entityId: id,
    op: 'upsert',
    fields: Object.keys(row),
    row,
  };
}

function fullTaskOp(
  opId: string,
  id: string,
  projectId: string,
  extra: Record<string, unknown> = {},
) {
  const row = taskRow(id, projectId, extra);
  return {
    opId,
    hlc: HLC,
    entity: 'task',
    entityId: id,
    op: 'upsert',
    fields: Object.keys(row),
    row,
  };
}

function fullChecklistOp(opId: string, id: string, taskId: string) {
  const row = {
    id,
    taskId,
    title: 'item',
    status: 0,
    sortKey: 'a0',
    createdAt: 1000,
    updatedAt: 1000,
  };
  return {
    opId,
    hlc: HLC,
    entity: 'checklistItem',
    entityId: id,
    op: 'upsert',
    fields: Object.keys(row),
    row,
  };
}

function fullMemberOp(opId: string, id: string) {
  const row = {
    id,
    name: 'Alice',
    initial: 'A',
    color: '#007AFF',
    createdAt: 1000,
    updatedAt: 1000,
  };
  return {
    opId,
    hlc: HLC,
    entity: 'member',
    entityId: id,
    op: 'upsert',
    fields: Object.keys(row),
    row,
  };
}

function fullFolderOp(opId: string, id: string) {
  const row = {
    id,
    name: 'Work',
    sortKey: 'a0',
    createdAt: 1000,
    updatedAt: 1000,
  };
  return {
    opId,
    hlc: HLC,
    entity: 'folder',
    entityId: id,
    op: 'upsert',
    fields: Object.keys(row),
    row,
  };
}

function fullTagOp(opId: string, name: string) {
  const row = {
    name,
    label: name,
    sortKey: 'a0',
    createdAt: 1000,
    updatedAt: 1000,
  };
  return {
    opId,
    hlc: HLC,
    entity: 'tag',
    entityId: name,
    op: 'upsert',
    fields: Object.keys(row),
    row,
  };
}

function partialOp(
  opId: string,
  entity: string,
  entityId: string,
  row: Record<string, unknown>,
  fields = Object.keys(row),
) {
  return { opId, hlc: HLC, entity, entityId, op: 'upsert', fields, row };
}

function deleteOp(opId: string, entity: string, entityId: string) {
  return { opId, hlc: HLC, entity, entityId, op: 'delete', fields: [], row: {} };
}

function planOps(
  ops: unknown[],
  context: PlanPushContext = ctx(),
  pusherScope = 'u:alice',
) {
  const parsed = collectPushLookups(ops.map(toEnvelope));
  return planPushBatch({ pusherScope, parsedOps: parsed.ops, context });
}

function routedScopes(plan: PushPlan) {
  return plan.ops.map((o) => (o.outcome.kind === 'routed' ? o.outcome.scope : null));
}

function rejectedResults(plan: PushPlan) {
  return plan.ops.map((o) => (o.outcome.kind === 'rejected' ? o.outcome.result : null));
}

function newHomes(plan: PushPlan): Map<string, NewEntityHomeEntry> {
  const map = new Map<string, NewEntityHomeEntry>();
  for (const op of plan.ops) {
    if (op.newHome) {
      map.set(`${op.newHome.entity}:${op.newHome.entityId}`, op.newHome);
    }
  }
  return map;
}

function listScopesWithIndex(plan: PushPlan) {
  return plan.ops.flatMap((o, idx) => (o.listScope ? [{ idx, ...o.listScope }] : []));
}

describe('planPushBatch characterization', () => {
  it('rejects malformed ops missing entity or entityId', () => {
    const plan = planOps([
      { opId: 'op-bad-entity', hlc: HLC, entity: 'bogus', entityId: 'x', op: 'upsert', fields: [], row: {} },
      { opId: 'op-empty-id', hlc: HLC, entity: 'task', entityId: '', op: 'upsert', fields: [], row: {} },
      'not-an-object',
    ]);

    expect(routedScopes(plan)).toEqual([null, null, null]);
    expect(rejectedResults(plan)[0]).toEqual({
      opId: 'op-bad-entity',
      status: 'rejected',
      reason: 'Unknown entity: bogus',
      row: null,
      clocks: {},
    });
    expect(rejectedResults(plan)[1]).toEqual({
      opId: 'op-empty-id',
      status: 'rejected',
      reason: 'entityId must be a non-empty string',
      row: null,
      clocks: {},
    });
    expect(rejectedResults(plan)[2]).toEqual({
      opId: '',
      status: 'rejected',
      reason: 'Op must be an object',
      row: null,
      clocks: {},
    });

    // Synthetic envelope where entity is null despite validated.ok === true falls back to 'Malformed op'.
    const synthetic: OpEnvelope = {
      rec: null,
      rawOpId: 'op-malformed',
      entity: null,
      entityId: null,
      validated: {
        ok: true,
        op: { opId: 'op-malformed', hlc: HLC, entity: 'task', entityId: 't1', op: 'delete', fields: [], row: {} },
      },
    };
    const syntheticPlan = planPushBatch({
      pusherScope: 'u:alice',
      parsedOps: [synthetic],
      context: ctx(),
    });
    expect(rejectedResults(syntheticPlan)[0]).toEqual({
      opId: 'op-malformed',
      status: 'rejected',
      reason: 'Malformed op',
      row: null,
      clocks: {},
    });
  });

  it('routes tag ops directly to pusherScope without touching entityHome or listScope', () => {
    const plan = planOps([fullTagOp('op-tag', 'urgent')], ctx(), 'u:alice');
    expect(routedScopes(plan)).toEqual(['u:alice']);
    expect(rejectedResults(plan)).toEqual([null]);
    expect(newHomes(plan).size).toBe(0);
    expect(listScopesWithIndex(plan)).toEqual([]);
  });

  it('routes projectMember and projectInvite to knownHome, project home, or pusherScope fallback', () => {
    const ops = [
      partialOp('op-pm-known', 'projectMember', 'p1:m1', { role: 'editor' }),
      partialOp('op-pm-proj', 'projectMember', 'p2:m1', { role: 'editor' }),
      partialOp('op-pm-fallback', 'projectMember', 'p-unknown:m1', { role: 'editor' }),
      partialOp('op-pi-known', 'projectInvite', 'inv-1', { projectId: 'p1' }),
      partialOp('op-pi-proj', 'projectInvite', 'inv-2', { projectId: 'p2' }),
      partialOp('op-pi-fallback', 'projectInvite', 'inv-3', {}),
    ];
    const plan = planOps(
      ops,
      ctx({
        knownHome: new Map([
          ['projectMember:p1:m1', 'u:pm-home'],
          ['projectInvite:inv-1', 'u:pi-home'],
          ['project:p2', 'u:owner'],
        ]),
      }),
      'u:alice',
    );

    expect(routedScopes(plan)).toEqual([
      'u:pm-home',
      'u:owner',
      'u:alice',
      'u:pi-home',
      'u:owner',
      'u:alice',
    ]);
    expect(newHomes(plan).size).toBe(0);
  });

  it('rejects full-upsert id collisions across scopes while allowing partial updates and same-scope resends', () => {
    const plan = planOps(
      [
        fullTaskOp('op-collide-task', 't-other', 'p1'),
        partialOp('op-partial-other', 'task', 't-other', { title: 'renamed' }),
        fullTaskOp('op-same-scope', 't-mine', 'p1'),
        fullProjectOp('op-collide-proj', 'p-other'),
      ],
      ctx({
        knownHome: new Map([
          ['task:t-other', 'u:bob'],
          ['task:t-mine', 'u:alice'],
          ['project:p-other', 'u:bob'],
        ]),
        memberships: { p1: 'editor', 'p-other': 'editor' },
      }),
      'u:alice',
    );

    expect(routedScopes(plan)).toEqual([null, 'u:bob', 'u:alice', null]);
    const results = rejectedResults(plan);
    expect(results[0]?.reason).toBe('id-in-other-scope');
    expect(results[1]).toBeNull();
    expect(results[2]).toBeNull();
    expect(results[3]?.reason).toBe('id-in-other-scope');
  });

  it('checks existing child full-upsert scope against parent task home (or pusherScope when parent unknown)', () => {
    const plan = planOps(
      [
        // Child and parent both live in u:bob -> allowed even though pusher is u:alice.
        fullChecklistOp('op-child-match', 'c-match', 't-bob'),
        // Child lives in u:carol while parent lives in u:bob -> id-in-other-scope.
        fullChecklistOp('op-child-mismatch', 'c-mismatch', 't-bob'),
        // Parent unknown, child lives in u:bob != pusherScope u:alice -> id-in-other-scope.
        fullChecklistOp('op-child-no-parent-other', 'c-orphan-bob', 't-missing'),
        // Parent unknown, child lives in pusherScope u:alice -> allowed.
        fullChecklistOp('op-child-no-parent-mine', 'c-orphan-alice', 't-missing'),
        // Parent rejected earlier in batch -> existing child inherits parent rejection.
        fullTaskOp('op-t-collide', 't-collide', 'p1'),
        fullChecklistOp('op-c-existing-under-collide', 'c-under-collide', 't-collide'),
      ],
      ctx({
        knownHome: new Map([
          ['task:t-bob', 'u:bob'],
          ['checklistItem:c-match', 'u:bob'],
          ['checklistItem:c-mismatch', 'u:carol'],
          ['checklistItem:c-orphan-bob', 'u:bob'],
          ['checklistItem:c-orphan-alice', 'u:alice'],
          ['task:t-collide', 'u:bob'],
          ['checklistItem:c-under-collide', 'u:bob'],
        ]),
        memberships: { p1: 'editor' },
      }),
      'u:alice',
    );

    expect(routedScopes(plan)).toEqual(['u:bob', null, null, 'u:alice', null, null]);
    expect(rejectedResults(plan).map((r) => r?.reason ?? null)).toEqual([
      null,
      'id-in-other-scope',
      'id-in-other-scope',
      null,
      'id-in-other-scope',
      'id-in-other-scope',
    ]);
  });

  it('handles owner project deletes including idempotent purged replay and scope check', () => {
    const plan = planOps(
      [
        deleteOp('op-active-owner', 'project', 'p-active'),
        deleteOp('op-purged-owner-replay', 'project', 'p-purged-own'),
        deleteOp('op-purged-other-scope', 'project', 'p-purged-other'),
        deleteOp('op-editor-del', 'project', 'p-editor'),
      ],
      ctx({
        knownHome: new Map([
          ['project:p-active', 'u:alice'],
          ['project:p-purged-own', 'u:alice'],
          ['project:p-purged-other', 'u:bob'],
          ['project:p-editor', 'u:bob'],
        ]),
        memberships: { 'p-active': 'owner', 'p-editor': 'editor' },
        purgedSet: new Set(['p-purged-own', 'p-purged-other']),
        removedOwnerProjects: new Set(['p-purged-own', 'p-purged-other']),
      }),
      'u:alice',
    );

    expect(plan.ops.map((o) => o.outcome)).toEqual([
      { kind: 'ownerDelete', projectId: 'p-active', homeScope: 'u:alice', opId: 'op-active-owner' },
      { kind: 'ownerDelete', projectId: 'p-purged-own', homeScope: 'u:alice', opId: 'op-purged-owner-replay' },
      { kind: 'routed', scope: 'u:bob' },
      { kind: 'routed', scope: 'u:bob' },
    ]);
  });

  it('backfills missing owner membership on knownHome project upsert and lets an in-batch task use it', () => {
    const plan = planOps(
      [
        // Partial upsert on pusher's own homed project without membership triggers owner backfill.
        partialOp('op-backfill', 'project', 'p-legacy', { name: 'Legacy' }),
        // New task into the backfilled list waives Forbidden.
        fullTaskOp('op-task-in-legacy', 't-1', 'p-legacy'),
        // Existing project where user already has membership: full upsert registers listScope, no backfill.
        fullProjectOp('op-known-member', 'p-member'),
        // Existing project partial upsert with membership: neither backfill nor listScope.
        partialOp('op-partial-member', 'project', 'p-member', { name: 'Renamed' }),
      ],
      ctx({
        knownHome: new Map([
          ['project:p-legacy', 'u:alice'],
          ['project:p-member', 'u:alice'],
        ]),
        memberships: { 'p-member': 'owner' },
      }),
      'u:alice',
    );

    expect(rejectedResults(plan)).toEqual([null, null, null, null]);
    expect(routedScopes(plan)).toEqual(['u:alice', 'u:alice', 'u:alice', 'u:alice']);
    expect([...plan.projectOwnerBackfills]).toEqual(['p-legacy']);
    expect(listScopesWithIndex(plan)).toEqual([
      { idx: 0, projectId: 'p-legacy', scope: 'u:alice' },
      { idx: 1, projectId: 'p-legacy', scope: 'u:alice' },
      { idx: 2, projectId: 'p-member', scope: 'u:alice' },
    ]);
  });

  it('registers listScope for existing task moves only when target list is writable, new, or backfilled', () => {
    const plan = planOps(
      [
        fullProjectOp('op-new-proj', 'p-new'),
        // Move existing task into the newly created list -> registered.
        partialOp('op-move-new', 'task', 't-1', { projectId: 'p-new' }),
        // Move existing task into a viewer list -> NOT registered.
        partialOp('op-move-viewer', 'task', 't-2', { projectId: 'p-view' }),
        // Edit existing task without projectId in fields -> NOT registered.
        partialOp('op-no-pid', 'task', 't-3', { title: 'just title' }),
      ],
      ctx({
        knownHome: new Map([
          ['task:t-1', 'u:alice'],
          ['task:t-2', 'u:alice'],
          ['task:t-3', 'u:alice'],
        ]),
        memberships: { 'p-view': 'viewer' },
      }),
      'u:alice',
    );

    expect(listScopesWithIndex(plan)).toEqual([
      { idx: 0, projectId: 'p-new', scope: 'u:alice' },
      { idx: 1, projectId: 'p-new', scope: 'u:alice' },
    ]);
  });

  it('rejects new invalid ops, unknown project/child deletes, partial upserts, and orphan children', () => {
    const plan = planOps([
      { opId: 'op-bad-hlc', hlc: 'bad', entity: 'task', entityId: 't-new', op: 'delete', fields: [], row: {} },
      deleteOp('op-del-new-proj', 'project', 'p-unknown'),
      partialOp('op-partial-new-task', 'task', 't-partial', { title: 'only title' }),
      deleteOp('op-del-new-child', 'checklistItem', 'c-unknown'),
      fullChecklistOp('op-orphan-child', 'c-orphan', 't-missing'),
    ]);

    expect(routedScopes(plan)).toEqual([null, null, null, null, null]);
    expect(rejectedResults(plan).map((r) => r?.reason)).toEqual([
      'Invalid hlc',
      'unknown-row',
      'unknown-row',
      'unknown-row',
      'unknown-row',
    ]);
    expect(newHomes(plan).size).toBe(0);
  });

  it('rejects new purged project and propagates purged/forbidden task rejection to in-batch children', () => {
    const plan = planOps(
      [
        fullProjectOp('op-purged-proj', 'p-gone'),
        fullTaskOp('op-task-purged', 't-purged', 'p-gone'),
        fullChecklistOp('op-child-purged', 'c-purged', 't-purged'),
        fullTaskOp('op-task-empty-pid', 't-empty', ''),
        fullChecklistOp('op-child-empty-pid', 'c-empty', 't-empty'),
      ],
      ctx({
        purgedSet: new Set(['p-gone']),
        memberships: { 'p-gone': 'owner' },
      }),
    );

    expect(routedScopes(plan)).toEqual([null, null, null, null, null]);
    expect(rejectedResults(plan).map((r) => r?.reason)).toEqual([
      'Project is purged',
      'Project is purged',
      'Project is purged',
      'Forbidden',
      'Forbidden',
    ]);
    expect(newHomes(plan).size).toBe(0);
  });

  it('binds new child of an existing foreign-scoped task to the parent scope and binds new member/folder/task-delete to pusherScope', () => {
    const plan = planOps(
      [
        fullChecklistOp('op-child-foreign', 'c-1', 't-bob'),
        fullMemberOp('op-member', 'm-1'),
        fullFolderOp('op-folder', 'f-1'),
        deleteOp('op-task-del', 'task', 't-never-seen'),
      ],
      ctx({
        knownHome: new Map([['task:t-bob', 'u:bob']]),
      }),
      'u:alice',
    );

    expect(rejectedResults(plan)).toEqual([null, null, null, null]);
    expect(routedScopes(plan)).toEqual(['u:bob', 'u:alice', 'u:alice', 'u:alice']);
    const homes = newHomes(plan);
    expect(homes.get('checklistItem:c-1')).toEqual({
      entity: 'checklistItem',
      entityId: 'c-1',
      desiredScope: 'u:bob',
      parentTaskId: 't-bob',
    });
    expect(homes.get('member:m-1')).toEqual({
      entity: 'member',
      entityId: 'm-1',
      desiredScope: 'u:alice',
    });
    expect(homes.get('folder:f-1')).toEqual({
      entity: 'folder',
      entityId: 'f-1',
      desiredScope: 'u:alice',
    });
    expect(homes.get('task:t-never-seen')).toEqual({
      entity: 'task',
      entityId: 't-never-seen',
      desiredScope: 'u:alice',
    });
    expect(listScopesWithIndex(plan)).toEqual([]);
  });

  it('plans project + task + child created in one batch without mutating input context', () => {
    const knownHome = new Map<string, string>();
    const purgedSet = new Set<string>();
    const memberships = {};
    const removedOwnerProjects = new Set<string>();
    const plan = planOps(
      [
        fullProjectOp('op-p', 'p-new'),
        fullTaskOp('op-t', 't-new', 'p-new'),
        fullChecklistOp('op-c', 'c-new', 't-new'),
      ],
      { knownHome, purgedSet, memberships, removedOwnerProjects },
      'u:alice',
    );

    expect(rejectedResults(plan)).toEqual([null, null, null]);
    expect(routedScopes(plan)).toEqual(['u:alice', 'u:alice', 'u:alice']);
    expect([...plan.inBatchNewProjects]).toEqual(['p-new']);
    expect(listScopesWithIndex(plan)).toEqual([
      { idx: 0, projectId: 'p-new', scope: 'u:alice' },
      { idx: 1, projectId: 'p-new', scope: 'u:alice' },
    ]);
    expect(newHomes(plan).get('checklistItem:c-new')).toEqual({
      entity: 'checklistItem',
      entityId: 'c-new',
      desiredScope: 'u:alice',
      parentTaskId: 't-new',
    });
    expect(knownHome.size).toBe(0);
  });

  it('list+task created in one batch relies on reconcileListScopes before dispatch', async () => {
    const observed: Array<{
      memberships: Record<string, string>;
      listScopesAtDispatch: Array<{ projectId: string; scope: string }>;
      membershipsInDbAtDispatch: Array<{ projectId: string; role: string }>;
    }> = [];

    const h = createServerHarness({
      onPush: async (input: ScopePushInput, proceed) => {
        if (input.ops.some((op) => (op as { entityId?: string }).entityId === 'p-batch')) {
          const ls = await h.db
            .select({ projectId: listScopes.projectId, scope: listScopes.scope })
            .from(listScopes)
            .where(eq(listScopes.projectId, 'p-batch'));
          const pm = await h.db
            .select({ projectId: projectMembership.projectId, role: projectMembership.role })
            .from(projectMembership)
            .where(eq(projectMembership.projectId, 'p-batch'));
          observed.push({
            memberships: { ...input.memberships },
            listScopesAtDispatch: ls,
            membershipsInDbAtDispatch: pm,
          });
        }
        return proceed(input);
      },
    });
    await seedUser(h, 'u-a', 'm-a', false);

    // Push a brand-new list and a task inside it in one batch (context.memberships starts empty).
    const res = await h.devicePush('u-a', [
      deviceOp(h, 'project', projectRow('p-batch')),
      deviceOp(h, 'task', taskRow('t-batch', 'p-batch')),
    ]);
    expect(res.results.map((r) => r.status)).toEqual(['applied', 'applied']);
    expect(observed).toHaveLength(1);
    expect(observed[0].memberships['p-batch']).toBe('owner');
    expect(observed[0].listScopesAtDispatch).toEqual([{ projectId: 'p-batch', scope: 'u:u-a' }]);
    expect(observed[0].membershipsInDbAtDispatch).toEqual([
      { projectId: 'p-batch', role: 'owner' },
    ]);

    // Proof of the coupling: if per-op listScope entries are cleared, reconcileListScopes
    // short-circuits without refreshing memberships from D1 before dispatch, so the DO rejects both ops.
    const h2 = createServerHarness();
    await seedUser(h2, 'u-a', 'm-a', false);
    const ops = [
      deviceOp(h2, 'project', projectRow('p-skip')),
      deviceOp(h2, 'task', taskRow('t-skip', 'p-skip')),
    ];
    const parsed = collectPushLookups(ops.map(toEnvelope));
    const context = await loadPushContext(h2.db, {
      userId: 'u-a',
      lookupPairs: parsed.lookupPairs,
      projectIdsToCheck: parsed.projectIdsToCheck,
    });
    const plan = planPushBatch({ pusherScope: 'u:u-a', parsedOps: parsed.ops, context });
    expect(plan.ops.map((o) => o.listScope?.projectId)).toEqual(['p-skip', 'p-skip']);

    const outcome = await applyPushPlan(h2.db, {
      userId: 'u-a',
      deviceId: 'dev-a',
      pusherScope: 'u:u-a',
      nowMs: 1_700_000_000_000,
      context,
      plan: {
        ...plan,
        ops: plan.ops.map((o) => ({ ...o, listScope: undefined })),
      },
      getScopeStub: h2.getScopeStub,
    });
    expect(outcome.results.map((r) => ({ status: r.status, reason: r.reason }))).toEqual([
      { status: 'rejected', reason: 'Forbidden' },
      { status: 'rejected', reason: 'Forbidden' },
    ]);
  });

  it('segments dispatch around owner project delete so earlier edits run before purge and later edits see purged state', async () => {
    const h = createServerHarness();
    await seedUser(h, 'u-a', 'm-a', false);

    // Seed project + task in a prior push.
    const setup = await h.devicePush('u-a', [
      deviceOp(h, 'project', projectRow('p-seg')),
      deviceOp(h, 'task', taskRow('t-seg', 'p-seg', { title: 'initial' })),
    ]);
    expect(setup.results.map((r) => r.status)).toEqual(['applied', 'applied']);

    // One batch: edit before delete -> owner project delete -> edit after delete.
    const res = await h.devicePush('u-a', [
      { ...deviceOp(h, 'task', { id: 't-seg', title: 'before-purge' }), fields: ['title'] },
      { opId: 'op-seg-del', hlc: h.deviceHlc(), entity: 'project', entityId: 'p-seg', op: 'delete', fields: [], row: {} },
      { ...deviceOp(h, 'task', { id: 't-seg', title: 'after-purge' }), fields: ['title'] },
    ]);

    expect(res.results.map((r) => ({ status: r.status, reason: r.reason }))).toEqual([
      { status: 'applied', reason: undefined },
      { status: 'applied', reason: undefined },
      { status: 'rejected', reason: 'Project is purged' },
    ]);
    expect(res.results[0].row?.title).toBe('before-purge');
  });
});

describe('newRowPreconditionDenial', () => {
  function validatedOf(raw: unknown) {
    const env = toEnvelope(raw);
    if (!env.validated.ok) throw new Error(`Expected valid op: ${env.validated.reason}`);
    return env.validated.op;
  }

  it('enforces required fields, child delete, child parent, and optional project delete rules', () => {
    const projDel = validatedOf(deleteOp('op-1', 'project', 'p1'));
    expect(newRowPreconditionDenial(projDel, { rejectUnknownProjectDelete: true })).toBe(
      'unknown-row',
    );
    expect(newRowPreconditionDenial(projDel)).toBeNull();

    const partialTask = validatedOf(partialOp('op-2', 'task', 't1', { title: 'only' }));
    expect(newRowPreconditionDenial(partialTask)).toBe('unknown-row');

    const childDel = validatedOf(deleteOp('op-3', 'checklistItem', 'c1'));
    expect(newRowPreconditionDenial(childDel)).toBe('unknown-row');

    const childUpsert = validatedOf(fullChecklistOp('op-4', 'c1', 't1'));
    expect(newRowPreconditionDenial(childUpsert, { checkParentTask: () => ({ ok: false }) })).toBe(
      'unknown-row',
    );
    expect(
      newRowPreconditionDenial(childUpsert, {
        checkParentTask: () => ({ ok: false, reason: 'Forbidden' }),
      }),
    ).toBe('Forbidden');
    expect(newRowPreconditionDenial(childUpsert, { checkParentTask: () => ({ ok: true }) })).toBeNull();

    const childEmptyParent = validatedOf(fullChecklistOp('op-5', 'c2', ''));
    expect(
      newRowPreconditionDenial(childEmptyParent, { checkParentTask: () => ({ ok: true }) }),
    ).toBe('unknown-row');

    const taskDel = validatedOf(deleteOp('op-6', 'task', 't-new'));
    expect(newRowPreconditionDenial(taskDel, { rejectUnknownProjectDelete: true })).toBeNull();
  });
});
