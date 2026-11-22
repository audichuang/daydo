import {
  isTaskChildEntity,
  type EntityName,
  type StoredEntityState,
} from '../sync/entities';
import type { clampHlc, Hlc } from '../sync/hlc';
import {
  canRead,
  childListId,
  isOwnerOnlyEntity,
  type ListAccess,
} from '../sync/access';
import { mergeOp } from '../sync/merge';
import { envelopeOf, toEnvelope, type OpEnvelope } from '../sync/envelope';
import { newRowPreconditionDenial } from '../sync/newRow';
import { rejectedResult } from '../sync/rejectReason';
import { authorizeOp } from './authorize';
import { rowView } from './rowView';
import type { PushOpResult, ScopePushInput, ScopePushResponse } from './api';
import type { ScopeStore } from './store';

/** The DO owns the HLC state, including clamping before a merge can reject an op. */
export interface ScopePushClock {
  clamp(hlc: string, nowMs: number): ReturnType<typeof clampHlc>;
  tick(nowMs: number, observed: Hlc[]): string;
}

const PROJECT_NON_CREATOR_IGNORED_FIELDS = new Set<string>(['folderId']);

/**
 * The batch's envelopes: the Worker's validations when it sent one per op, otherwise (an older
 * Worker) the DO validates the raw ops itself. Decided for the whole input, never per op.
 */
export function pushEnvelopes(input: ScopePushInput): OpEnvelope[] {
  const { ops, validated } = input;
  if (Array.isArray(validated) && validated.length === ops.length) {
    return ops.map((raw, i) => envelopeOf(raw, validated[i]));
  }
  return ops.map(toEnvelope);
}

