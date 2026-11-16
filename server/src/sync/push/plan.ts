import type { PushOpResult } from '../../scope/api';
import {
  hasAllRequiredFields,
  isTaskChildEntity,
  parseEntityId,
  type EntityName,
  type MembershipRole,
} from '../entities';
import { listWriteDenial } from '../access';
import { entityHomeKey, type ParsedPushOp } from './parse';

export interface NewEntityHomeEntry {
  entity: EntityName;
  entityId: string;
  desiredScope: string;
  parentTaskId?: string;
}

export interface OwnerProjectDelete {
  opIndex: number;
  projectId: string;
  homeScope: string;
  opId: string;
}

export interface ListScopeTarget {
  opIndex: number;
  projectId: string;
  scope: string;
}

export interface PlanPushContext {
  knownHome: ReadonlyMap<string, string>;
  purgedSet: ReadonlySet<string>;
  memberships: Readonly<Record<string, MembershipRole>>;
  removedOwnerProjects: ReadonlySet<string>;
}

export interface PlanPushInput {
  pusherScope: string;
  parsedOps: readonly ParsedPushOp[];
  context: PlanPushContext;
}

export interface PushPlan {
  results: Array<PushOpResult | null>;
  opTargetScope: Array<string | null>;
  inBatchNewHome: Map<string, NewEntityHomeEntry>;
  inBatchNewProjects: Set<string>;
  projectOwnerBackfills: Set<string>;
  ownerProjectDeletes: OwnerProjectDelete[];
  listScopeTargets: ListScopeTarget[];
}

function rejectedResult(opId: string, reason: string): PushOpResult {
  return {
    opId,
    status: 'rejected',
    reason,
    row: null,
    clocks: {},
  };
}

/**
 * Pure planning pass over parsed ops and loaded D1 context.
 * Resolves per-op scope routing, in-batch parent/child rejections, owner deletes,
 * and D1 binding/listScope intents without mutating the input context.
 */
export function planPushBatch(input: PlanPushInput): PushPlan {
  const { pusherScope, parsedOps, context } = input;
  const { purgedSet, memberships, removedOwnerProjects } = context;
  const workingHome = new Map(context.knownHome);

  const results: Array<PushOpResult | null> = Array.from({ length: parsedOps.length }, () => null);
  const inBatchNewHome = new Map<string, NewEntityHomeEntry>();
  const inBatchRejectedTasks = new Map<string, string>();
  const inBatchNewProjects = new Set<string>();
  const projectOwnerBackfills = new Set<string>();
  const ownerProjectDeletes: OwnerProjectDelete[] = [];
  const listScopeTargets: ListScopeTarget[] = [];
  const opTargetScope: Array<string | null> = Array.from({ length: parsedOps.length }, () => null);

  for (let i = 0; i < parsedOps.length; i += 1) {
    const { rec, rawOpId, entity, entityId, validated } = parsedOps[i];
    if (!entity || !entityId) {
      results[i] = rejectedResult(rawOpId, validated.ok ? 'Malformed op' : validated.reason);
      continue;
    }

    const key = entityHomeKey(entity, entityId);

    if (entity === 'tag') {
      opTargetScope[i] = pusherScope;
      continue;
    }

    if (entity === 'projectMember' || entity === 'projectInvite') {
      if (workingHome.has(key)) {
        opTargetScope[i] = workingHome.get(key)!;
      } else if (entity === 'projectMember') {
        const pm = parseEntityId('projectMember', entityId)!;
        opTargetScope[i] = workingHome.get(entityHomeKey('project', pm.projectId)) ?? pusherScope;
      } else {
        const pid =
          rec?.row &&
          typeof rec.row === 'object' &&
          !Array.isArray(rec.row) &&
          typeof (rec.row as Record<string, unknown>).projectId === 'string'
            ? ((rec.row as Record<string, unknown>).projectId as string)
            : '';
        opTargetScope[i] =
          (pid && workingHome.get(entityHomeKey('project', pid))) || pusherScope;
      }
      continue;
    }

    if (workingHome.has(key)) {
      const targetScope = workingHome.get(key)!;
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
            results[i] = rejectedResult(validated.op.opId, parentRejectReason);
            continue;
          }
          const taskHome = taskId ? workingHome.get(entityHomeKey('task', taskId)) : undefined;
          if (taskHome ? targetScope !== taskHome : targetScope !== pusherScope) {
            results[i] = rejectedResult(validated.op.opId, 'id-in-other-scope');
            continue;
          }
        } else if (targetScope !== pusherScope) {
          if (entity === 'task') {
            inBatchRejectedTasks.set(entityId, 'id-in-other-scope');
          }
          results[i] = rejectedResult(validated.op.opId, 'id-in-other-scope');
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
      results[i] = rejectedResult(validated.opId, validated.reason);
      continue;
    }

    const op = validated.op;
    if (op.entity === 'project' && op.op === 'delete') {
      results[i] = rejectedResult(op.opId, 'unknown-row');
      continue;
    }

    if (op.op === 'upsert' && !hasAllRequiredFields(op.entity, op.fields)) {
      results[i] = rejectedResult(op.opId, 'unknown-row');
      continue;
    }

    if (isTaskChildEntity(op.entity)) {
      if (op.op === 'delete') {
        results[i] = rejectedResult(op.opId, 'unknown-row');
        continue;
      }
      const taskId =
        Object.hasOwn(op.row, 'taskId') && typeof op.row.taskId === 'string' ? op.row.taskId : '';
      const parentRejectReason = taskId ? inBatchRejectedTasks.get(taskId) : undefined;
      if (parentRejectReason) {
        results[i] = rejectedResult(op.opId, parentRejectReason);
        continue;
      }
      const parentScope = taskId ? workingHome.get(entityHomeKey('task', taskId)) : undefined;
      if (!parentScope) {
        results[i] = rejectedResult(op.opId, 'unknown-row');
        continue;
      }
      workingHome.set(key, parentScope);
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
      results[i] = rejectedResult(op.opId, 'Project is purged');
      continue;
    }
    if (op.entity === 'task' && op.op === 'upsert') {
      const targetPid =
        Object.hasOwn(op.row, 'projectId') && typeof op.row.projectId === 'string'
          ? op.row.projectId
          : '';
      // A list created or claimed earlier in this batch has no D1 role yet; that only waives Forbidden.
      const denial = targetPid ? listWriteDenial(targetPid, context) : 'Forbidden';
      if (
        denial === 'Project is purged' ||
        (denial && !inBatchNewProjects.has(targetPid) && !projectOwnerBackfills.has(targetPid))
      ) {
        inBatchRejectedTasks.set(op.entityId, denial);
        results[i] = rejectedResult(op.opId, denial);
        continue;
      }
    }
    workingHome.set(key, pusherScope);
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

  return {
    results,
    opTargetScope,
    inBatchNewHome,
    inBatchNewProjects,
    projectOwnerBackfills,
    ownerProjectDeletes,
    listScopeTargets,
  };
}
