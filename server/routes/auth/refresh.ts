import { defineHandler } from 'void';
import { env } from 'void/env';
import { rotateRefreshToken } from '../../src/auth/session';
import { productionAppDeps } from '../../src/deps';
import { nonEmptyString, readJsonObject, withScopeRelocating503 } from '../../src/http';

export const POST = defineHandler(async (c) => {
  const body = await readJsonObject(c);
  if (!body) {
    return c.json({ error: 'Invalid JSON body' }, 400);
  }
  const refreshToken = nonEmptyString(body.refreshToken);
  if (!refreshToken) {
    return c.json({ error: 'refreshToken is required' }, 400);
  }

  return withScopeRelocating503(c, async () => {
    const deps = productionAppDeps(c.env);
    const result = await rotateRefreshToken(deps.db, {
      refreshToken,
      jwtSecret: env.JWT_SECRET,
      getScopeStub: deps.getScopeStub,
    });
    if (!result) {
      return c.json({ error: 'Invalid or expired refresh token' }, 401);
    }
    return c.json(result, 200);
  });
});
