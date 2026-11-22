import { hasAllRequiredFields, isTaskChildEntity, type ValidatedOp } from './entities';
import { REJECT_REASON } from './rejectReason';

export interface NewRowPreconditionOptions {
  /**
   * Whether deleting an unknown project is rejected with REJECT_REASON.UNKNOWN_ROW here.
   * The D1 planner enables this (there is no homeScope to purge); the Scope DO leaves it false so
   * `authorizeOp` enforces owner / D1-purge rules on direct DO calls.
   */
  rejectUnknownProjectDelete?: boolean;
  /**
   * Checks whether a new task-child's parent task exists.
   * Return `{ ok: true }` when known, or `{ ok: false, reason? }` to reject
   * (defaults to `REJECT_REASON.UNKNOWN_ROW`).
   */
  checkParentTask?: (taskId: string) => { ok: true } | { ok: false; reason?: string };
}

/**
 * Shared precondition ladder for an op whose target row does not exist yet:
 * 1. (optional) Deleting an unknown project -> REJECT_REASON.UNKNOWN_ROW.
 * 2. Upsert missing any required field -> REJECT_REASON.UNKNOWN_ROW.
 * 3. Deleting an unknown task child -> REJECT_REASON.UNKNOWN_ROW.
 * 4. Creating a task child whose parent task is missing (or rejected in-batch) -> parent reason or
 *    REJECT_REASON.UNKNOWN_ROW.
 *
 * Returns the rejection reason string, or `null` when all preconditions pass.
 * The Scope DO remains the authority.
 */
export function newRowPreconditionDenial(
  op: ValidatedOp,
  options: NewRowPreconditionOptions = {},
): string | null {
  if (options.rejectUnknownProjectDelete && op.entity === 'project' && op.op === 'delete') {
    return REJECT_REASON.UNKNOWN_ROW;
  }

  if (op.op === 'upsert' && !hasAllRequiredFields(op.entity, op.fields)) {
    return REJECT_REASON.UNKNOWN_ROW;
  }

  if (isTaskChildEntity(op.entity)) {
    if (op.op === 'delete') {
      return REJECT_REASON.UNKNOWN_ROW;
    }
    if (options.checkParentTask) {
      const taskId =
        Object.hasOwn(op.row, 'taskId') && typeof op.row.taskId === 'string' ? op.row.taskId : '';
      if (!taskId) {
        return REJECT_REASON.UNKNOWN_ROW;
      }
      const parentCheck = options.checkParentTask(taskId);
      if (!parentCheck.ok) {
        return parentCheck.reason ?? REJECT_REASON.UNKNOWN_ROW;
      }
    }
  }

  return null;
}
