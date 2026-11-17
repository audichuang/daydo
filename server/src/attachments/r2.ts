// Low-level R2 key layout and size/purge primitives for task attachments.
// Kept at the bottom of the import graph so sync, attachments, and serverops can all share it without cycles.
import { logEvent } from '../log';

export const MAX_ATTACHMENT_BYTES = 20 * 1024 * 1024;

export function attachmentObjectKey(taskId: string, attachmentId: string): string {
  return `att/${taskId}/${attachmentId}`;
}

export function attachmentTaskPrefix(taskId: string): string {
  return `att/${taskId}/`;
}

/**
 * Lists and deletes every R2 object under `att/<taskId>/`.
 * Best-effort: logs failures without throwing so task purge responses are unaffected.
 */
export async function deleteTaskAttachmentObjects(
  storage: R2Bucket,
  taskId: string,
): Promise<void> {
  try {
    const prefix = attachmentTaskPrefix(taskId);
    let cursor: string | undefined;
    do {
      const listed = await storage.list({ prefix, ...(cursor ? { cursor } : {}) });
      const keys = listed.objects.map((obj) => obj.key);
      if (keys.length > 0) {
        await storage.delete(keys);
      }
      cursor = listed.truncated ? listed.cursor : undefined;
    } while (cursor);
  } catch (err) {
    logEvent('error', 'attachment.purge.failed', {
      task_id: taskId,
      error: err instanceof Error ? err.message : String(err),
    });
  }
}
