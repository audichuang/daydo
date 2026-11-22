import { entityHome, user } from '@schema';
import { and, eq, isNull, or, type BatchItem } from 'void/db';
import { deleteTaskAttachmentObjects } from '../../attachments/r2';
import type { PushOpResult, ScopePushResponse, ScopeStub } from '../../scope/api';
import {
  activeForUser,
  claimOwner,
  collectProjectIds,
  decodeActiveRoles,
  purgedAmong,
  purgeProject,
  registerListScope,
} from '../../membership';
import type { EntityName, MembershipRole } from '../entities';
import type { AppDb } from '../push';
import { REJECT_REASON, rejectedResult } from '../rejectReason';
import { scopeOwnerId } from '../scopeName';
import {
  chunkArray,
  PAIR_CHUNK_SIZE,
  QUERY_CHUNK_SIZE,
  type PushContext,
} from './context';
import { entityHomeKey } from './parse';
import type { ListScopeTarget, NewEntityHomeEntry, PlannedPushOp, PushPlan } from './plan';

interface ExecutionOp extends PlannedPushOp {
  result: PushOpResult | null;
}

interface ScopeResponseEntry {
  scope: string;
  group: ExecutionOp[];
  response: ScopePushResponse;
}

export interface ApplyPushPlanParams {
  userId: string;
  deviceId: string;
  pusherScope: string;
  nowMs: number;
  context: PushContext;
  plan: PushPlan;
  getScopeStub: (scope: string) => ScopeStub;
  storage?: R2Bucket | null;
}

export interface AppliedPushOutcome {
  results: PushOpResult[];
  scopeServerTimes: string[];
}

/**
 * D1 Batch 2: binds new entityHome ids and new project owner memberships,
 * rejects ops lost to a concurrent scope race, and cleans up orphaned child bindings.
 */
async function bindEntityHomes(
  db: AppDb,
  params: {
    userId: string;
    pusherScope: string;
    nowMs: number;
    ops: ExecutionOp[];
    inBatchNewProjects: Set<string>;
  },
): Promise<void> {
  const { userId, pusherScope, nowMs, ops, inBatchNewProjects } = params;

  const inBatchNewHome = new Map<string, NewEntityHomeEntry>();
  for (const entry of ops) {
    if (entry.newHome) {
      inBatchNewHome.set(entityHomeKey(entry.newHome.entity, entry.newHome.entityId), entry.newHome);
    }
  }
  if (inBatchNewHome.size === 0) return;

  const entries = Array.from(inBatchNewHome.values());
  const batch2Stmts: BatchItem<'sqlite'>[] = [];
  for (const chunk of chunkArray(entries, 25)) {
    batch2Stmts.push(
      db
        .insert(entityHome)
        .values(
          chunk.map((e) => ({
            entity: e.entity,
            entityId: e.entityId,
            scope: e.desiredScope,
          })),
        )
        .onConflictDoNothing()
        .returning({ entity: entityHome.entity, entityId: entityHome.entityId }),
    );
  }

  const selectStartIdx = batch2Stmts.length;
  const selectChunks = chunkArray(entries, PAIR_CHUNK_SIZE);
  for (const chunk of selectChunks) {
    batch2Stmts.push(
      db
        .select({
          entity: entityHome.entity,
          entityId: entityHome.entityId,
          scope: entityHome.scope,
        })
        .from(entityHome)
        .where(
          or(
            ...chunk.map((e) =>
              and(eq(entityHome.entity, e.entity), eq(entityHome.entityId, e.entityId)),
            ),
          ),
        ),
    );
  }
  const selectEndIdx = batch2Stmts.length;

  for (const pid of inBatchNewProjects) {
    batch2Stmts.push(claimOwner(db, { projectId: pid, userId, pusherScope, nowMs }));
  }

  const batch2Results = (await db.batch(
    batch2Stmts as [BatchItem<'sqlite'>, ...BatchItem<'sqlite'>[]],
  )) as Array<Array<Record<string, unknown>>>;

  const newlyWonKeys = new Set<string>();
  for (let s = 0; s < selectStartIdx; s += 1) {
    for (const row of batch2Results[s]) {
      newlyWonKeys.add(`${String(row.entity)}:${String(row.entityId)}`);
    }
  }

  const boundMap = new Map<string, string>();
  for (let s = selectStartIdx; s < selectEndIdx; s += 1) {
    for (const row of batch2Results[s]) {
      boundMap.set(`${String(row.entity)}:${String(row.entityId)}`, String(row.scope));
    }
  }

  const mismatchKeys = new Set<string>();
  const mismatchTaskIds = new Set<string>();
  for (const [key, entry] of inBatchNewHome) {
    if (boundMap.get(key) !== entry.desiredScope) {
      mismatchKeys.add(key);
      if (entry.entity === 'task') {
        mismatchTaskIds.add(entry.entityId);
      }
    }
  }

  const orphanCleanupKeys: Array<{ entity: EntityName; entityId: string }> = [];
  for (const entry of ops) {
    const { rawOpId, entity, entityId } = entry.parsed;
    if (!entity || !entityId || entry.outcome.kind !== 'routed') continue;
    const key = entityHomeKey(entity, entityId);
    const newEntry = inBatchNewHome.get(key);
    if (mismatchKeys.has(key)) {
      const result = rejectedResult(rawOpId, REJECT_REASON.ID_IN_OTHER_SCOPE);
      entry.outcome = { kind: 'rejected', result };
      entry.result = result;
      if (entity === 'project') {
        inBatchNewProjects.delete(entityId);
      }
    } else if (newEntry?.parentTaskId && mismatchTaskIds.has(newEntry.parentTaskId)) {
      const result = rejectedResult(rawOpId, REJECT_REASON.ID_IN_OTHER_SCOPE);
      entry.outcome = { kind: 'rejected', result };
      entry.result = result;
      if (newlyWonKeys.has(key)) {
        newlyWonKeys.delete(key);
        orphanCleanupKeys.push({ entity, entityId });
      }
    }
  }

  if (orphanCleanupKeys.length > 0) {
    const cleanupStmts: BatchItem<'sqlite'>[] = [];
    for (const chunk of chunkArray(orphanCleanupKeys, PAIR_CHUNK_SIZE)) {
      cleanupStmts.push(
        db
          .delete(entityHome)
          .where(
            or(
              ...chunk.map((k) =>
                and(eq(entityHome.entity, k.entity), eq(entityHome.entityId, k.entityId)),
              ),
            ),
          ),
      );
    }
    await db.batch(cleanupStmts as [BatchItem<'sqlite'>, ...BatchItem<'sqlite'>[]]);
  }
}

