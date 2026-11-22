// HTTP content upload and download for task attachments (spec/openapi.yaml).
import { entityHome } from '@schema';
import { and, eq } from 'void/db';
import { loadProjectAccess, requesterRoleOf } from '../membership';
import type { ScopeStub } from '../scope/api';
import { roleCanWrite } from '../sync/access';
import type { AppDb } from '../sync/push';
import { canReadAttachment } from './access';
import { attachmentObjectKey, MAX_ATTACHMENT_BYTES } from './r2';

function jsonError(status: number, error: string): Response {
  return new Response(JSON.stringify({ error }), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}

async function loadAttachmentAndAccess(
  db: AppDb,
  params: {
    attachmentId: string;
    userId: string;
    getScopeStub: (scope: string) => Pick<ScopeStub, 'getAttachmentInfo'>;
  },
) {
  const { attachmentId, userId, getScopeStub } = params;
  if (!attachmentId) return null;

  const homeRows = await db
    .select({ scope: entityHome.scope })
    .from(entityHome)
    .where(and(eq(entityHome.entity, 'attachment'), eq(entityHome.entityId, attachmentId)));
  const scope = homeRows[0]?.scope;
  if (!scope) return null;

  const info = await getScopeStub(scope).getAttachmentInfo({ attachmentId });
  if (!info) return null;

  const access = await loadProjectAccess(db, {
    projectId: info.projectId,
    requesterUserId: userId,
  });
  return { info, access };
}

type ReadBodyResult =
  | { ok: true; bytes: Uint8Array }
  | { ok: false; status: 400 | 413; error: string };

async function readBodyForSize(
  body: ReadableStream<Uint8Array> | null,
  expectedSize: number,
  maxBytes: number,
): Promise<ReadBodyResult> {
  if (!body) {
    return expectedSize === 0
      ? { ok: true, bytes: new Uint8Array(0) }
      : { ok: false, status: 400, error: 'size-mismatch' };
  }

  const out = new Uint8Array(expectedSize);
  const reader = body.getReader();
  let total = 0;

  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      const len = value.byteLength;
      if (total + len > maxBytes) {
        await reader.cancel().catch(() => {});
        return { ok: false, status: 413, error: 'payload-too-large' };
      }
      if (total + len <= expectedSize) {
        out.set(value, total);
      }
      total += len;
    }
  } finally {
    reader.releaseLock();
  }

  if (total !== expectedSize) {
    return { ok: false, status: 400, error: 'size-mismatch' };
  }
  return { ok: true, bytes: out };
}

export interface UploadAttachmentContentParams {
  attachmentId: string;
  userId: string;
  contentTypeHeader?: string;
  contentLengthHeader?: string;
  body: ReadableStream<Uint8Array> | null;
  getScopeStub: (scope: string) => Pick<ScopeStub, 'getAttachmentInfo'>;
  storage: R2Bucket | null;
}

export async function uploadAttachmentContent(
  db: AppDb,
  params: UploadAttachmentContentParams,
): Promise<Response> {
  const {
    attachmentId,
    userId,
    contentTypeHeader,
    contentLengthHeader,
    body,
    getScopeStub,
    storage,
  } = params;

  const loaded = await loadAttachmentAndAccess(db, { attachmentId, userId, getScopeStub });
  if (!loaded) return jsonError(404, 'attachment-not-found');

  const { info, access } = loaded;
  const role = requesterRoleOf(access);
  if (!roleCanWrite(role)) {
    return jsonError(403, 'Forbidden');
  }

  if (
    access.purged ||
    info.deletedAt !== null ||
    info.purgedAt !== null ||
    info.taskPurgedAt !== null
  ) {
    return jsonError(410, 'attachment-deleted');
  }

  if (!Number.isInteger(info.size) || info.size < 0) {
    return jsonError(400, 'size-mismatch');
  }
  if (info.size > MAX_ATTACHMENT_BYTES) {
    return jsonError(413, 'payload-too-large');
  }

  const trimmedLength = contentLengthHeader?.trim();
  if (trimmedLength !== undefined && trimmedLength !== '') {
    if (!/^\d+$/.test(trimmedLength)) {
      return jsonError(400, 'size-mismatch');
    }
    const declared = Number(trimmedLength);
    if (declared > MAX_ATTACHMENT_BYTES) {
      return jsonError(413, 'payload-too-large');
    }
    if (declared !== info.size) {
      return jsonError(400, 'size-mismatch');
    }
  }

  const read = await readBodyForSize(body, info.size, MAX_ATTACHMENT_BYTES);
  if (!read.ok) {
    return jsonError(read.status, read.error);
  }

  if (!storage) {
    throw new Error('Attachment storage is not configured');
  }

  const contentType = contentTypeHeader?.trim() || info.mimeType || 'application/octet-stream';
  await storage.put(attachmentObjectKey(info.taskId, info.id), read.bytes, {
    httpMetadata: { contentType },
  });

  return new Response(null, { status: 204 });
}

export interface DownloadAttachmentContentParams {
  attachmentId: string;
  userId: string;
  getScopeStub: (scope: string) => Pick<ScopeStub, 'getAttachmentInfo'>;
  storage: R2Bucket | null;
}

export async function downloadAttachmentContent(
  db: AppDb,
  params: DownloadAttachmentContentParams,
): Promise<Response> {
  const { attachmentId, userId, getScopeStub, storage } = params;

  const loaded = await loadAttachmentAndAccess(db, { attachmentId, userId, getScopeStub });
  if (!loaded) return jsonError(404, 'attachment-not-found');

  const { info, access } = loaded;
  const denial = canReadAttachment({
    role: requesterRoleOf(access),
    projectPurged: access.purged,
    task: { projectId: info.projectId, purgedAt: info.taskPurgedAt },
    attachment: { taskId: info.taskId, deletedAt: info.deletedAt, purgedAt: info.purgedAt },
  });
  if (denial === 'not-member') {
    return jsonError(403, 'Forbidden');
  }
  if (denial !== null) {
    return jsonError(404, 'attachment-not-found');
  }

  if (!storage) {
    throw new Error('Attachment storage is not configured');
  }

  const object = await storage.get(attachmentObjectKey(info.taskId, info.id));
  if (!object) {
    return jsonError(404, 'attachment-not-found');
  }

  return new Response(object.body ?? new Uint8Array(0), {
    status: 200,
    headers: {
      'Content-Type': info.mimeType || 'application/octet-stream',
      'Content-Length': String(object.size),
      'X-Content-Type-Options': 'nosniff',
    },
  });
}
