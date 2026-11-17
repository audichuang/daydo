import { describe, expect, it, vi } from 'vitest';
import { downloadAttachmentContent, uploadAttachmentContent } from '../src/attachments/content';
import { attachmentObjectKey, MAX_ATTACHMENT_BYTES } from '../src/attachments/r2';
import { NO_DATA_MESSAGE } from '../src/serverops/writer';
import { createInvite, acceptInvite } from '../src/sharing';
import {
  call,
  createServerHarness,
  deviceOp,
  NOW_ISH,
  projectRow,
  pulled,
  seedBasic,
  seedUser,
  taskRow,
} from './helpers/serverHarness';

function attachmentRow(
  id: string,
  taskId: string,
  size: number,
  extra: Record<string, unknown> = {},
) {
  return {
    id,
    taskId,
    fileName: 'photo.png',
    size,
    mimeType: 'image/png',
    createdAt: NOW_ISH,
    updatedAt: NOW_ISH,
    ...extra,
  };
}

function streamOf(chunks: Uint8Array[]): ReadableStream<Uint8Array> {
  return new ReadableStream<Uint8Array>({
    start(controller) {
      for (const c of chunks) controller.enqueue(c);
      controller.close();
    },
  });
}

async function seedAttachment(
  h: ReturnType<typeof createServerHarness>,
  id: string,
  taskId: string,
  size: number,
  extra: Record<string, unknown> = {},
) {
  const res = await h.devicePush('u-a', [
    deviceOp(h, 'attachment', attachmentRow(id, taskId, size, extra)),
  ]);
  expect(res.results[0]?.status).toBe('applied');
}

async function shareWith(
  h: ReturnType<typeof createServerHarness>,
  projectId: string,
  targetUserId: string,
  targetMemberId: string,
  role: 'editor' | 'viewer',
) {
  await seedUser(h, targetUserId, targetMemberId);
  const inv = await createInvite(h.db, {
    projectId,
    userId: 'u-a',
    role,
    nowMs: NOW_ISH,
  });
  await acceptInvite(h.db, {
    code: inv.code,
    userId: targetUserId,
    nowMs: NOW_ISH,
    getScopeStub: h.getScopeStub,
  });
}