export function processPushBatch(
  store: ScopeStore,
  input: ScopePushInput,
  clock: ScopePushClock,
): ScopePushResponse {
  const nowMs = Date.now();
  const initialSeq = store.getCounter();
  let currentSeq = initialSeq;
  let meMemberId = input.meMemberId;
  let boundMeMemberId: string | null = null;
  const isScopeOwner = input.pusherUserId === input.scopeUserId;
  const purgedSet = new Set<string>([...input.purgedProjects, ...store.getPurgedProjects()]);
  const access: ListAccess = { memberships: input.memberships, purgedSet };

  const results: PushOpResult[] = [];
  const batchHlcs: Hlc[] = [];

  if (input.ops.length === 0) {
    const serverTime = clock.tick(nowMs, batchHlcs);
    return {
      results: [],
      serverSeq: currentSeq,
      boundMeMemberId: null,
      serverTime,
    };
  }

  const canReadState = (
    entity: EntityName,
    entityId: string,
    state: StoredEntityState,
  ): boolean => {
    if (isOwnerOnlyEntity(entity)) {
      return isScopeOwner;
    }
    if (entity === 'project') {
      return canRead(input.memberships, entityId);
    }
    if (entity === 'projectMember' || entity === 'projectInvite' || entity === 'task') {
      return canRead(input.memberships, String(state.row.projectId));
    }
    // Child row: check parent task's current list (or stored projectId tag).
    const parentTask = store.getRow('task', String(state.row.taskId));
    const projectId = childListId(
      parentTask ? String(parentTask.row.projectId) : null,
      state.projectId,
    );
    return canRead(input.memberships, projectId);
  };

  const resolveCurrentRow = (
    entity: EntityName | null,
    entityId: string | null,
  ): { row: Record<string, unknown> | null; clocks: Record<string, string>; gone?: boolean } => {
    if (!entity || !entityId) {
      return { row: null, clocks: {} };
    }
    const state = store.getRow(entity, entityId);
    if (!state) {
      return { row: null, clocks: {} };
    }
    if (!canReadState(entity, entityId, state)) {
      return { row: null, clocks: {}, gone: true };
    }
    return {
      row: rowView(entity, state.row, state.purgedAt, { isScopeOwner, meMemberId }),
      clocks: { ...state.clocks },
    };
  };

  const rejectOp = (
    opId: string,
    reason: string,
    entity: EntityName | null,
    entityId: string | null,
  ) => {
    const current = resolveCurrentRow(entity, entityId);
    const result = rejectedResult(opId, reason, current.row, current.clocks, current.gone);
    if (opId.length > 0) {
      store.insertOpApplied({
        opId,
        userId: input.pusherUserId,
        status: result.status,
        reason,
        serverSeq: currentSeq,
      });
    }
    results.push(result);
  };

  for (const envelope of pushEnvelopes(input)) {
    const { rec, rawOpId } = envelope;
    const rawEntityId = envelope.entityId;
    const rawEntity = rawEntityId !== null ? envelope.entity : null;

    // 1. opId dedupe
    if (rawOpId.length > 0) {
      const seen = store.getOpApplied(rawOpId);
      if (seen) {
        if (seen.userId !== input.pusherUserId) {
          results.push(rejectedResult(rawOpId, 'opId already used by another user'));
          continue;
        }
        if (seen.status === 'rejected') {
          const current = resolveCurrentRow(rawEntity, rawEntityId);
          results.push(
            rejectedResult(
              rawOpId,
              seen.reason ?? 'Previously rejected',
              current.row,
              current.clocks,
              current.gone,
            ),
          );
          continue;
        }
        // Previously applied replay
        if (rawEntity && rawEntityId) {
          const state = store.getRow(rawEntity, rawEntityId);
          if (state && canReadState(rawEntity, rawEntityId, state)) {
            if (
              rawEntity === 'member' &&
              isScopeOwner &&
              meMemberId === null &&
              rec?.row &&
              typeof rec.row === 'object' &&
              !Array.isArray(rec.row) &&
              Object.hasOwn(rec.row, 'isMe') &&
              (rec.row as Record<string, unknown>).isMe === true
            ) {
              meMemberId = rawEntityId;
              boundMeMemberId = rawEntityId;
              currentSeq += 1;
              store.upsertRow('member', rawEntityId, { ...state, serverSeq: currentSeq });
              store.setCounter(currentSeq);
            }
            results.push({
              opId: rawOpId,
              status: 'applied',
              row: rowView(rawEntity, state.row, state.purgedAt, { isScopeOwner, meMemberId }),
              clocks: { ...state.clocks },
            });
            continue;
          }
          if (state) {
            results.push({
              opId: rawOpId,
              status: 'applied',
              row: null,
              clocks: {},
              gone: true,
            });
            continue;
          }
        }
        results.push({
          opId: rawOpId,
          status: 'applied',
          row: null,
          clocks: {},
        });
        continue;
      }
    }

    // 2. Validation
    const validated = envelope.validated;
    if (!validated.ok) {
      rejectOp(validated.opId, validated.reason, rawEntity, rawEntityId);
      continue;
    }
    const op = validated.op;

    // 3. Disallowed sync entities
    if (op.entity === 'projectMember' || op.entity === 'projectInvite') {
      rejectOp(op.opId, `${op.entity} cannot be modified via sync`, op.entity, op.entityId);
      continue;
    }

    const existing = store.getRow(op.entity, op.entityId);

    // 4. Missing row precondition ladder (partial upsert, child delete, child without parent)
    if (!existing) {
      const denial = newRowPreconditionDenial(op, {
        checkParentTask: (taskId) =>
          store.getRow('task', taskId) ? { ok: true } : { ok: false },
      });
      if (denial) {
        rejectOp(op.opId, denial, op.entity, op.entityId);
        continue;
      }
    }

    // 5. Authorization & domain rules by row's CURRENT list
    const auth = authorizeOp({
      op,
      existing,
      isScopeOwner,
      access,
      getTask: (taskId) => store.getRow('task', taskId),
    });
    if (!auth.ok) {
      rejectOp(op.opId, auth.reason, op.entity, op.entityId);
      continue;
    }
    const { parentTask, childProjectId } = auth;

    // 6. HLC 5-minute clamp & merge
    let clamped: ReturnType<typeof clampHlc>;
    let merged: ReturnType<typeof mergeOp>;
    try {
      clamped = clock.clamp(op.hlc, nowMs);
      const parentPurged =
        isTaskChildEntity(op.entity) &&
        (!existing || existing.purgedAt === null) &&
        parentTask !== null &&
        parentTask.purgedAt !== null;

      merged = mergeOp(
        existing
          ? { row: existing.row, clocks: existing.clocks, purgedAt: existing.purgedAt }
          : null,
        {
          entity: op.entity,
          entityId: op.entityId,
          op: op.op,
          hlc: clamped.formatted,
          fields: op.fields,
          row: op.row,
        },
        nowMs,
        {
          parentPurged,
          ignoreFields:
            op.entity === 'project' && !isScopeOwner
              ? PROJECT_NON_CREATOR_IGNORED_FIELDS
              : undefined,
        },
      );
      batchHlcs.push(clamped.hlc);
    } catch (err) {
      rejectOp(
        op.opId,
        err instanceof Error ? `Invalid op: ${err.message}` : 'Invalid sync op',
        op.entity,
        op.entityId,
      );
      continue;
    }

    // 7. Persist state & handle task move / cascade purge
    let opServerSeq = existing?.serverSeq ?? currentSeq;
    if (merged.changed) {
      currentSeq += 1;
      opServerSeq = currentSeq;
      const nextState: StoredEntityState = {
        row: merged.row,
        clocks: merged.clocks,
        purgedAt: merged.purgedAt,
        serverSeq: opServerSeq,
        ...(isTaskChildEntity(op.entity) ? { projectId: childProjectId ?? '' } : {}),
      };
      store.upsertRow(op.entity, op.entityId, nextState);

      if (
        op.entity === 'task' &&
        existing &&
        existing.purgedAt === null &&
        op.op === 'upsert'
      ) {
        const oldProjectId = String(existing.row.projectId);
        const newProjectId = String(merged.row.projectId);
        if (newProjectId !== oldProjectId) {
          store.upsertDeparture({
            entity: 'task',
            entityId: op.entityId,
            projectId: oldProjectId,
            serverSeq: opServerSeq,
          });
          const children = store.findActiveTaskChildren(op.entityId);
          for (const child of children) {
            currentSeq += 1;
            const childSeq = currentSeq;
            store.upsertRow(child.entity, child.entityId, {
              ...child.state,
              projectId: newProjectId,
              serverSeq: childSeq,
            });
            store.upsertDeparture({
              entity: child.entity,
              entityId: child.entityId,
              projectId: oldProjectId,
              serverSeq: childSeq,
            });
          }
        }
      }

      if (op.entity === 'task' && op.op === 'delete') {
        const children = store.findActiveTaskChildren(op.entityId);
        for (const child of children) {
          currentSeq += 1;
          store.upsertRow(child.entity, child.entityId, {
            ...child.state,
            purgedAt: nowMs,
            serverSeq: currentSeq,
          });
        }
      }
    }

    if (
      op.entity === 'member' &&
      op.op === 'upsert' &&
      isScopeOwner &&
      meMemberId === null &&
      Object.hasOwn(op.row, 'isMe') &&
      op.row.isMe === true
    ) {
      meMemberId = op.entityId;
      boundMeMemberId = op.entityId;
      if (!merged.changed && existing) {
        currentSeq += 1;
        opServerSeq = currentSeq;
        store.upsertRow('member', op.entityId, {
          ...existing,
          serverSeq: opServerSeq,
        });
      }
    }

    store.insertOpApplied({
      opId: op.opId,
      userId: input.pusherUserId,
      status: 'applied',
      reason: null,
      serverSeq: opServerSeq,
    });

    results.push({
      opId: op.opId,
      status: 'applied',
      row: rowView(op.entity, merged.row, merged.purgedAt, { isScopeOwner, meMemberId }),
      clocks: merged.clocks,
    });
  }

  if (currentSeq !== initialSeq) {
    store.setCounter(currentSeq);
  }

  const serverTime = clock.tick(Math.max(Date.now(), nowMs), batchHlcs);

  return {
    results,
    serverSeq: currentSeq,
    boundMeMemberId,
    serverTime,
  };
}
