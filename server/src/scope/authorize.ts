import { listWriteDenial, roleOf, type ListAccess } from '../sync/access';
import type { StoredEntityState, ValidatedOp } from '../sync/entities';

export interface AuthorizeOpInput {
  /** A validated op; projectMember and projectInvite are refused before this check. */
  op: ValidatedOp;
  /** The row's current state in this scope, or null for a new id. */
  existing: StoredEntityState | null;
  /** Whether the pusher owns this scope (member, folder and tag rows are owner-only). */
  isScopeOwner: boolean;
  access: ListAccess;
  /** Reads a task from the same store the push uses (the parent of a child row). */
  getTask: (taskId: string) => StoredEntityState | null;
}

export type AuthorizeOpResult =
  | {
      ok: true;
      /** The child row's parent task, read while authorizing (null for non-child rows). */
      parentTask: StoredEntityState | null;
      /** The list a child row belongs to after this op (undefined for non-child rows). */
      childProjectId: string | undefined;
    }
  | { ok: false; reason: string };

function changesNullableField(
  op: ValidatedOp,
  existing: StoredEntityState | null,
  field: 'deletedAt' | 'archivedAt',
): boolean {
  if (!op.fields.includes(field)) return false;
  if (existing) {
    const next = Object.hasOwn(op.row, field) ? (op.row[field] ?? null) : null;
    return next !== (existing.row[field] ?? null);
  }
  return Object.hasOwn(op.row, field) && op.row[field] !== null && op.row[field] !== undefined;
}

/**
 * Decides whether a push op may be applied, judged by the row's CURRENT list in this scope:
 * owner-only rows, project delete/archive rules, task moves and child rows following their parent.
 * Pure apart from `getTask`; the Scope DO calls it inside its transaction.
 */
export function authorizeOp(input: AuthorizeOpInput): AuthorizeOpResult {
  const { op, existing, isScopeOwner, access, getTask } = input;
  const deny = (reason: string): AuthorizeOpResult => ({ ok: false, reason });

  if (op.entity === 'member' || op.entity === 'folder' || op.entity === 'tag') {
    if (!isScopeOwner) return deny('Forbidden');
    return { ok: true, parentTask: null, childProjectId: undefined };
  }

  if (op.entity === 'project') {
    const isOwner = roleOf(access.memberships, op.entityId) === 'owner';
    if (op.op === 'delete') {
      if (!isOwner) return deny('Forbidden');
      if (!access.purgedSet.has(op.entityId)) {
        return deny('Project deletion must be purged via D1');
      }
    } else {
      const denial = listWriteDenial(op.entityId, access);
      if (denial) return deny(denial);
      // Only the owner may trash, restore, archive or unarchive a list.
      const touchesLifecycle =
        changesNullableField(op, existing, 'deletedAt') ||
        changesNullableField(op, existing, 'archivedAt');
      if (touchesLifecycle && !isOwner) return deny('Forbidden');
    }
    return { ok: true, parentTask: null, childProjectId: undefined };
  }

  if (op.entity === 'task') {
    if (!existing) {
      if (op.op === 'upsert') {
        const denial = listWriteDenial(String(op.row.projectId), access);
        if (denial) return deny(denial);
      } else if (!isScopeOwner) {
        return deny('Forbidden');
      }
      return { ok: true, parentTask: null, childProjectId: undefined };
    }
    const currentProjectId = String(existing.row.projectId);
    // The owner may replay onto a tombstone that lost its list (projectId '').
    const allowEmptyTombstoneReplay =
      existing.purgedAt !== null && currentProjectId === '' && isScopeOwner;
    const denial = listWriteDenial(currentProjectId, access);
    if (denial === 'Project is purged' || (denial && !allowEmptyTombstoneReplay)) {
      return deny(denial);
    }
    if (existing.purgedAt === null && op.op === 'upsert' && op.fields.includes('projectId')) {
      const nextProjectId =
        Object.hasOwn(op.row, 'projectId') && typeof op.row.projectId === 'string'
          ? op.row.projectId
          : '';
      if (nextProjectId !== currentProjectId) {
        const moveDenial = listWriteDenial(nextProjectId, access);
        if (moveDenial) return deny(moveDenial);
      }
    }
    return { ok: true, parentTask: null, childProjectId: undefined };
  }

  // Child row (checklistItem, attachment, comment): its list is the parent task's current list.
  if (existing) {
    if (op.op === 'upsert' && op.fields.includes('taskId')) {
      const nextTaskId = Object.hasOwn(op.row, 'taskId') ? op.row.taskId : null;
      if (nextTaskId !== existing.row.taskId) return deny('Child taskId cannot be changed');
    }
    const parentTask = getTask(String(existing.row.taskId));
    const currentProjectId = parentTask
      ? String(parentTask.row.projectId)
      : (existing.projectId ?? '');
    const allowEmptyTombstoneReplay =
      existing.purgedAt !== null && currentProjectId === '' && isScopeOwner;
    const denial = listWriteDenial(currentProjectId, access);
    if (denial === 'Project is purged' || (denial && !allowEmptyTombstoneReplay)) {
      return deny(denial);
    }
    return { ok: true, parentTask, childProjectId: currentProjectId };
  }

  const parentTaskId =
    Object.hasOwn(op.row, 'taskId') && typeof op.row.taskId === 'string' ? op.row.taskId : '';
  const parentTask = parentTaskId ? getTask(parentTaskId) : null;
  if (!parentTask) return deny('unknown-row');
  const currentProjectId = String(parentTask.row.projectId);
  const allowEmptyTaskTombstone =
    parentTask.purgedAt !== null && currentProjectId === '' && isScopeOwner;
  const denial = listWriteDenial(currentProjectId, access);
  if (denial === 'Project is purged' || (denial && !allowEmptyTaskTombstone)) {
    return deny(denial);
  }
  return { ok: true, parentTask, childProjectId: currentProjectId };
}
