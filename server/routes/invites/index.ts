import { defineHandler } from 'void';
import { requireUser } from '../../src/auth/middleware';
import { productionAppDeps } from '../../src/deps';
import { nonEmptyString, readJsonObject, withSharingErrors } from '../../src/http';
import { createInvite } from '../../src/sharing';

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
  return withSharingErrors(c, async () => {
    const result = await createInvite(deps.db, {
      userId,
      projectId,
      role: body.role,
      email: body.email,
    });
    return c.json(result, 200);
  });
});
