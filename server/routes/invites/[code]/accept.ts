import { defineHandler } from 'void';
import { requireUser } from '../../../src/auth/middleware';
import { productionAppDeps } from '../../../src/deps';
import { withSharingErrors } from '../../../src/http';
import { acceptInvite } from '../../../src/sharing';

export const POST = defineHandler(async (c) => {
  const userId = await requireUser(c);
  if (userId instanceof Response) return userId;

  const code = c.req.param('code') ?? '';
  const deps = productionAppDeps(c.env);
  return withSharingErrors(c, async () => {
    const result = await acceptInvite(deps.db, {
      code,
      userId,
      getScopeStub: deps.getScopeStub,
    });
    return c.json(result, 200);
  });
});
