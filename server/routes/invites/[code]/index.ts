import { defineHandler } from 'void';
import { requireUser } from '../../../src/auth/middleware';
import { productionAppDeps } from '../../../src/deps';
import { withScopeRelocating503 } from '../../../src/http';
import { getInviteInfo, revokeInvite, SharingError } from '../../../src/sharing';

export const GET = defineHandler(async (c) => {
  const userId = await requireUser(c);
  if (userId instanceof Response) return userId;

  const code = c.req.param('code') ?? '';
  return withScopeRelocating503(c, async () => {
    const deps = productionAppDeps(c.env);
    try {
      const result = await getInviteInfo(deps.db, {
        code,
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
});

export const DELETE = defineHandler(async (c) => {
  const userId = await requireUser(c);
  if (userId instanceof Response) return userId;

  const code = c.req.param('code') ?? '';
  const deps = productionAppDeps(c.env);
  try {
    const result = await revokeInvite(deps.db, {
      code,
      userId,
    });
    return c.json(result, 200);
  } catch (err) {
    if (err instanceof SharingError) {
      return c.json({ error: err.message }, err.status as 400 | 403 | 404);
    }
    throw err;
  }
});
