import { defineHandler } from 'void';
import { createDb } from 'void/db';
import { Scope } from '../../../durable-objects/scope';
import { requireUser } from '../../../src/auth/middleware';
import { acceptInvite, SharingError } from '../../../src/sharing';

export const POST = defineHandler(async (c) => {
  const userId = await requireUser(c);
  if (userId instanceof Response) return userId;

  const code = c.req.param('code') ?? '';
  const db = createDb(c.env.DB, { session: 'first-primary' });
  try {
    const result = await acceptInvite(db, {
      code,
      userId,
      getScopeStub: (scope) => Scope.get(scope),
    });
    return c.json(result, 200);
  } catch (err) {
    if (err instanceof SharingError) {
      return c.json({ error: err.message }, err.status as 400 | 403 | 404);
    }
    throw err;
  }
});