/**
 * D1 Batch 3: backfills missing owner memberships on knownHome resend, inserts
 * conditional listScopes entries, and refreshes purgedProject and active memberships.
 */
async function reconcileListScopes(
  db: AppDb,
  params: {
    userId: string;
    pusherScope: string;
    nowMs: number;
    projectOwnerBackfills: ReadonlySet<string>;
    ops: readonly ExecutionOp[];
    purgedSet: Set<string>;
  },
): Promise<Record<string, MembershipRole> | null> {
  const { userId, pusherScope, nowMs, projectOwnerBackfills, ops, purgedSet } = params;

  const activeListTargets: ListScopeTarget[] = [];
  for (const entry of ops) {
    if (entry.outcome.kind === 'routed' && entry.listScope) {
      activeListTargets.push(entry.listScope);
    }
  }
  if (projectOwnerBackfills.size === 0 && activeListTargets.length === 0) {
    return null;
  }

  const batch3Stmts: BatchItem<'sqlite'>[] = [];
  for (const pid of projectOwnerBackfills) {
    batch3Stmts.push(claimOwner(db, { projectId: pid, userId, pusherScope, nowMs }));
  }

  const seenListScope = new Set<string>();
  const listProjectsToRead = new Set<string>();
  for (const target of activeListTargets) {
    listProjectsToRead.add(target.projectId);
    const lsKey = `${target.projectId}:${target.scope}`;
    if (seenListScope.has(lsKey)) continue;
    seenListScope.add(lsKey);
    batch3Stmts.push(
      registerListScope(db, { projectId: target.projectId, scope: target.scope, userId }),
    );
  }

  const purgedReadChunks = chunkArray(Array.from(listProjectsToRead), QUERY_CHUNK_SIZE);
  const purgedStartIdx = batch3Stmts.length;
  for (const chunk of purgedReadChunks) {
    batch3Stmts.push(purgedAmong(db, chunk));
  }

  const membershipReadIdx = batch3Stmts.length;
  batch3Stmts.push(activeForUser(db, userId));

  const batch3Results = (await db.batch(
    batch3Stmts as [BatchItem<'sqlite'>, ...BatchItem<'sqlite'>[]],
  )) as Array<Array<Record<string, unknown>>>;

  for (let s = purgedStartIdx; s < membershipReadIdx; s += 1) {
    collectProjectIds(batch3Results[s], purgedSet);
  }

  return decodeActiveRoles(batch3Results[membershipReadIdx] ?? []);
}