describe('attachment HTTP content endpoints', () => {
  it('uploads bytes and lets members download with row Content-Type and Content-Length', async () => {
    const h = createServerHarness();
    await seedBasic(h);
    const bytes = new TextEncoder().encode('hello attachment bytes');
    await seedAttachment(h, 'att-1', 't1', bytes.byteLength, { mimeType: 'text/plain' });

    await shareWith(h, 'p1', 'u-b', 'm-b', 'editor');
    await shareWith(h, 'p1', 'u-c', 'm-c', 'viewer');

    const putRes = await uploadAttachmentContent(h.db, {
      attachmentId: 'att-1',
      userId: 'u-a',
      contentTypeHeader: 'application/octet-stream',
      contentLengthHeader: String(bytes.byteLength),
      body: streamOf([bytes]),
      getScopeStub: h.getScopeStub,
      storage: h.storage,
    });
    expect(putRes.status).toBe(204);
    expect(h.storage.keys()).toEqual([attachmentObjectKey('t1', 'att-1')]);

    // Editor and viewer can both download; Content-Type comes from the attachment row.
    for (const reader of ['u-a', 'u-b', 'u-c']) {
      const getRes = await downloadAttachmentContent(h.db, {
        attachmentId: 'att-1',
        userId: reader,
        getScopeStub: h.getScopeStub,
        storage: h.storage,
      });
      expect(getRes.status).toBe(200);
      expect(getRes.headers.get('Content-Type')).toBe('text/plain');
      expect(getRes.headers.get('Content-Length')).toBe(String(bytes.byteLength));
      expect(new Uint8Array(await getRes.arrayBuffer())).toEqual(bytes);
    }

    // Re-uploading overwrites the same key idempotently.
    const nextBytes = new TextEncoder().encode('updated-attachment-222');
    const overwriteRes = await uploadAttachmentContent(h.db, {
      attachmentId: 'att-1',
      userId: 'u-b',
      body: streamOf([nextBytes]),
      getScopeStub: h.getScopeStub,
      storage: h.storage,
    });
    expect(overwriteRes.status).toBe(204);
    const afterOverwrite = await downloadAttachmentContent(h.db, {
      attachmentId: 'att-1',
      userId: 'u-a',
      getScopeStub: h.getScopeStub,
      storage: h.storage,
    });
    expect(new Uint8Array(await afterOverwrite.arrayBuffer())).toEqual(nextBytes);
  });

  it('rejects non-members (403 on PUT & GET) and viewers (403 on PUT)', async () => {
    const h = createServerHarness();
    await seedBasic(h);
    const bytes = new TextEncoder().encode('secret');
    await seedAttachment(h, 'att-1', 't1', bytes.byteLength);
    await seedUser(h, 'u-stranger', 'm-stranger');
    await shareWith(h, 'p1', 'u-viewer', 'm-viewer', 'viewer');

    await uploadAttachmentContent(h.db, {
      attachmentId: 'att-1',
      userId: 'u-a',
      body: streamOf([bytes]),
      getScopeStub: h.getScopeStub,
      storage: h.storage,
    });

    const strangerPut = await uploadAttachmentContent(h.db, {
      attachmentId: 'att-1',
      userId: 'u-stranger',
      body: streamOf([bytes]),
      getScopeStub: h.getScopeStub,
      storage: h.storage,
    });
    expect(strangerPut.status).toBe(403);

    const strangerGet = await downloadAttachmentContent(h.db, {
      attachmentId: 'att-1',
      userId: 'u-stranger',
      getScopeStub: h.getScopeStub,
      storage: h.storage,
    });
    expect(strangerGet.status).toBe(403);

    const viewerPut = await uploadAttachmentContent(h.db, {
      attachmentId: 'att-1',
      userId: 'u-viewer',
      body: streamOf([bytes]),
      getScopeStub: h.getScopeStub,
      storage: h.storage,
    });
    expect(viewerPut.status).toBe(403);
  });

  it('returns 404 for unknown attachment id and when R2 object is not yet uploaded', async () => {
    const h = createServerHarness();
    await seedBasic(h);

    const putUnknown = await uploadAttachmentContent(h.db, {
      attachmentId: 'att-missing',
      userId: 'u-a',
      body: streamOf([new Uint8Array(4)]),
      getScopeStub: h.getScopeStub,
      storage: h.storage,
    });
    expect(putUnknown.status).toBe(404);
    expect(await putUnknown.json()).toEqual({ error: 'attachment-not-found' });

    const getUnknown = await downloadAttachmentContent(h.db, {
      attachmentId: 'att-missing',
      userId: 'u-a',
      getScopeStub: h.getScopeStub,
      storage: h.storage,
    });
    expect(getUnknown.status).toBe(404);

    // Row exists in DO, but R2 file has not been uploaded yet.
    await seedAttachment(h, 'att-unloaded', 't1', 5);
    const getBeforeUpload = await downloadAttachmentContent(h.db, {
      attachmentId: 'att-unloaded',
      userId: 'u-a',
      getScopeStub: h.getScopeStub,
      storage: h.storage,
    });
    expect(getBeforeUpload.status).toBe(404);
  });

  it('returns 410 on PUT and 404 on GET for soft-deleted attachments without deleting R2', async () => {
    const h = createServerHarness();
    await seedBasic(h);
    const bytes = new TextEncoder().encode('keep-in-r2');
    await seedAttachment(h, 'att-1', 't1', bytes.byteLength);

    const putOk = await uploadAttachmentContent(h.db, {
      attachmentId: 'att-1',
      userId: 'u-a',
      body: streamOf([bytes]),
      getScopeStub: h.getScopeStub,
      storage: h.storage,
    });
    expect(putOk.status).toBe(204);

    const softDel = await h.devicePush('u-a', [
      deviceOp(h, 'attachment', { id: 'att-1', deletedAt: NOW_ISH + 1000, updatedAt: NOW_ISH + 1000 }),
    ]);
    expect(softDel.results[0]?.status).toBe('applied');

    // Soft-deleted attachment keeps its R2 object.
    expect(h.storage.keys()).toEqual([attachmentObjectKey('t1', 'att-1')]);

    const putDeleted = await uploadAttachmentContent(h.db, {
      attachmentId: 'att-1',
      userId: 'u-a',
      body: streamOf([bytes]),
      getScopeStub: h.getScopeStub,
      storage: h.storage,
    });
    expect(putDeleted.status).toBe(410);
    expect(await putDeleted.json()).toEqual({ error: 'attachment-deleted' });

    const getDeleted = await downloadAttachmentContent(h.db, {
      attachmentId: 'att-1',
      userId: 'u-a',
      getScopeStub: h.getScopeStub,
      storage: h.storage,
    });
    expect(getDeleted.status).toBe(404);
  });

  it('returns 410 on PUT and 404 on GET when task or project is permanently deleted', async () => {
    const h = createServerHarness();
    await seedBasic(h);
    const bytes = new TextEncoder().encode('bye');
    await seedAttachment(h, 'att-1', 't1', bytes.byteLength);

    const purgeTask = await h.devicePush('u-a', [
      {
        opId: 'purge-t1',
        hlc: h.deviceHlc(),
        entity: 'task',
        entityId: 't1',
        op: 'delete',
        fields: [],
        row: {},
      },
    ]);
    expect(purgeTask.results[0]?.status).toBe('applied');

    const putPurged = await uploadAttachmentContent(h.db, {
      attachmentId: 'att-1',
      userId: 'u-a',
      body: streamOf([bytes]),
      getScopeStub: h.getScopeStub,
      storage: h.storage,
    });
    expect(putPurged.status).toBe(410);
    expect(await putPurged.json()).toEqual({ error: 'attachment-deleted' });

    const getPurged = await downloadAttachmentContent(h.db, {
      attachmentId: 'att-1',
      userId: 'u-a',
      getScopeStub: h.getScopeStub,
      storage: h.storage,
    });
    expect(getPurged.status).toBe(404);

    // Also test whole-project purge for an attachment on a task in another project p2.
    await h.devicePush('u-a', [
      deviceOp(h, 'project', projectRow('p2')),
      deviceOp(h, 'task', taskRow('t2', 'p2')),
      deviceOp(h, 'attachment', attachmentRow('att-2', 't2', bytes.byteLength)),
    ]);
    await h.devicePush('u-a', [
      {
        opId: 'purge-p2',
        hlc: h.deviceHlc(),
        entity: 'project',
        entityId: 'p2',
        op: 'delete',
        fields: [],
        row: {},
      },
    ]);

    const putProjectPurged = await uploadAttachmentContent(h.db, {
      attachmentId: 'att-2',
      userId: 'u-a',
      body: streamOf([bytes]),
      getScopeStub: h.getScopeStub,
      storage: h.storage,
    });
    expect(putProjectPurged.status).toBe(410);
    expect(await putProjectPurged.json()).toEqual({ error: 'attachment-deleted' });
  });

  it('rejects > 20 MB with 413 and size mismatch with 400 without overwriting R2', async () => {
    const h = createServerHarness();
    await seedBasic(h);
    const validBytes = new TextEncoder().encode('original');
    await seedAttachment(h, 'att-1', 't1', validBytes.byteLength);
    await uploadAttachmentContent(h.db, {
      attachmentId: 'att-1',
      userId: 'u-a',
      body: streamOf([validBytes]),
      getScopeStub: h.getScopeStub,
      storage: h.storage,
    });

    // 1. Mismatched Content-Length header
    const mismatchHeader = await uploadAttachmentContent(h.db, {
      attachmentId: 'att-1',
      userId: 'u-a',
      contentLengthHeader: String(validBytes.byteLength + 1),
      body: streamOf([new Uint8Array(validBytes.byteLength + 1)]),
      getScopeStub: h.getScopeStub,
      storage: h.storage,
    });
    expect(mismatchHeader.status).toBe(400);
    expect(await mismatchHeader.json()).toEqual({ error: 'size-mismatch' });

    // 2. Mismatched streamed body (no Content-Length)
    const mismatchStream = await uploadAttachmentContent(h.db, {
      attachmentId: 'att-1',
      userId: 'u-a',
      body: streamOf([new Uint8Array(validBytes.byteLength - 1)]),
      getScopeStub: h.getScopeStub,
      storage: h.storage,
    });
    expect(mismatchStream.status).toBe(400);
    expect(await mismatchStream.json()).toEqual({ error: 'size-mismatch' });
    expect(h.storage.rawBytes(attachmentObjectKey('t1', 'att-1'))).toEqual(validBytes);

    // 3. > 20 MB via Content-Length header
    const tooLargeHeader = await uploadAttachmentContent(h.db, {
      attachmentId: 'att-1',
      userId: 'u-a',
      contentLengthHeader: String(MAX_ATTACHMENT_BYTES + 1),
      body: streamOf([]),
      getScopeStub: h.getScopeStub,
      storage: h.storage,
    });
    expect(tooLargeHeader.status).toBe(413);

    // 4. > 20 MB via chunked stream without Content-Length
    const oneMb = new Uint8Array(1024 * 1024);
    const chunks21 = Array.from({ length: 21 }, () => oneMb);
    const tooLargeStream = await uploadAttachmentContent(h.db, {
      attachmentId: 'att-1',
      userId: 'u-a',
      body: streamOf(chunks21),
      getScopeStub: h.getScopeStub,
      storage: h.storage,
    });
    expect(tooLargeStream.status).toBe(413);

    // 5. Row declared size > 20 MB
    await seedAttachment(h, 'att-huge', 't1', MAX_ATTACHMENT_BYTES + 1);
    const tooLargeRow = await uploadAttachmentContent(h.db, {
      attachmentId: 'att-huge',
      userId: 'u-a',
      body: streamOf([]),
      getScopeStub: h.getScopeStub,
      storage: h.storage,
    });
    expect(tooLargeRow.status).toBe(413);
  });

  it('follows the parent task when moved across lists', async () => {
    const h = createServerHarness();
    await seedBasic(h);
    await h.devicePush('u-a', [deviceOp(h, 'project', projectRow('p-priv'))]);
    await shareWith(h, 'p1', 'u-b', 'm-b', 'editor');

    const bytes = new TextEncoder().encode('moved-content');
    await seedAttachment(h, 'att-1', 't1', bytes.byteLength);
    await uploadAttachmentContent(h.db, {
      attachmentId: 'att-1',
      userId: 'u-a',
      body: streamOf([bytes]),
      getScopeStub: h.getScopeStub,
      storage: h.storage,
    });

    // Move t1 from shared p1 to private p-priv.
    const moveRes = await h.devicePush('u-a', [
      deviceOp(h, 'task', { id: 't1', projectId: 'p-priv', updatedAt: NOW_ISH + 500 }),
    ]);
    expect(moveRes.results[0]?.status).toBe('applied');

    const bGet = await downloadAttachmentContent(h.db, {
      attachmentId: 'att-1',
      userId: 'u-b',
      getScopeStub: h.getScopeStub,
      storage: h.storage,
    });
    expect(bGet.status).toBe(403);

    const aGet = await downloadAttachmentContent(h.db, {
      attachmentId: 'att-1',
      userId: 'u-a',
      getScopeStub: h.getScopeStub,
      storage: h.storage,
    });
    expect(aGet.status).toBe(200);
    expect(new Uint8Array(await aGet.arrayBuffer())).toEqual(bytes);
  });
});

