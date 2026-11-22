import type { PushOpResult } from '../../scope/api';
import {
  hasAllRequiredFields,
  isTaskChildEntity,
  parseEntityId,
  type EntityName,
  type MembershipRole,
} from '../entities';
import { hasWriteRole, listWriteDenial } from '../access';
import { newRowPreconditionDenial } from '../newRow';
import { REJECT_REASON, rejectedResult } from '../rejectReason';
import { entityHomeKey, type ParsedPushOp } from './parse';

export interface NewEntityHomeEntry {
  entity: EntityName;
  entityId: string;
  desiredScope: string;
  parentTaskId?: string;
}

export interface ListScopeTarget {
  projectId: string;
  scope: string;
}

export type PlannedOpOutcome =
  | { kind: 'routed'; scope: string }
  | { kind: 'rejected'; result: PushOpResult }
  | { kind: 'ownerDelete'; projectId: string; homeScope: string; opId: string };

export interface PlannedPushOp {
  parsed: ParsedPushOp;
  outcome: PlannedOpOutcome;
  newHome?: NewEntityHomeEntry;
  listScope?: ListScopeTarget;
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
  ops: PlannedPushOp[];
  inBatchNewProjects: Set<string>;
  projectOwnerBackfills: Set<string>;
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

  const ops: PlannedPushOp[] = [];
  const inBatchRejectedTasks = new Map<string, string>();
  const inBatchNewProjects = new Set<string>();
  const projectOwnerBackfills = new Set<string>();

  for (const parsed of parsedOps) {
    const { rec, rawOpId, entity, entityId, validated } = parsed;
    if (!entity || !entityId) {
      ops.push({
        parsed,
        outcome: {
          kind: 'rejected',
          result: rejectedResult(
            rawOpId,
            validated.ok ? REJECT_REASON.MALFORMED_OP : validated.reason,
          ),
        },
      });
      continue;
    }

    const key = entityHomeKey(entity, entityId);

    if (entity === 'tag') {
      ops.push({ parsed, outcome: { kind: 'routed', scope: pusherScope } });
      continue;
    }

    if (entity === 'projectMember' || entity === 'projectInvite') {
      let scope: string;
      if (workingHome.has(key)) {
        scope = workingHome.get(key)!;
      } else if (entity === 'projectMember') {
        const pm = parseEntityId('projectMember', entityId)!;
        scope = workingHome.get(entityHomeKey('project', pm.projectId)) ?? pusherScope;
      } else {
        const pid =
          rec?.row &&
          typeof rec.row === 'object' &&
          !Array.isArray(rec.row) &&
          typeof (rec.row as Record<string, unknown>).projectId === 'string'
            ? ((rec.row as Record<string, unknown>).projectId as string)
            : '';
        scope = (pid && workingHome.get(entityHomeKey('project', pid))) || pusherScope;
      }
      ops.push({ parsed, outcome: { kind: 'routed', scope } });
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
            ops.push({
              parsed,
              outcome: {
                kind: 'rejected',
                result: rejectedResult(validated.op.opId, parentRejectReason),
              },
            });
            continue;
          }
          const taskHome = taskId ? workingHome.get(entityHomeKey('task', taskId)) : undefined;
          if (taskHome ? targetScope !== taskHome : targetScope !== pusherScope) {
            ops.push({
              parsed,
              outcome: {
                kind: 'rejected',
                result: rejectedResult(validated.op.opId, REJECT_REASON.ID_IN_OTHER_SCOPE),
              },
            });
            continue;
          }
        } else if (targetScope !== pusherScope) {
          if (entity === 'task') {
            inBatchRejectedTasks.set(entityId, REJECT_REASON.ID_IN_OTHER_SCOPE);
          }
          ops.push({
            parsed,
            outcome: {
              kind: 'rejected',
              result: rejectedResult(validated.op.opId, REJECT_REASON.ID_IN_OTHER_SCOPE),
            },
          });
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
        ops.push({
          parsed,
          outcome: {
            kind: 'ownerDelete',
            projectId: entityId,
            homeScope: targetScope,
            opId: validated.op.opId,
          },
        });
        continue;
      }