/**
 * Executes ops in original batch order by flushing scope-grouped segments between
 * owner project deletes so earlier edits run before purge and later ops see purged state.
 */
async function dispatchScopeBatches(
  db: AppDb,
  params: {
    userId: string;
    deviceId: string;
    pusherScope: string;
    nowMs: number;
    ops: ExecutionOp[];
    purgedSet: Set<string>;
    memberships: Record<string, MembershipRole>;
    meMemberId: string | null;
    getScopeStub: (scope: string) => ScopeStub;
  },
): Promise<{
  scopeResponses: ScopeResponseEntry[];
  extraServerTimes: string[];
  boundMeMemberId: string | null;
}> {
  const {
    userId,
    deviceId,
    pusherScope,
    nowMs,
    ops,
    purgedSet,
    memberships,
    meMemberId,
    getScopeStub,
  } = params;

  const extraServerTimes: string[] = [];
  const scopeResponses: ScopeResponseEntry[] = [];
  let boundMeMemberId: string | null = null;

  const pushSegment = async (segment: readonly ExecutionOp[]): Promise<void> => {
    const scopeGroups = new Map<string, ExecutionOp[]>();
    for (const entry of segment) {
      if (entry.outcome.kind !== 'routed') continue;
      const scope = entry.outcome.scope;
      let group = scopeGroups.get(scope);
      if (!group) {
        group = [];
        scopeGroups.set(scope, group);
      }
      group.push(entry);
    }
    if (scopeGroups.size === 0) return;

    const purgedList = Array.from(purgedSet);
    const membershipsSnapshot = { ...memberships };
    const currentMeMemberId = boundMeMemberId ?? meMemberId;
    const groupEntries = Array.from(scopeGroups.entries());
    const segmentResponses = await Promise.all(
      groupEntries.map(async ([scope, group]) => {
        const scopeUserId = scopeOwnerId(scope);
        const stub = getScopeStub(scope);
        const response = await stub.push({
          scope,
          scopeUserId,
          pusherUserId: userId,
          deviceId,
          memberships: membershipsSnapshot,
          purgedProjects: purgedList,
          meMemberId: scope === pusherScope ? currentMeMemberId : null,
          ops: group.map((g) => g.parsed.rec),
          validated: group.map((g) => g.parsed.validated),
        });
        return { scope, group, response };
      }),
    );

    for (const entry of segmentResponses) {
      scopeResponses.push(entry);
      for (let j = 0; j < entry.group.length; j += 1) {
        entry.group[j].result = entry.response.results[j];
      }
      if (entry.scope === pusherScope && entry.response.boundMeMemberId) {
        boundMeMemberId = entry.response.boundMeMemberId;
      }
    }
  };

  let pendingSegment: ExecutionOp[] = [];
  for (const entry of ops) {
    if (entry.outcome.kind !== 'ownerDelete') {
      pendingSegment.push(entry);
      continue;
    }

    await pushSegment(pendingSegment);
    pendingSegment = [];

    const del = entry.outcome;
    const homeResult = await purgeProject(db, {
      projectId: del.projectId,
      homeScope: del.homeScope,
      opId: del.opId,
      pusherUserId: userId,
      purgedAt: nowMs,
      getScopeStub,
    });

    purgedSet.add(del.projectId);
    delete memberships[del.projectId];
    extraServerTimes.push(homeResult.serverTime);
    entry.result = {
      opId: del.opId,
      status: 'applied',
      row: homeResult.purgedRow,
      clocks: homeResult.clocks,
    };
  }
  await pushSegment(pendingSegment);

  return { scopeResponses, extraServerTimes, boundMeMemberId };
}

