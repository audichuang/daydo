import { defineHandler } from 'void';
import { createDb } from 'void/db';
import { env } from 'void/env';
import { Scope } from '../../durable-objects/scope';
import { rotateRefreshToken } from '../../src/auth/session';
import { nonEmptyString, readJsonObject } from '../../src/http';

export const POST = defineHandler(async (c) => {
  const body = await readJsonObject(c);
  if (!body) {
    return c.json({ error: 'Invalid JSON body' }, 400);
  }
  const refreshToken = nonEmptyString(body.refreshToken);
  if (!refreshToken) {
    return c.json({ error: 'refreshToken is required' }, 400);
  }

  const primaryDb = createDb(c.env.DB, { session: 'first-primary' });
  const result = await rotateRefreshToken(primaryDb, {
    refreshToken,
    jwtSecret: env.JWT_SECRET,
    getScopeStub: (scope) => Scope.get(scope),
  });
  if (!result) {
    return c.json({ error: 'Invalid or expired refresh token' }, 401);
  }
  return c.json(result, 200);
});
