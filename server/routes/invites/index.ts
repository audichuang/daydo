import { defineHandler } from 'void';
import { requireUser } from '../../src/auth/middleware';
import { productionAppDeps } from '../../src/deps';
import { nonEmptyString, readJsonObject } from '../../src/http';
import { createInvite, SharingError } from '../../src/sharing';

export const POST = defineHandler(async (c) => {
  const userId = await requireUser(c);
  if (userId instanceof Response) return userId;

  const body = await readJsonObject(c);
  if (!body) {
    return c.json({ error: 'Invalid JSON body' }, 400);
  }

  const projectId = nonEmptyString(body.projectId);
  if (!projectId) {
    return c.json({ error: 'projectId is required' }, 400);
  }

  const deps = productionAppDeps(c.env);
  try {
    const result = await createInvite(deps.db, {
      userId,
      projectId,
      role: body.role,
      email: body.email,
    });
    return c.json(result, 200);
  } catch (err) {
    if (err instanceof SharingError) {
      return c.json({ error: err.message }, err.status as 400 | 403 | 404);
    }
    throw err;
  }
});
