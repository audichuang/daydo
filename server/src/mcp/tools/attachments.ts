// Attachment tools (spec/mcp.md 8): upload_attachment, get_attachment.
import { canReadAttachment } from '../../attachments/access';
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

function sniffImageMime(header: Uint8Array): string | null {
  if (
    header.length >= 8 &&
    header[0] === 0x89 &&
    header[1] === 0x50 &&
    header[2] === 0x4e &&
    header[3] === 0x47 &&
    header[4] === 0x0d &&
    header[5] === 0x0a &&
    header[6] === 0x1a &&
    header[7] === 0x0a
  ) {
    return 'image/png';
  }
  if (header.length >= 3 && header[0] === 0xff && header[1] === 0xd8 && header[2] === 0xff) {
    return 'image/jpeg';
  }
  if (
    header.length >= 6 &&
    header[0] === 0x47 &&
    header[1] === 0x49 &&
    header[2] === 0x46 &&
    header[3] === 0x38 &&
    (header[4] === 0x37 || header[4] === 0x39) &&
    header[5] === 0x61
  ) {
    return 'image/gif';
  }
  if (
    header.length >= 12 &&
    header[0] === 0x52 &&
    header[1] === 0x49 &&
    header[2] === 0x46 &&
    header[3] === 0x46 &&
    header[8] === 0x57 &&
    header[9] === 0x45 &&
    header[10] === 0x42 &&
    header[11] === 0x50
  ) {
    return 'image/webp';
  }
  return null;
}

function parseCharset(rawMime: string): string | null {
  for (const part of rawMime.split(';').slice(1)) {
    const eq = part.indexOf('=');
    if (eq === -1) continue;
    if (part.slice(0, eq).trim().toLowerCase() !== 'charset') continue;
    let val = part.slice(eq + 1).trim();
    if (
      (val.startsWith('"') && val.endsWith('"') && val.length >= 2) ||
      (val.startsWith("'") && val.endsWith("'") && val.length >= 2)
    ) {
      val = val.slice(1, -1).trim();
    }
    return val || null;
  }
  return null;
}

