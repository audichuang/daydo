import { defineHandler } from 'void';
import { downloadAttachmentContent, uploadAttachmentContent } from '../../../src/attachments/content';
import { requireUser } from '../../../src/auth/middleware';
import { productionAppDeps } from '../../../src/deps';

export const PUT = defineHandler(async (c) => {
  const userId = await requireUser(c);
  if (userId instanceof Response) return userId;

  const attachmentId = c.req.param('id') ?? '';
  const deps = productionAppDeps(c.env);
  return uploadAttachmentContent(deps.db, {
    attachmentId,
    userId,
    contentTypeHeader: c.req.header('Content-Type'),
    contentLengthHeader: c.req.header('Content-Length'),
    body: c.req.raw.body,
    getScopeStub: deps.getScopeStub,
    storage: deps.storage,
  });
});

export const GET = defineHandler(async (c) => {
  const userId = await requireUser(c);
  if (userId instanceof Response) return userId;

  const attachmentId = c.req.param('id') ?? '';
  const deps = productionAppDeps(c.env);
  return downloadAttachmentContent(deps.db, {
    attachmentId,
    userId,
    getScopeStub: deps.getScopeStub,
    storage: deps.storage,
  });
});
