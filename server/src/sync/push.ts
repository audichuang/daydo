import { entityHome, listScopes, projectMembership, purgedProject, user } from '@schema';
import { and, eq, inArray, isNull, or, sql, type BatchItem } from 'void/db';
import type * as schema from '@schema';
import type { DrizzleD1Database } from 'void/db';
import type {
  PushOpResult,
  ScopeProjectInfo,
  ScopeProjectMemberInput,
  ScopePullInput,
  ScopePullResponse,
  ScopePurgeProjectInput,
  ScopePurgeProjectResponse,
  ScopePushInput,
  ScopePushResponse,
} from '../../durable-objects/scope';
import {
  hasAllRequiredFields,
  isEntityName,
  isTaskChildEntity,
  parseEntityId,
  validateSyncOp,
  type EntityName,
  type MembershipRole,
} from './entities';
import { advanceServerHlc, type ServerHlcClock } from './hlc';

export type AppDb = DrizzleD1Database<typeof schema>;

export interface ScopeStub {
  push(input: ScopePushInput): Promise<ScopePushResponse>;
  pull(input: ScopePullInput): Promise<ScopePullResponse>;
  getInboxProjectId(input: { readableProjectIds: string[] }): Promise<string | null>;
  getProjectInfo(input: { projectId: string }): Promise<ScopeProjectInfo | null>;
  projectMember(input: ScopeProjectMemberInput): Promise<void>;
  purgeProject(input: ScopePurgeProjectInput): Promise<ScopePurgeProjectResponse>;
}

const QUERY_CHUNK_SIZE = 50;
const PAIR_CHUNK_SIZE = 25;

export function chunkArray<T>(items: readonly T[], size = QUERY_CHUNK_SIZE): T[][] {
  const chunks: T[][] = [];
  for (let i = 0; i < items.length; i += size) {
    chunks.push(items.slice(i, i + size));
  }
  return chunks;
}

function entityHomeKey(entity: EntityName, entityId: string): string {
  return `${entity}:${entityId}`;
}

