import { defineHandler } from 'void';
import { requireUser } from '../../../src/auth/middleware';
import { productionAppDeps } from '../../../src/deps';
import { acceptInvite, SharingError } from '../../../src/sharing';

export const POST = defineHandler(async (c) => {
  const userId = await requireUser(c);
  if (userId instanceof Response) return userId;

  const code = c.req.param('code') ?? '';
  const deps = productionAppDeps(c.env);
  try {
    const result = await acceptInvite(deps.db, {
      code,
      userId,
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