async function syncPusherProfile(
  db: AppDb,
  params: {
    userId: string;
    pusherScope: string;
    meMemberId: string | null;
    boundMeMemberId: string | null;
    scopeResponses: readonly ScopeResponseEntry[];
  },
): Promise<void> {
  const { userId, pusherScope, meMemberId, boundMeMemberId, scopeResponses } = params;
  const effectiveMeMemberId = boundMeMemberId ?? meMemberId;
  let profileUpdate: { name: string | null; initial: string | null; color: string | null } | null =
    null;

  if (effectiveMeMemberId !== null) {
    for (const { scope, group, response } of scopeResponses) {
      if (scope !== pusherScope) continue;
      for (let j = 0; j < group.length; j += 1) {
        const res = response.results[j];
        const opObj = group[j].parsed.rec;
        if (
          res.status === 'applied' &&
          res.row &&
          opObj &&
          opObj.entity === 'member' &&
          opObj.entityId === effectiveMeMemberId &&
          opObj.op === 'upsert'
        ) {
          profileUpdate = {
            name: typeof res.row.name === 'string' ? res.row.name : null,
            initial: typeof res.row.initial === 'string' ? res.row.initial : null,
            color: typeof res.row.color === 'string' ? res.row.color : null,
          };
        }
      }
    }
  }

  if (boundMeMemberId !== null) {
    await db
      .update(user)
      .set({ meMemberId: boundMeMemberId, ...profileUpdate })
      .where(and(eq(user.id, userId), isNull(user.meMemberId)));
  } else if (profileUpdate !== null && effectiveMeMemberId !== null) {
    await db
      .update(user)
      .set(profileUpdate)
      .where(and(eq(user.id, userId), eq(user.meMemberId, effectiveMeMemberId)));
  }
}

/**
 * Executes a planned sync push batch across D1 (entityHome bindings, listScopes,
 * memberships, project purges, user profile) and the target Scope Durable Objects.
 */
export async function applyPushPlan(
  db: AppDb,
  params: ApplyPushPlanParams,
): Promise<AppliedPushOutcome> {
  const { userId, deviceId, pusherScope, nowMs, context, plan, getScopeStub, storage } = params;

  const ops: ExecutionOp[] = plan.ops.map((op) => ({
    ...op,
    result: op.outcome.kind === 'rejected' ? op.outcome.result : null,
  }));
  const inBatchNewProjects = new Set(plan.inBatchNewProjects);
  const purgedSet = new Set(context.purgedSet);
  let memberships: Record<string, MembershipRole> = { ...context.memberships };

  await bindEntityHomes(db, {
    userId,
    pusherScope,
    nowMs,
    ops,
    inBatchNewProjects,
  });

  // Ordering invariant: reconcileListScopes must run after bindEntityHomes (which inserts
  // claimOwner for new lists) and before dispatchScopeBatches so tasks targeting lists created
  // or owner-backfilled earlier in this batch see the refreshed owner membership at the Scope DO.
  const refreshedMemberships = await reconcileListScopes(db, {
    userId,
    pusherScope,
    nowMs,
    projectOwnerBackfills: plan.projectOwnerBackfills,
    ops,
    purgedSet,
  });
  if (refreshedMemberships !== null) {
    memberships = refreshedMemberships;
  }

  const { scopeResponses, extraServerTimes, boundMeMemberId } = await dispatchScopeBatches(db, {
    userId,
    deviceId,
    pusherScope,
    nowMs,
    ops,
    purgedSet,
    memberships,
    meMemberId: context.meMemberId,
    getScopeStub,
  });

  await syncPusherProfile(db, {
    userId,
    pusherScope,
    meMemberId: context.meMemberId,
    boundMeMemberId,
    scopeResponses,
  });

  if (storage) {
    const purgedTaskIds = new Set<string>();
    for (const entry of ops) {
      const { validated } = entry.parsed;
      if (
        validated.ok &&
        validated.op.entity === 'task' &&
        validated.op.op === 'delete' &&
        entry.result?.status === 'applied'
      ) {
        purgedTaskIds.add(validated.op.entityId);
      }
    }
    if (purgedTaskIds.size > 0) {
      await Promise.all(
        Array.from(purgedTaskIds, (taskId) => deleteTaskAttachmentObjects(storage, taskId)),
      );
    }
  }

  return {
    results: ops.map((entry) => entry.result!),
    scopeServerTimes: [
      ...extraServerTimes,
      ...scopeResponses.map((r) => r.response.serverTime),
    ],
  };
}