describe('task purge R2 cleanup', () => {
  it('deletes all att/<taskId>/ objects on task op=delete while keeping other tasks', async () => {
    const h = createServerHarness();
    await seedBasic(h);
    await h.devicePush('u-a', [deviceOp(h, 'task', taskRow('t2', 'p1'))]);

    await h.storage.put(attachmentObjectKey('t1', 'a1'), new Uint8Array([1, 2]));
    await h.storage.put(attachmentObjectKey('t1', 'a2'), new Uint8Array([3, 4]));
    await h.storage.put(attachmentObjectKey('t2', 'b1'), new Uint8Array([5, 6]));

    const res = await h.devicePush('u-a', [
      {
        opId: 'purge-t1',
        hlc: h.deviceHlc(),
        entity: 'task',
        entityId: 't1',
        op: 'delete',
        fields: [],
        row: {},
      },
    ]);
    expect(res.results[0]?.status).toBe('applied');
    expect(h.storage.keys()).toEqual([attachmentObjectKey('t2', 'b1')]);
  });

  it('logs R2 purge errors without failing the push response', async () => {
    const h = createServerHarness();
    await seedBasic(h);
    vi.spyOn(h.storage, 'list').mockRejectedValueOnce(new Error('r2 down'));
    const errSpy = vi.spyOn(console, 'error').mockImplementation(() => {});

    try {
      const res = await h.devicePush('u-a', [
        {
          opId: 'purge-t1-fail-r2',
          hlc: h.deviceHlc(),
          entity: 'task',
          entityId: 't1',
          op: 'delete',
          fields: [],
          row: {},
        },
      ]);
      expect(res.results[0]?.status).toBe('applied');
      expect(errSpy).toHaveBeenCalledTimes(1);
      expect(errSpy.mock.calls[0]?.[0]).toContain('attachment.purge.failed');
    } finally {
      errSpy.mockRestore();
    }
  });
});