      let listScope: ListScopeTarget | undefined;
      if (entity === 'project' && validated.ok && validated.op.op === 'upsert') {
        if (targetScope === pusherScope && !memberships[entityId] && !purgedSet.has(entityId)) {
          projectOwnerBackfills.add(entityId);
          listScope = { projectId: entityId, scope: targetScope };
        } else if (hasAllRequiredFields('project', validated.op.fields)) {
          listScope = { projectId: entityId, scope: targetScope };
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
        // Role only, as before: a purged target list is still registered here (registerListScope
        // skips purged lists and the DO refuses the write), so the batch composition is unchanged.
        if (
          hasWriteRole(memberships, targetPid) ||
          inBatchNewProjects.has(targetPid) ||
          projectOwnerBackfills.has(targetPid)
        ) {
          listScope = { projectId: targetPid, scope: targetScope };
        }
      }
      ops.push({
        parsed,
        outcome: { kind: 'routed', scope: targetScope },
        ...(listScope ? { listScope } : {}),
      });
      continue;
    }

    // New entity id (not yet in entityHome)
    if (!validated.ok) {
      ops.push({
        parsed,
        outcome: { kind: 'rejected', result: rejectedResult(validated.opId, validated.reason) },
      });
      continue;
    }

    const op = validated.op;
    const preconditionDenial = newRowPreconditionDenial(op, {
      rejectUnknownProjectDelete: true,
      checkParentTask: (taskId) => {
        const parentRejectReason = inBatchRejectedTasks.get(taskId);
        if (parentRejectReason) return { ok: false, reason: parentRejectReason };
        return workingHome.has(entityHomeKey('task', taskId)) ? { ok: true } : { ok: false };
      },
    });
    if (preconditionDenial) {
      ops.push({
        parsed,
        outcome: { kind: 'rejected', result: rejectedResult(op.opId, preconditionDenial) },
      });
      continue;
    }

    if (isTaskChildEntity(op.entity)) {
      const taskId = String(op.row.taskId);
      const parentScope = workingHome.get(entityHomeKey('task', taskId))!;
      workingHome.set(key, parentScope);
      ops.push({
        parsed,
        outcome: { kind: 'routed', scope: parentScope },
        newHome: {
          entity: op.entity,
          entityId: op.entityId,
          desiredScope: parentScope,
          parentTaskId: taskId,
        },
      });
      continue;
    }

    // New top-level entity: project, task, member, folder
    if (op.entity === 'project' && purgedSet.has(op.entityId)) {
      ops.push({
        parsed,
        outcome: { kind: 'rejected', result: rejectedResult(op.opId, REJECT_REASON.PROJECT_PURGED) },
      });
      continue;
    }
    if (op.entity === 'task' && op.op === 'upsert') {
      const targetPid =
        Object.hasOwn(op.row, 'projectId') && typeof op.row.projectId === 'string'
          ? op.row.projectId
          : '';
      // Ordering invariant: a list created or owner-backfilled earlier in this batch has no D1 role
      // yet; waiving Forbidden here is valid only because applyPushPlan runs reconcileListScopes
      // (which re-reads D1 memberships after claimOwner) before dispatchScopeBatches.
      const denial = targetPid ? listWriteDenial(targetPid, context) : REJECT_REASON.FORBIDDEN;
      if (
        denial === REJECT_REASON.PROJECT_PURGED ||
        (denial && !inBatchNewProjects.has(targetPid) && !projectOwnerBackfills.has(targetPid))
      ) {
        inBatchRejectedTasks.set(op.entityId, denial);
        ops.push({
          parsed,
          outcome: { kind: 'rejected', result: rejectedResult(op.opId, denial) },
        });
        continue;
      }
    }

    workingHome.set(key, pusherScope);
    let listScope: ListScopeTarget | undefined;
    if (op.entity === 'project' && op.op === 'upsert') {
      inBatchNewProjects.add(op.entityId);
      listScope = { projectId: op.entityId, scope: pusherScope };
    } else if (
      op.entity === 'task' &&
      op.op === 'upsert' &&
      Object.hasOwn(op.row, 'projectId') &&
      typeof op.row.projectId === 'string' &&
      op.row.projectId.length > 0
    ) {
      listScope = { projectId: op.row.projectId, scope: pusherScope };
    }
    ops.push({
      parsed,
      outcome: { kind: 'routed', scope: pusherScope },
      newHome: {
        entity: op.entity,
        entityId: op.entityId,
        desiredScope: pusherScope,
      },
      ...(listScope ? { listScope } : {}),
    });
  }

  return {
    ops,
    inBatchNewProjects,
    projectOwnerBackfills,
  };
}
