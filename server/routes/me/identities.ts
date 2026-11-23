import { defineHandler } from 'void';
import { listUserIdentitiesWithCheck } from '../../src/auth/identities';
import { requireUser } from '../../src/auth/middleware';
import { productionAppDeps } from '../../src/deps';

export const GET = defineHandler(async (c) => {
  const userId = await requireUser(c);
  if (userId instanceof Response) return userId;

  const deps = productionAppDeps(c.env);
  const identities = await listUserIdentitiesWithCheck(deps.db, userId);
  if (!identities) {
    return c.json({ error: 'User not found' }, 404);
  }
  return c.json(identities, 200);
});