describe('MCP upload_attachment', () => {
  it('puts bytes to R2, writes attachment row with safeName and defaults, and is downloadable', async () => {
    let now = 1_700_123_456_000;
    const h = createServerHarness({ getNow: () => now });
    await seedBasic(h);

    const payload = new TextEncoder().encode('MCP uploaded file');
    const b64 = Buffer.from(payload).toString('base64');

    const res = await call(h, 'u-a', 'upload_attachment', {
      project_id: 'p1',
      task_id: 't1',
      content_base64: b64,
      filename: 'dir/sub/report.txt',
    });
    expect(res.isError, res.text).toBe(false);
    expect(res.json).toMatchObject({
      file_name: 'dir_sub_report.txt',
      size: payload.byteLength,
      mime_type: 'application/octet-stream',
      created_at: now,
    });
    expect(typeof res.json.id).toBe('string');

    const id = res.json.id as string;
    expect(h.storage.rawBytes(attachmentObjectKey('t1', id))).toEqual(payload);

    const pulledAtt = pulled(await h.pull('u-a'), 'attachment', id);
    expect(pulledAtt).toMatchObject({
      id,
      taskId: 't1',
      fileName: 'dir_sub_report.txt',
      size: payload.byteLength,
      mimeType: 'application/octet-stream',
      createdAt: now,
      updatedAt: now,
    });

    const getRes = await downloadAttachmentContent(h.db, {
      attachmentId: id,
      userId: 'u-a',
      getScopeStub: h.getScopeStub,
      storage: h.storage,
    });
    expect(getRes.status).toBe(200);
    expect(getRes.headers.get('Content-Type')).toBe('application/octet-stream');
    expect(new Uint8Array(await getRes.arrayBuffer())).toEqual(payload);
  });

  it('rejects wrong project, read-only list, no-data account, invalid base64, and > 20 MB', async () => {
    const h = createServerHarness();
    await seedBasic(h);
    await h.devicePush('u-a', [deviceOp(h, 'project', projectRow('p2'))]);
    await shareWith(h, 'p1', 'u-viewer', 'm-viewer', 'viewer');
    await seedUser(h, 'u-empty', null, false);

    const validB64 = Buffer.from('ok').toString('base64');

    // Wrong project
    const wrongProj = await call(h, 'u-a', 'upload_attachment', {
      project_id: 'p2',
      task_id: 't1',
      content_base64: validB64,
      filename: 'a.txt',
    });
    expect(wrongProj.isError).toBe(true);
    expect(wrongProj.text).toContain('not in project');

    // Read-only viewer
    const viewerWrite = await call(h, 'u-viewer', 'upload_attachment', {
      project_id: 'p1',
      task_id: 't1',
      content_base64: validB64,
      filename: 'a.txt',
    });
    expect(viewerWrite.isError).toBe(true);
    expect(viewerWrite.text).toContain('read-only');

    // No-data account
    const noData = await call(h, 'u-empty', 'upload_attachment', {
      project_id: 'p1',
      task_id: 't1',
      content_base64: validB64,
      filename: 'a.txt',
    });
    expect(noData.isError).toBe(true);
    expect(noData.text).toContain(NO_DATA_MESSAGE);

    // Invalid base64
    const badB64 = await call(h, 'u-a', 'upload_attachment', {
      project_id: 'p1',
      task_id: 't1',
      content_base64: '!!!not-base64!!!',
      filename: 'a.txt',
    });
    expect(badB64.isError).toBe(true);
    expect(badB64.text).toContain('valid base64');

    // > 20 MB base64
    const oversizedB64 = 'A'.repeat(Math.ceil(((MAX_ATTACHMENT_BYTES + 3) / 3) * 4));
    const tooBig = await call(h, 'u-a', 'upload_attachment', {
      project_id: 'p1',
      task_id: 't1',
      content_base64: oversizedB64,
      filename: 'big.bin',
    });
    expect(tooBig.isError).toBe(true);
    expect(tooBig.text).toContain('20 MB');

    expect(h.storage.keys()).toEqual([]);
  });

  it('cleans up R2 object when push explicitly rejects the write', async () => {
    const h = createServerHarness({
      onPush: async (input, proceed) => {
        const res = await proceed(input);
        if (input.ops.some((o) => (o as Record<string, unknown>).entity === 'attachment')) {
          return {
            ...res,
            results: input.ops.map((o) => ({
              opId: String((o as Record<string, unknown>).opId),
              status: 'rejected' as const,
              reason: 'Forbidden',
              row: null,
              clocks: {},
            })),
          };
        }
        return res;
      },
    });
    await seedBasic(h);

    const res = await call(h, 'u-a', 'upload_attachment', {
      project_id: 'p1',
      task_id: 't1',
      content_base64: Buffer.from('cleanup-me').toString('base64'),
      filename: 'a.txt',
      content_type: 'text/plain',
    });
    expect(res.isError).toBe(true);
    expect(res.text).toContain('rejected');
    expect(h.storage.keys()).toEqual([]);
  });

  it('keeps R2 object when Scope commits the row but the RPC response is lost', async () => {
    const h = createServerHarness({
      onPush: async (input, proceed) => {
        const res = await proceed(input);
        if (input.ops.some((o) => (o as Record<string, unknown>).entity === 'attachment')) {
          throw new Error('RPC response lost');
        }
        return res;
      },
    });
    await seedBasic(h);

    const payload = Buffer.from('keep-on-lost-rpc');
    const res = await call(h, 'u-a', 'upload_attachment', {
      project_id: 'p1',
      task_id: 't1',
      content_base64: payload.toString('base64'),
      filename: 'lost.txt',
      content_type: 'text/plain',
    });
    expect(res.isError).toBe(true);
    expect(res.text).toContain('RPC response lost');
    expect(h.storage.keys()).toHaveLength(1);

    const key = h.storage.keys()[0]!;
    const attId = key.split('/').pop()!;
    expect(pulled(await h.pull('u-a'), 'attachment', attId)).toMatchObject({
      id: attId,
      taskId: 't1',
      fileName: 'lost.txt',
      size: payload.byteLength,
    });
    const getRes = await downloadAttachmentContent(h.db, {
      attachmentId: attId,
      userId: 'u-a',
      getScopeStub: h.getScopeStub,
      storage: h.storage,
    });
    expect(getRes.status).toBe(200);
    expect(Buffer.from(await getRes.arrayBuffer())).toEqual(payload);
  });
});
