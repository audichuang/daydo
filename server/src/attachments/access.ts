// Shared attachment read authorization used by HTTP download and MCP get_attachment.

export type AttachmentReadDenial =
  | 'not-member'
  | 'project-purged'
  | 'task-missing'
  | 'task-purged'
  | 'task-wrong-project'
  | 'attachment-missing'
  | 'attachment-wrong-task'
  | 'attachment-deleted';

export interface CanReadAttachmentInput {
  /** Caller's role on the project (`null` / `undefined` when not a member). */
  role: string | null | undefined;
  /** Whether the project itself has been permanently deleted (purged). */
  projectPurged: boolean;
  /** Task state (`null` when the task row does not exist). */
  task: { projectId: string; purgedAt: unknown } | null;
  /** Attachment state (`null` when the attachment row does not exist). */
  attachment: { taskId: string; deletedAt: unknown; purgedAt: unknown } | null;
  /** When set, requires `task.projectId === expectedProjectId`. */
  expectedProjectId?: string;
  /** When set, requires `attachment.taskId === expectedTaskId`. */
  expectedTaskId?: string;
}

/**
 * Checks whether a caller may read an attachment given its list membership, task, and attachment row.
 * Trashed tasks and archived lists remain readable as long as the caller is a member and neither the
 * project, task, nor attachment is purged (and the attachment itself is not deleted).
 */
export function canReadAttachment(input: CanReadAttachmentInput): AttachmentReadDenial | null {
  if (!input.role) return 'not-member';
  if (input.projectPurged) return 'project-purged';
  if (!input.task) return 'task-missing';
  if (input.task.purgedAt != null) return 'task-purged';
  if (input.expectedProjectId !== undefined && input.task.projectId !== input.expectedProjectId) {
    return 'task-wrong-project';
  }
  if (!input.attachment) return 'attachment-missing';
  if (input.expectedTaskId !== undefined && input.attachment.taskId !== input.expectedTaskId) {
    return 'attachment-wrong-task';
  }
  if (input.attachment.deletedAt != null || input.attachment.purgedAt != null) {
    return 'attachment-deleted';
  }
  return null;
}