export async function executeSyncPush(
  db: AppDb,
  params: {
    userId: string;
    deviceId: string;
    ops: unknown[];
    getScopeStub: (scope: string) => ScopeStub;
    clock?: ServerHlcClock;
  },
): Promise<{
  results: PushOpResult[];
  /** Server HLC string (`<13-digit ms>:<4-digit counter>:server`). */
  serverTime: string;
}> {
  const { userId, deviceId, ops, getScopeStub, clock } = params;
  const nowMs = Date.now();
  const pusherScope = `u:${userId}`;
  const nextServerTime = (timeMs: number, observed: string[] = []): string =>
    clock ? clock.tick(timeMs, observed) : advanceServerHlc(timeMs, observed).formatted;

  if (ops.length === 0) {
    return { results: [], serverTime: nextServerTime(nowMs) };
  }

  const results: Array<PushOpResult | null> = new Array(ops.length).fill(null);

  // Pre-scan ops to collect D1 lookup keys.
  const lookupPairsMap = new Map<string, { entity: EntityName; entityId: string }>();
  const projectIdsToCheck = new Set<string>();

  const parsedOps = ops.map((raw) => {
    const rec =
      raw && typeof raw === 'object' && !Array.isArray(raw)
        ? (raw as Record<string, unknown>)
        : null;
    const rawOpId = rec && typeof rec.opId === 'string' ? rec.opId : '';
    const entity = rec && isEntityName(rec.entity) ? rec.entity : null;
    const entityId =
      entity && rec && typeof rec.entityId === 'string' && parseEntityId(entity, rec.entityId)
        ? rec.entityId
        : null;
    const validated = validateSyncOp(raw);

    if (entity && entityId && entity !== 'tag') {
      lookupPairsMap.set(entityHomeKey(entity, entityId), { entity, entityId });
      if (
        isTaskChildEntity(entity) &&
        rec?.row &&
        typeof rec.row === 'object' &&
        !Array.isArray(rec.row) &&
        Object.hasOwn(rec.row, 'taskId')
      ) {
        const taskId = (rec.row as Record<string, unknown>).taskId;
        if (typeof taskId === 'string' && taskId.length > 0) {
          lookupPairsMap.set(entityHomeKey('task', taskId), { entity: 'task', entityId: taskId });
        }
      }
      if (entity === 'projectMember') {
        const pm = parseEntityId('projectMember', entityId);
        if (pm) {
          lookupPairsMap.set(entityHomeKey('project', pm.projectId), {
            entity: 'project',
            entityId: pm.projectId,
          });
        }
      } else if (
        entity === 'projectInvite' &&
        rec?.row &&
        typeof rec.row === 'object' &&
        !Array.isArray(rec.row) &&
        Object.hasOwn(rec.row, 'projectId')
      ) {
        const pid = (rec.row as Record<string, unknown>).projectId;
        if (typeof pid === 'string' && pid.length > 0) {
          lookupPairsMap.set(entityHomeKey('project', pid), { entity: 'project', entityId: pid });
        }
      }
    }

    if (validated.ok) {
      if (validated.op.entity === 'project') {
        projectIdsToCheck.add(validated.op.entityId);
      } else if (
        validated.op.op === 'upsert' &&
        validated.op.entity === 'task' &&
        validated.op.fields.includes('projectId') &&
        Object.hasOwn(validated.op.row, 'projectId') &&
        typeof validated.op.row.projectId === 'string' &&
        validated.op.row.projectId.length > 0
      ) {
        projectIdsToCheck.add(validated.op.row.projectId);
      }
    }

    return { raw, rec, rawOpId, entity, entityId, validated };
  });

  // D1 Batch 1: read existing entityHome rows, purgedProject, user.meMemberId, and memberships.
  const batch1Queries: BatchItem<'sqlite'>[] = [];
  const homeChunks = chunkArray(Array.from(lookupPairsMap.values()), PAIR_CHUNK_SIZE);
  for (const chunk of homeChunks) {
    batch1Queries.push(
      db
        .select({
          entity: entityHome.entity,
          entityId: entityHome.entityId,
          scope: entityHome.scope,
        })
        .from(entityHome)
        .where(
          or(
            ...chunk.map((p) =>
              and(eq(entityHome.entity, p.entity), eq(entityHome.entityId, p.entityId)),
            ),
          ),
        ),
    );
  }
  const purgedChunks = chunkArray(Array.from(projectIdsToCheck), QUERY_CHUNK_SIZE);
  for (const chunk of purgedChunks) {
    batch1Queries.push(
      db
        .select({ projectId: purgedProject.projectId })
        .from(purgedProject)
        .where(inArray(purgedProject.projectId, chunk)),
    );
  }
  const userQueryIdx = batch1Queries.length;
  batch1Queries.push(
    db.select({ meMemberId: user.meMemberId }).from(user).where(eq(user.id, userId)),
  );
  const membershipQueryIdx = batch1Queries.length;
  batch1Queries.push(
    db
      .select({
        projectId: projectMembership.projectId,
        role: projectMembership.role,
        removedAt: projectMembership.removedAt,
      })
      .from(projectMembership)
      .where(eq(projectMembership.userId, userId)),
  );

  const batch1Results = (await db.batch(
    batch1Queries as [BatchItem<'sqlite'>, ...BatchItem<'sqlite'>[]],
  )) as Array<Array<Record<string, unknown>>>;

  const knownHome = new Map<string, string>();
  let cursorIdx = 0;
  for (let i = 0; i < homeChunks.length; i += 1) {
    for (const row of batch1Results[cursorIdx++]) {
      knownHome.set(`${String(row.entity)}:${String(row.entityId)}`, String(row.scope));
    }
  }
  const purgedSet = new Set<string>();
  for (let i = 0; i < purgedChunks.length; i += 1) {
    for (const row of batch1Results[cursorIdx++]) {
      purgedSet.add(String(row.projectId));
    }
  }
  const userRow = batch1Results[userQueryIdx]?.[0];
  const meMemberId =
    userRow && typeof userRow.meMemberId === 'string' ? userRow.meMemberId : null;

  let memberships: Record<string, MembershipRole> = {};
  const removedOwnerProjects = new Set<string>();
  for (const row of batch1Results[membershipQueryIdx] ?? []) {
    const role = row.role;
    if (row.removedAt === null || row.removedAt === undefined) {
      if (role === 'owner' || role === 'editor' || role === 'viewer') {
        memberships[String(row.projectId)] = role;
      }
    } else if (role === 'owner') {
      removedOwnerProjects.add(String(row.projectId));
    }
  }

  // Planning pass in op order.
  const inBatchNewHome = new Map<
    string,
    { entity: EntityName; entityId: string; desiredScope: string; parentTaskId?: string }
  >();
  const inBatchRejectedTasks = new Map<string, string>();
  const inBatchNewProjects = new Set<string>();
  const projectOwnerBackfills = new Set<string>();
  const ownerProjectDeletes: Array<{
    opIndex: number;
    projectId: string;
    homeScope: string;
    opId: string;
  }> = [];
  const listScopeTargets: Array<{ opIndex: number; projectId: string; scope: string }> = [];
  const opTargetScope: Array<string | null> = new Array(ops.length).fill(null);

  for (let i = 0; i < parsedOps.length; i += 1) {
    const { rec, rawOpId, entity, entityId, validated } = parsedOps[i];
    if (!entity || !entityId) {
      results[i] = {
        opId: rawOpId,
        status: 'rejected',
        reason: validated.ok ? 'Malformed op' : validated.reason,
        row: null,
        clocks: {},
      };
      continue;
    }

    const key = entityHomeKey(entity, entityId);

    if (entity === 'tag') {
      opTargetScope[i] = pusherScope;
      continue;
    }

    if (entity === 'projectMember' || entity === 'projectInvite') {
      if (knownHome.has(key)) {
        opTargetScope[i] = knownHome.get(key)!;
      } else if (entity === 'projectMember') {
        const pm = parseEntityId('projectMember', entityId)!;
        opTargetScope[i] = knownHome.get(entityHomeKey('project', pm.projectId)) ?? pusherScope;
      } else {
        const pid =
          rec?.row &&
          typeof rec.row === 'object' &&
          !Array.isArray(rec.row) &&
          typeof (rec.row as Record<string, unknown>).projectId === 'string'
            ? ((rec.row as Record<string, unknown>).projectId as string)
            : '';
        opTargetScope[i] =
          (pid && knownHome.get(entityHomeKey('project', pid))) || pusherScope;
      }
      continue;
    }

    if (knownHome.has(key)) {
      const targetScope = knownHome.get(key)!;
      if (
        validated.ok &&
        validated.op.op === 'upsert' &&
        hasAllRequiredFields(entity, validated.op.fields)
      ) {
        if (isTaskChildEntity(entity)) {
          const taskId =
            Object.hasOwn(validated.op.row, 'taskId') &&
            typeof validated.op.row.taskId === 'string'
              ? validated.op.row.taskId
              : '';
          const parentRejectReason = taskId ? inBatchRejectedTasks.get(taskId) : undefined;
          if (parentRejectReason) {
            results[i] = {
              opId: validated.op.opId,
              status: 'rejected',
              reason: parentRejectReason,
              row: null,
              clocks: {},
            };
            continue;
          }
          const taskHome = taskId ? knownHome.get(entityHomeKey('task', taskId)) : undefined;
          if (taskHome ? targetScope !== taskHome : targetScope !== pusherScope) {
            results[i] = {
              opId: validated.op.opId,
              status: 'rejected',
              reason: 'id-in-other-scope',
              row: null,
              clocks: {},
            };
            continue;
          }
        } else if (targetScope !== pusherScope) {
          if (entity === 'task') {
            inBatchRejectedTasks.set(entityId, 'id-in-other-scope');
          }
          results[i] = {
            opId: validated.op.opId,
            status: 'rejected',
            reason: 'id-in-other-scope',
            row: null,
            clocks: {},
          };
          continue;
        }
      }

      if (
        entity === 'project' &&
        validated.ok &&
        validated.op.op === 'delete' &&
        ((memberships[entityId] === 'owner' && !purgedSet.has(entityId)) ||
          (purgedSet.has(entityId) &&
            removedOwnerProjects.has(entityId) &&
            targetScope === pusherScope))
      ) {
        ownerProjectDeletes.push({
          opIndex: i,
          projectId: entityId,
          homeScope: targetScope,
          opId: validated.op.opId,
        });
        continue;
      }

      opTargetScope[i] = targetScope;
      if (entity === 'project' && validated.ok && validated.op.op === 'upsert') {
        if (targetScope === pusherScope && !memberships[entityId] && !purgedSet.has(entityId)) {
          projectOwnerBackfills.add(entityId);
          listScopeTargets.push({ opIndex: i, projectId: entityId, scope: targetScope });
        } else if (hasAllRequiredFields('project', validated.op.fields)) {
          listScopeTargets.push({ opIndex: i, projectId: entityId, scope: targetScope });
        }
      } else if (
        entity === 'task' &&
        validated.ok &&
        validated.op.op === 'upsert' &&
        validated.op.fields.includes('projectId') &&
        Object.hasOwn(validated.op.row, 'projectId') &&
        typeof validated.op.row.projectId === 'string' &&
        validated.op.row.projectId.length > 0
      ) {
        const targetPid = validated.op.row.projectId;
        const targetRole = memberships[targetPid];
        if (
          targetRole === 'owner' ||
          targetRole === 'editor' ||
          inBatchNewProjects.has(targetPid) ||
          projectOwnerBackfills.has(targetPid)
        ) {
          listScopeTargets.push({
            opIndex: i,
            projectId: targetPid,
            scope: targetScope,
          });
        }
      }
      continue;
    }

    // New entity id (not yet in entityHome)
    if (!validated.ok) {
      results[i] = {
        opId: validated.opId,
        status: 'rejected',
        reason: validated.reason,
        row: null,
        clocks: {},
      };
      continue;
    }

    const op = validated.op;
    if (op.entity === 'project' && op.op === 'delete') {
      results[i] = {
        opId: op.opId,
        status: 'rejected',
        reason: 'unknown-row',
        row: null,
        clocks: {},
      };
      continue;
    }

    if (op.op === 'upsert' && !hasAllRequiredFields(op.entity, op.fields)) {
      results[i] = {
        opId: op.opId,
        status: 'rejected',
        reason: 'unknown-row',
        row: null,
        clocks: {},
      };
      continue;
    }

    if (isTaskChildEntity(op.entity)) {
      if (op.op === 'delete') {
        results[i] = {
          opId: op.opId,
          status: 'rejected',
          reason: 'unknown-row',
          row: null,
          clocks: {},
        };
        continue;
      }
      const taskId =
        Object.hasOwn(op.row, 'taskId') && typeof op.row.taskId === 'string' ? op.row.taskId : '';
      const parentRejectReason = taskId ? inBatchRejectedTasks.get(taskId) : undefined;
      if (parentRejectReason) {
        results[i] = {
          opId: op.opId,
          status: 'rejected',
          reason: parentRejectReason,
          row: null,
          clocks: {},
        };
        continue;
      }
      const parentScope = taskId ? knownHome.get(entityHomeKey('task', taskId)) : undefined;
      if (!parentScope) {
        results[i] = {
          opId: op.opId,
          status: 'rejected',
          reason: 'unknown-row',
          row: null,
          clocks: {},
        };
        continue;
      }
      knownHome.set(key, parentScope);
      inBatchNewHome.set(key, {
        entity: op.entity,
        entityId: op.entityId,
        desiredScope: parentScope,
        parentTaskId: taskId,
      });
      opTargetScope[i] = parentScope;
      continue;
    }

    // New top-level entity: project, task, member, folder
    if (op.entity === 'project' && purgedSet.has(op.entityId)) {
      results[i] = {
        opId: op.opId,
        status: 'rejected',
        reason: 'Project is purged',
        row: null,
        clocks: {},
      };
      continue;
    }
    if (
      op.entity === 'task' &&
      op.op === 'upsert' &&
      Object.hasOwn(op.row, 'projectId') &&
      typeof op.row.projectId === 'string' &&
      purgedSet.has(op.row.projectId)
    ) {
      inBatchRejectedTasks.set(op.entityId, 'Project is purged');
      results[i] = {
        opId: op.opId,
        status: 'rejected',
        reason: 'Project is purged',
        row: null,
        clocks: {},
      };
      continue;
    }
    if (op.entity === 'task' && op.op === 'upsert') {
      const targetPid =
        Object.hasOwn(op.row, 'projectId') && typeof op.row.projectId === 'string'
          ? op.row.projectId
          : '';
      const targetRole = targetPid ? memberships[targetPid] : undefined;
      if (
        !inBatchNewProjects.has(targetPid) &&
        !projectOwnerBackfills.has(targetPid) &&
        targetRole !== 'owner' &&
        targetRole !== 'editor'
      ) {
        inBatchRejectedTasks.set(op.entityId, 'Forbidden');
        results[i] = {
          opId: op.opId,
          status: 'rejected',
          reason: 'Forbidden',
          row: null,
          clocks: {},
        };
        continue;
      }
    }
    knownHome.set(key, pusherScope);
    inBatchNewHome.set(key, {
      entity: op.entity,
      entityId: op.entityId,
      desiredScope: pusherScope,
    });
    opTargetScope[i] = pusherScope;

    if (op.entity === 'project' && op.op === 'upsert') {
      inBatchNewProjects.add(op.entityId);
      listScopeTargets.push({ opIndex: i, projectId: op.entityId, scope: pusherScope });
    } else if (
      op.entity === 'task' &&
      op.op === 'upsert' &&
      Object.hasOwn(op.row, 'projectId') &&
      typeof op.row.projectId === 'string' &&
      op.row.projectId.length > 0
    ) {
      listScopeTargets.push({
        opIndex: i,
        projectId: op.row.projectId,
        scope: pusherScope,
      });
    }
  }

  // D1 Batch 2: bind new ids in entityHome (INSERT ON CONFLICT DO NOTHING RETURNING + SELECT)
  // and atomically write owner memberships for newly created projects.
  const newlyWonKeys = new Set<string>();
  if (inBatchNewHome.size > 0) {
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
      batch2Stmts.push(
        db
          .insert(projectMembership)
          .select(
            sql`SELECT ${pid}, ${userId}, 'owner', ${nowMs}, NULL WHERE EXISTS (SELECT 1 FROM entityHome WHERE entity = 'project' AND entityId = ${pid} AND scope = ${pusherScope}) AND NOT EXISTS (SELECT 1 FROM purgedProject WHERE projectId = ${pid}) AND NOT EXISTS (SELECT 1 FROM projectMembership WHERE projectId = ${pid})`,
          )
          .onConflictDoNothing(),
      );
    }

    const batch2Results = (await db.batch(
      batch2Stmts as [BatchItem<'sqlite'>, ...BatchItem<'sqlite'>[]],
    )) as Array<Array<Record<string, unknown>>>;

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
    for (let i = 0; i < parsedOps.length; i += 1) {
      const { rawOpId, entity, entityId } = parsedOps[i];
      if (!entity || !entityId || opTargetScope[i] === null) continue;
      const key = entityHomeKey(entity, entityId);
      const newEntry = inBatchNewHome.get(key);
      if (mismatchKeys.has(key)) {
        results[i] = {
          opId: rawOpId,
          status: 'rejected',
          reason: 'id-in-other-scope',
          row: null,
          clocks: {},
        };
        opTargetScope[i] = null;
        if (entity === 'project') {
          inBatchNewProjects.delete(entityId);
        }
      } else if (newEntry?.parentTaskId && mismatchTaskIds.has(newEntry.parentTaskId)) {
        results[i] = {
          opId: rawOpId,
          status: 'rejected',
          reason: 'id-in-other-scope',
          row: null,
          clocks: {},
        };
        opTargetScope[i] = null;
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

  // D1 Batch 3: backfill missing owner memberships on knownHome resend, conditional listScopes inserts,
  // plus reading purgedProject & final memberships.
  const activeListTargets = listScopeTargets.filter((t) => opTargetScope[t.opIndex] !== null);
  if (projectOwnerBackfills.size > 0 || activeListTargets.length > 0) {
    const batch3Stmts: BatchItem<'sqlite'>[] = [];
    for (const pid of projectOwnerBackfills) {
      batch3Stmts.push(
        db
          .insert(projectMembership)
          .select(
            sql`SELECT ${pid}, ${userId}, 'owner', ${nowMs}, NULL WHERE EXISTS (SELECT 1 FROM entityHome WHERE entity = 'project' AND entityId = ${pid} AND scope = ${pusherScope}) AND NOT EXISTS (SELECT 1 FROM purgedProject WHERE projectId = ${pid}) AND NOT EXISTS (SELECT 1 FROM projectMembership WHERE projectId = ${pid})`,
          )
          .onConflictDoNothing(),
      );
    }

    const seenListScope = new Set<string>();
    const listProjectsToRead = new Set<string>();
    for (const target of activeListTargets) {
      listProjectsToRead.add(target.projectId);
      const lsKey = `${target.projectId}:${target.scope}`;
      if (seenListScope.has(lsKey)) continue;
      seenListScope.add(lsKey);
      batch3Stmts.push(
        db
          .insert(listScopes)
          .select(
            sql`SELECT ${target.projectId}, ${target.scope} WHERE NOT EXISTS (SELECT 1 FROM purgedProject WHERE projectId = ${target.projectId}) AND EXISTS (SELECT 1 FROM projectMembership WHERE projectId = ${target.projectId} AND userId = ${userId} AND removedAt IS NULL AND role IN ('owner', 'editor'))`,
          )
          .onConflictDoNothing(),
      );
    }

    const purgedReadChunks = chunkArray(Array.from(listProjectsToRead), QUERY_CHUNK_SIZE);
    const purgedStartIdx = batch3Stmts.length;
    for (const chunk of purgedReadChunks) {
      batch3Stmts.push(
        db
          .select({ projectId: purgedProject.projectId })
          .from(purgedProject)
          .where(inArray(purgedProject.projectId, chunk)),
      );
    }

    const membershipReadIdx = batch3Stmts.length;
    batch3Stmts.push(
      db
        .select({ projectId: projectMembership.projectId, role: projectMembership.role })
        .from(projectMembership)
        .where(and(eq(projectMembership.userId, userId), isNull(projectMembership.removedAt))),
    );

    const batch3Results = (await db.batch(
      batch3Stmts as [BatchItem<'sqlite'>, ...BatchItem<'sqlite'>[]],
    )) as Array<Array<Record<string, unknown>>>;

    for (let s = purgedStartIdx; s < membershipReadIdx; s += 1) {
      for (const row of batch3Results[s]) {
        purgedSet.add(String(row.projectId));
      }
    }

    memberships = {};
    for (const row of batch3Results[membershipReadIdx] ?? []) {
      const role = row.role;
      if (role === 'owner' || role === 'editor' || role === 'viewer') {
        memberships[String(row.projectId)] = role;
      }
    }
  }

  // Execute ops in original batch order: flush scope-grouped ops between owner project deletes
  // so earlier moves/edits run before a list purge, and later ops observe the purged state.
  const extraServerTimes: string[] = [];
  const scopeResponses: Array<{
    scope: string;
    group: Array<{ index: number; op: unknown }>;
    response: ScopePushResponse;
  }> = [];
  let boundMeMemberId: string | null = null;

  const pushRange = async (startIdx: number, endIdx: number): Promise<void> => {
    const scopeGroups = new Map<string, Array<{ index: number; op: unknown }>>();
    for (let i = startIdx; i < endIdx; i += 1) {
      const scope = opTargetScope[i];
      if (!scope) continue;
      let group = scopeGroups.get(scope);
      if (!group) {
        group = [];
        scopeGroups.set(scope, group);
      }
      group.push({ index: i, op: ops[i] });
    }
    if (scopeGroups.size === 0) return;

    const purgedList = Array.from(purgedSet);
    const membershipsSnapshot = { ...memberships };
    const currentMeMemberId = boundMeMemberId ?? meMemberId;
    const groupEntries = Array.from(scopeGroups.entries());
    const segmentResponses = await Promise.all(
      groupEntries.map(async ([scope, group]) => {
        const scopeUserId = scope.startsWith('u:') ? scope.slice(2) : scope;
        const stub = getScopeStub(scope);
        const response = await stub.push({
          scope,
          scopeUserId,
          pusherUserId: userId,
          deviceId,
          memberships: membershipsSnapshot,
          purgedProjects: purgedList,
          meMemberId: scope === pusherScope ? currentMeMemberId : null,
          ops: group.map((g) => g.op),
        });
        return { scope, group, response };
      }),
    );

    for (const entry of segmentResponses) {
      scopeResponses.push(entry);
      for (let j = 0; j < entry.group.length; j += 1) {
        results[entry.group[j].index] = entry.response.results[j];
      }
      if (entry.scope === pusherScope && entry.response.boundMeMemberId) {
        boundMeMemberId = entry.response.boundMeMemberId;
      }
    }
  };

  let segmentStart = 0;
  for (const del of ownerProjectDeletes) {
    await pushRange(segmentStart, del.opIndex);
    segmentStart = del.opIndex + 1;

    const purgeBatchResults = (await db.batch([
      db
        .insert(purgedProject)
        .values({ projectId: del.projectId, purgedAt: nowMs })
        .onConflictDoNothing(),
      db
        .update(projectMembership)
        .set({ removedAt: nowMs })
        .where(
          and(
            eq(projectMembership.projectId, del.projectId),
            isNull(projectMembership.removedAt),
          ),
        ),
      db
        .select({ scope: listScopes.scope })
        .from(listScopes)
        .where(eq(listScopes.projectId, del.projectId)),
    ])) as Array<Array<Record<string, unknown>>>;

    const listedScopes = (purgeBatchResults[2] ?? []).map((r) => String(r.scope));
    const scopesToPurge = Array.from(new Set([...listedScopes, del.homeScope]));
    const settleResults = await Promise.allSettled(
      scopesToPurge.map(async (targetScope) =>
        getScopeStub(targetScope).purgeProject({
          projectId: del.projectId,
          purgedAt: nowMs,
          opId: targetScope === del.homeScope ? del.opId : undefined,
          pusherUserId: targetScope === del.homeScope ? userId : undefined,
        }),
      ),
    );

    const succeededScopes: string[] = [];
    let homeResult: ScopePurgeProjectResponse | null = null;
    let homeError: unknown = null;
    for (let idx = 0; idx < scopesToPurge.length; idx += 1) {
      const targetScope = scopesToPurge[idx];
      const settled = settleResults[idx];
      if (settled.status === 'fulfilled') {
        succeededScopes.push(targetScope);
        if (targetScope === del.homeScope) {
          homeResult = settled.value;
        }
      } else if (targetScope === del.homeScope) {
        homeError = settled.reason;
      }
    }

    if (succeededScopes.length > 0) {
      await db
        .delete(listScopes)
        .where(
          and(
            eq(listScopes.projectId, del.projectId),
            inArray(listScopes.scope, succeededScopes),
          ),
        );
    }

    if (homeError !== null) {
      throw homeError;
    }

    purgedSet.add(del.projectId);
    delete memberships[del.projectId];
    extraServerTimes.push(homeResult!.serverTime);
    results[del.opIndex] = {
      opId: del.opId,
      status: 'applied',
      row: homeResult!.purgedRow,
      clocks: homeResult!.clocks,
    };
  }
  await pushRange(segmentStart, ops.length);

  const effectiveMeMemberId = boundMeMemberId ?? meMemberId;
  let profileUpdate: { name: string | null; initial: string | null; color: string | null } | null =
    null;
  if (effectiveMeMemberId !== null) {
    for (const { scope, group, response } of scopeResponses) {
      if (scope !== pusherScope) continue;
      for (let j = 0; j < group.length; j += 1) {
        const res = response.results[j];
        const opObj = group[j].op as Record<string, unknown>;
        if (
          res.status === 'applied' &&
          res.row &&
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
      .set({ meMemberId: boundMeMemberId, ...(profileUpdate ?? {}) })
      .where(and(eq(user.id, userId), isNull(user.meMemberId)));
  } else if (profileUpdate !== null && effectiveMeMemberId !== null) {
    await db
      .update(user)
      .set(profileUpdate)
      .where(and(eq(user.id, userId), eq(user.meMemberId, effectiveMeMemberId)));
  }

  const scopeServerTimes = [
    ...extraServerTimes,
    ...scopeResponses.map((r) => r.response.serverTime),
  ];
  return {
    results: results as PushOpResult[],
    serverTime: nextServerTime(Math.max(Date.now(), nowMs), scopeServerTimes),
  };
}