function decodeText(bytes: Uint8Array, charset: string | null): { ok: true; text: string } | { ok: false; note: string } {
  // Check 4-byte UTF-32 BOMs before 2-byte UTF-16 BOMs (FF FE 00 00 starts with FF FE).
  if (bytes.length >= 4 && bytes[0] === 0xff && bytes[1] === 0xfe && bytes[2] === 0x00 && bytes[3] === 0x00) {
    return { ok: false, note: "Unsupported encoding 'UTF-32LE' (BOM); returned as base64." };
  }
  if (bytes.length >= 4 && bytes[0] === 0x00 && bytes[1] === 0x00 && bytes[2] === 0xfe && bytes[3] === 0xff) {
    return { ok: false, note: "Unsupported encoding 'UTF-32BE' (BOM); returned as base64." };
  }

  let encoding = charset ?? 'utf-8';
  let slice = bytes;
  let bomLabel: string | null = null;
  if (bytes.length >= 3 && bytes[0] === 0xef && bytes[1] === 0xbb && bytes[2] === 0xbf) {
    encoding = 'utf-8';
    slice = bytes.subarray(3);
    bomLabel = 'UTF-8';
  } else if (bytes.length >= 2 && bytes[0] === 0xff && bytes[1] === 0xfe) {
    encoding = 'utf-16le';
    slice = bytes.subarray(2);
    bomLabel = 'UTF-16LE';
  } else if (bytes.length >= 2 && bytes[0] === 0xfe && bytes[1] === 0xff) {
    encoding = 'utf-16be';
    slice = bytes.subarray(2);
    bomLabel = 'UTF-16BE';
  }

  if (/^utf-?32(?:le|be)?$/i.test(encoding.trim())) {
    return { ok: false, note: `Unsupported charset '${encoding}'; returned as base64.` };
  }

  try {
    return { ok: true, text: new TextDecoder(encoding, { fatal: true }).decode(slice) };
  } catch (err) {
    if (err instanceof RangeError) {
      return { ok: false, note: `Unsupported charset '${encoding}'; returned as base64.` };
    }
    const label = bomLabel ? `${bomLabel} (BOM)` : encoding.toUpperCase();
    return { ok: false, note: `Unable to decode attachment as ${label}; returned as base64.` };
  }
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
        'Read an attachment\'s metadata and content. Caller must be a member of `project_id`, and the attachment must belong to `task_id` and not be deleted. Text files (text/*, JSON, XML, CSV; decoded via BOM/charset or UTF-8, falling back to content_base64 with encoding_note if undecodable) <= 1 MB return text; images (png, jpeg, gif, webp, including generic application/octet-stream files whose header matches those image types) <= 3.75 MB return MCP image content plus metadata; other files <= 1 MB return content_base64. Files over the size limit or not yet uploaded to storage return metadata with an explanation (not an error).',
      inputSchema: {
        type: 'object',
        required: ['project_id', 'task_id', 'attachment_id'],
        properties: {
          project_id: { type: 'string', description: 'Project id from list_projects.' },
          task_id: { type: 'string', description: 'Task id; the task must belong to `project_id`.' },
          attachment_id: {
            type: 'string',
            description:
              'Attachment id from get_task (pass include_deleted: true to get_task for trashed tasks or tasks in archived lists).',
          },
        },
      },
      run: async (args, ctx) => {
        const projectId = requireStr(args, 'project_id');
        const taskId = requireStr(args, 'task_id');
        const attachmentId = requireStr(args, 'attachment_id');

        const { snapshot } = await openSession(ctx);
        const project = snapshot.findRow('project', projectId);
        const task = snapshot.findRow('task', taskId);
        const att = snapshot.findRow('attachment', attachmentId);
        const denial = canReadAttachment({
          role: project ? (snapshot.memberships.get(projectId) ?? null) : null,
          projectPurged: project ? !isNil(project.row.purgedAt) : false,
          task: task ? { projectId: String(task.row.projectId ?? ''), purgedAt: task.row.purgedAt } : null,
          attachment: att
            ? { taskId: String(att.row.taskId ?? ''), deletedAt: att.row.deletedAt, purgedAt: att.row.purgedAt }
            : null,
          expectedProjectId: projectId,
          expectedTaskId: taskId,
        });
        if (denial !== null) {
          switch (denial) {
            case 'not-member':
              throw new Error(`Unknown project_id '${projectId}'; call list_projects first`);
            case 'project-purged':
              throw new Error(`Project '${projectId}' was permanently deleted`);
            case 'task-missing':
              throw new Error(`Unknown task_id '${taskId}'`);
            case 'task-purged':
              throw new Error(`Task '${taskId}' was permanently deleted`);
            case 'task-wrong-project':
              throw new Error(
                `Task '${taskId}' is not in project '${projectId}' (it is in '${String(task!.row.projectId)}')`,
              );
            case 'attachment-missing':
              throw new Error(`Unknown attachment_id '${attachmentId}'`);
            case 'attachment-wrong-task':
              throw new Error(`Attachment '${attachmentId}' does not belong to task '${taskId}'`);
            case 'attachment-deleted':
              throw new Error(`Attachment '${attachmentId}' has been deleted`);
          }
        }
        const attRow = att!;

        const storage = ctx.services?.storage;
        if (!storage) {
          throw new Error('Attachment storage is not configured');
        }

        const rawMime = String(attRow.row.mimeType ?? '').trim() || 'application/octet-stream';
        const normalizedMime = normalizeMime(rawMime);
        const declaredSize = Number(attRow.row.size ?? 0);
        const meta = {
          id: String(attRow.row.id),
          task_id: String(attRow.row.taskId),
          file_name: String(attRow.row.fileName ?? ''),
          size: declaredSize,
          mime_type: rawMime,
          created_at: Number(attRow.row.createdAt ?? 0),
        };

        const notUploaded = () => ({
          ...meta,
          available: false,
          message: '檔案還沒上傳（Attachment file has not been uploaded yet）',
        });
        const tooLarge = (actualSize: number, limit: number) => ({
          ...meta,
          available: true,
          too_large: true,
          max_bytes: limit,
          message: `Attachment is too large to read (${actualSize} bytes; maximum is ${limit} bytes)`,
        });

        const key = attachmentObjectKey(taskId, attachmentId);
        let effectiveMime = normalizedMime;
        let preloadedBytes: Uint8Array | null = null;

        if (normalizedMime === 'application/octet-stream' && declaredSize > 0) {
          const headObj = await storage.get(key, { range: { offset: 0, length: 16 } });
          if (!headObj) return notUploaded();
          const header = new Uint8Array(await headObj.arrayBuffer());
          const sniffed = sniffImageMime(header);
          if (sniffed !== null) {
            effectiveMime = sniffed;
          }
          const sniffLimit = sniffed !== null ? IMAGE_LIMIT_BYTES : BINARY_LIMIT_BYTES;
          if (headObj.size > sniffLimit) return tooLarge(headObj.size, sniffLimit);
          if (headObj.size <= header.byteLength) {
            preloadedBytes = header;
          }
        }

        const isImage = IMAGE_MIMES.has(effectiveMime);
        const isText = !isImage && isTextMime(effectiveMime);
        const limit = isImage ? IMAGE_LIMIT_BYTES : isText ? TEXT_LIMIT_BYTES : BINARY_LIMIT_BYTES;

        let bytes: Uint8Array;
        if (preloadedBytes !== null) {
          bytes = preloadedBytes;
        } else {
          if (declaredSize > limit) {
            const head = await storage.head(key);
            if (!head) return notUploaded();
            if (head.size > limit) return tooLarge(head.size, limit);
          }

          const obj = await storage.get(key);
          if (!obj) return notUploaded();
          if (obj.size > limit) {
            await obj.body?.cancel().catch(() => {});
            return tooLarge(obj.size, limit);
          }

          bytes = new Uint8Array(await obj.arrayBuffer());
          if (bytes.byteLength > limit) return tooLarge(bytes.byteLength, limit);
        }

        if (isImage) {
          return mcpResult([
            { type: 'text', text: JSON.stringify(meta) },
            { type: 'image', data: bytesToBase64(bytes), mimeType: effectiveMime },
          ]);
        }
        if (isText) {
          const decoded = decodeText(bytes, parseCharset(rawMime));
          if (decoded.ok) {
            return { ...meta, content: decoded.text };
          }
          return { ...meta, content_base64: bytesToBase64(bytes), encoding_note: decoded.note };
        }
        return { ...meta, content_base64: bytesToBase64(bytes) };
      },
    },
  ];
}
