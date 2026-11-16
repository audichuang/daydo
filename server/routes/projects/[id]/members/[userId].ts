import { defineHandler } from 'void';
import { requireUser } from '../../../../src/auth/middleware';
import { productionAppDeps } from '../../../../src/deps';
import { readJsonObject } from '../../../../src/http';
import {
  removeProjectMember,
  SharingError,
  updateProjectMemberRole,
} from '../../../../src/sharing';

export const PUT = defineHandler(async (c) => {
  const userId = await requireUser(c);
  if (userId instanceof Response) return userId;

  const projectId = c.req.param('id') ?? '';
  const targetUserId = c.req.param('userId') ?? '';
  const body = await readJsonObject(c);
  if (!body) {
    return c.json({ error: 'Invalid JSON body' }, 400);
  }

  const deps = productionAppDeps(c.env);
  try {
    const result = await updateProjectMemberRole(deps.db, {
      projectId,
      targetUserId,
      requesterUserId: userId,
      role: body.role,
      getScopeStub: deps.getScopeStub,
    });
    return c.json(result, 200);
  } catch (err) {
    if (err instanceof SharingError) {
      return c.json({ error: err.message }, err.status as 400 | 403 | 404);
    }
    throw err;
  }
});

export const DELETE = defineHandler(async (c) => {
  const userId = await requireUser(c);
  if (userId instanceof Response) return userId;

  const projectId = c.req.param('id') ?? '';
  const targetUserId = c.req.param('userId') ?? '';

  const deps = productionAppDeps(c.env);
  try {
    const result = await removeProjectMember(deps.db, {
      projectId,
      targetUserId,
      requesterUserId: userId,
      getScopeStub: deps.getScopeStub,
    });
    return c.json(result, 200);
  } catch (err) {
    if (err instanceof SharingError) {
      return c.json({ error: err.message }, err.status as 400 | 403 | 404);
    }
    throw err;
  }
});
