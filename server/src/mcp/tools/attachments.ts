// Attachment tools (spec/mcp.md 8): upload_attachment, get_attachment.
import { attachmentObjectKey, MAX_ATTACHMENT_BYTES } from '../../attachments/r2';
import { uuidv7 } from '../../domain/uuid';
import { isNil } from '../../serverops/values';
import { assertHasData, WriteError, WriteValidationError, writeOrThrow } from '../../serverops/writer';
import { mcpResult, nowOf, requireStr, ToolValidationError, type ToolDef } from '../toolkit';
import { openSession, requireWritableList } from './projects';
import { taskIn } from './tasks';

const TEXT_LIMIT_BYTES = 1024 * 1024;
// Claude rejects images whose base64 payload exceeds 5 MB; base64 inflates bytes by 4/3.
const IMAGE_LIMIT_BYTES = 3_750_000;
const BINARY_LIMIT_BYTES = 1024 * 1024;

const IMAGE_MIMES = new Set(['image/png', 'image/jpeg', 'image/gif', 'image/webp']);
const TEXT_APPLICATION_MIMES = new Set([
  'application/json',
  'application/xml',
  'application/csv',
  'application/x-csv',
  'application/javascript',
  'application/ecmascript',
  'application/x-yaml',
  'application/yaml',
  'application/toml',
  'application/sql',
  'application/xhtml+xml',
]);

function normalizeMime(raw: string): string {
  return raw.split(';', 1)[0]!.trim().toLowerCase() || 'application/octet-stream';
}

function isTextMime(mime: string): boolean {
  return (
    mime.startsWith('text/') ||
    TEXT_APPLICATION_MIMES.has(mime) ||
    mime.endsWith('+json') ||
    mime.endsWith('+xml')
  );
}

function bytesToBase64(bytes: Uint8Array): string {
  const CHUNK = 0x4000;
  const parts: string[] = [];
  for (let i = 0; i < bytes.byteLength; i += CHUNK) {
    parts.push(String.fromCharCode(...bytes.subarray(i, i + CHUNK)));
  }
  return btoa(parts.join(''));
}

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
    {
      name: 'get_attachment',
      description:
        'Read an attachment\'s metadata and content. Caller must be a member of `project_id`, and the attachment must belong to `task_id` and not be deleted. Text files (text/*, JSON, XML, CSV) <= 1 MB return UTF-8 text; images (png, jpeg, gif, webp) <= 3.75 MB return MCP image content plus metadata; other files <= 1 MB return content_base64. Files over the size limit or not yet uploaded to storage return metadata with an explanation (not an error).',
      inputSchema: {
        type: 'object',
        required: ['project_id', 'task_id', 'attachment_id'],
        properties: {
          project_id: { type: 'string', description: 'Project id from list_projects.' },
          task_id: { type: 'string', description: 'Task id; the task must belong to `project_id`.' },
          attachment_id: { type: 'string', description: 'Attachment id from get_task.' },
        },
      },
      run: async (args, ctx) => {
        const projectId = requireStr(args, 'project_id');
        const taskId = requireStr(args, 'task_id');
        const attachmentId = requireStr(args, 'attachment_id');

        const { snapshot } = await openSession(ctx);
        taskIn(snapshot, taskId, projectId);
        const att = snapshot.findRow('attachment', attachmentId);
        if (!att) {
          throw new Error(`Unknown attachment_id '${attachmentId}'`);
        }
        if (att.row.taskId !== taskId) {
          throw new Error(`Attachment '${attachmentId}' does not belong to task '${taskId}'`);
        }
        if (!isNil(att.row.deletedAt) || !isNil(att.row.purgedAt)) {
          throw new Error(`Attachment '${attachmentId}' has been deleted`);
        }

        const storage = ctx.services?.storage;
        if (!storage) {
          throw new Error('Attachment storage is not configured');
        }

        const rawMime = String(att.row.mimeType ?? '').trim() || 'application/octet-stream';
        const normalizedMime = normalizeMime(rawMime);
        const declaredSize = Number(att.row.size ?? 0);
        const meta = {
          id: String(att.row.id),
          task_id: String(att.row.taskId),
          file_name: String(att.row.fileName ?? ''),
          size: declaredSize,
          mime_type: rawMime,
          created_at: Number(att.row.createdAt ?? 0),
        };

        const isImage = IMAGE_MIMES.has(normalizedMime);
        const isText = !isImage && isTextMime(normalizedMime);
        const limit = isImage ? IMAGE_LIMIT_BYTES : isText ? TEXT_LIMIT_BYTES : BINARY_LIMIT_BYTES;

        const notUploaded = () => ({
          ...meta,
          available: false,
          message: '檔案還沒上傳（Attachment file has not been uploaded yet）',
        });
        const tooLarge = (actualSize: number) => ({
          ...meta,
          available: true,
          too_large: true,
          max_bytes: limit,
          message: `Attachment is too large to read (${actualSize} bytes; maximum is ${limit} bytes)`,
        });

        const key = attachmentObjectKey(taskId, attachmentId);
        if (declaredSize > limit) {
          const head = await storage.head(key);
          if (!head) return notUploaded();
          if (head.size > limit) return tooLarge(head.size);
        }

        const obj = await storage.get(key);
        if (!obj) return notUploaded();
        if (obj.size > limit) {
          await obj.body?.cancel().catch(() => {});
          return tooLarge(obj.size);
        }

        const bytes = new Uint8Array(await obj.arrayBuffer());
        if (bytes.byteLength > limit) return tooLarge(bytes.byteLength);

        if (isImage) {
          return mcpResult([
            { type: 'text', text: JSON.stringify(meta) },
            { type: 'image', data: bytesToBase64(bytes), mimeType: normalizedMime },
          ]);
        }
        if (isText) {
          return { ...meta, content: new TextDecoder().decode(bytes) };
        }
        return { ...meta, content_base64: bytesToBase64(bytes) };
      },
    },
  ];
}
