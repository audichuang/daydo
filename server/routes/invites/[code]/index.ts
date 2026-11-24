import { defineHandler } from 'void';
import { requireUser } from '../../../src/auth/middleware';
import { productionAppDeps } from '../../../src/deps';
import { withScopeRelocating503, withSharingErrors } from '../../../src/http';
import { getInviteInfo, revokeInvite } from '../../../src/sharing';

export const GET = defineHandler(async (c) => {
  const userId = await requireUser(c);
  if (userId instanceof Response) return userId;

  const code = c.req.param('code') ?? '';
  return withScopeRelocating503(c, async () => {
    const deps = productionAppDeps(c.env);
    return withSharingErrors(c, async () => {
      const result = await getInviteInfo(deps.db, {
        code,
        getScopeStub: deps.getScopeStub,
      });
      return c.json(result, 200);
    });
  });
});

export const DELETE = defineHandler(async (c) => {
  const userId = await requireUser(c);
  if (userId instanceof Response) return userId;

  const code = c.req.param('code') ?? '';
  const deps = productionAppDeps(c.env);
  return withSharingErrors(c, async () => {
    const result = await revokeInvite(deps.db, {
      code,
      userId,
    });
    return c.json(result, 200);
  });
});
