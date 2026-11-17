// Attachment upload tool (spec/mcp.md 8): upload_attachment.
import { attachmentObjectKey, MAX_ATTACHMENT_BYTES } from '../../attachments/r2';
import { uuidv7 } from '../../domain/uuid';
import { assertHasData, WriteError, WriteValidationError, writeOrThrow } from '../../serverops/writer';
import { nowOf, requireStr, ToolValidationError, type ToolDef } from '../toolkit';
import { openSession, requireWritableList } from './projects';
import { taskIn } from './tasks';

const BASE64_RE = /^[A-Za-z0-9+/]+={0,2}$/;

function decodeBase64(raw: string): Uint8Array {
  const stripped = raw.replace(/\s+/g, '');
  const mod = stripped.length % 4;
  if (stripped.length === 0 || mod === 1) {
    throw new ToolValidationError('content_base64', "Argument 'content_base64' must be valid base64");
  }
  const padded = mod === 0 ? stripped : stripped + '='.repeat(4 - mod);
  const padding = padded.endsWith('==') ? 2 : padded.endsWith('=') ? 1 : 0;
  const decodedLength = (padded.length / 4) * 3 - padding;
  if (decodedLength > MAX_ATTACHMENT_BYTES) {
    throw new ToolValidationError(
      'content_base64',
      `Attachment exceeds maximum size of 20 MB (${MAX_ATTACHMENT_BYTES} bytes)`,
    );
  }
  if (!BASE64_RE.test(padded)) {
    throw new ToolValidationError('content_base64', "Argument 'content_base64' must be valid base64");
  }
  const bin = atob(padded);
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i += 1) {
    bytes[i] = bin.charCodeAt(i);
  }
  return bytes;
}

function parseContentType(raw: unknown): string {
  if (raw === undefined || raw === null) return 'application/octet-stream';
  if (typeof raw !== 'string') {
    throw new ToolValidationError('content_type', "Argument 'content_type' must be a string");
  }
  return raw.trim() || 'application/octet-stream';
}

export function attachmentTools(): ToolDef[] {
  return [
    {
      name: 'upload_attachment',
      description:
        'Upload a file attachment to an existing task. Encode the file bytes as base64 in `content_base64`. Maximum decoded file size is 20 MB (20,971,520 bytes). The task must belong to `project_id` and the project must be writable.',
      inputSchema: {
        type: 'object',
        required: ['project_id', 'task_id', 'content_base64', 'filename'],
        properties: {
          project_id: { type: 'string', description: 'Project id from list_projects.' },
          task_id: { type: 'string', description: 'Target task id; the task must belong to `project_id`.' },
          content_base64: {
            type: 'string',
            description: 'File content encoded as base64 (maximum 20 MB / 20,971,520 bytes after decoding).',
          },
          filename: { type: 'string', description: 'Attachment file name (e.g. notes.txt).' },
          content_type: {
            type: 'string',
            description: 'Optional MIME type of the file. Defaults to application/octet-stream.',
          },
        },
      },
      run: async (args, ctx) => {
        const projectId = requireStr(args, 'project_id');
        const taskId = requireStr(args, 'task_id');
        const contentBase64 = requireStr(args, 'content_base64');
        const filename = requireStr(args, 'filename');
        const safeName = filename.replaceAll('/', '_');
        const contentType = parseContentType(args.content_type);
        const bytes = decodeBase64(contentBase64);

        const { snapshot, deps } = await openSession(ctx);
        assertHasData(snapshot);
        taskIn(snapshot, taskId, projectId);
        requireWritableList(snapshot, projectId);

        const storage = ctx.services?.storage;
        if (!storage) {
          throw new Error('Attachment storage is not configured');
        }

        const now = nowOf(ctx);
        const id = uuidv7(now);
        const key = attachmentObjectKey(taskId, id);
        await storage.put(key, bytes, { httpMetadata: { contentType } });

        let outcomes;
        try {
          outcomes = await writeOrThrow(
            deps,
            snapshot,
            [
              {
                entity: 'attachment',
                entityId: id,
                set: {
                  id,
                  taskId,
                  fileName: safeName,
                  size: bytes.byteLength,
                  mimeType: contentType,
                },
              },
            ],
            { nowMs: now },
          );
        } catch (err) {
          // Only compensate when we know the row was not written; on RPC/network errors the DO may
          // have committed before the response was lost, so keep the R2 object.
          const definitelyNotWritten =
            err instanceof WriteValidationError ||
            (err instanceof WriteError &&
              (err.outcome.status === 'rejected' || err.outcome.status === 'purged'));
          if (definitelyNotWritten) {
            await storage.delete(key).catch(() => {});
          }
          throw err;
        }

        const row = outcomes[0]!.row!;
        return {
          id: String(row.id),
          file_name: String(row.fileName),
          size: Number(row.size),
          mime_type: String(row.mimeType),
          created_at: Number(row.createdAt),
        };
      },
    },
  ];
}
