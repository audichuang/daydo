import { defineHandler } from 'void';
import { env } from 'void/env';
import { AuthVerificationError, verifyGoogleToken } from '../../src/auth/providers';
import { createSessionForIdentity } from '../../src/auth/session';
import { productionAppDeps } from '../../src/deps';
import { nonEmptyString, readJsonObject, withScopeRelocating503 } from '../../src/http';

export const POST = defineHandler(async (c) => {
  const body = await readJsonObject(c);
  if (!body) {
    return c.json({ error: 'Invalid JSON body' }, 400);
  }
  const idToken = nonEmptyString(body.idToken);
  const deviceId = nonEmptyString(body.deviceId);
  if (!idToken || !deviceId) {
    return c.json({ error: 'idToken and deviceId are required' }, 400);
  }

  const audience = env.GOOGLE_AUDIENCE;
  if (!audience) {
    return c.json({ error: 'Google auth is not configured' }, 500);
  }

  let verified;
  try {
    verified = await verifyGoogleToken({
      idToken,
      audience,
      jwksUrl: env.GOOGLE_JWKS_URL,
    });
  } catch (error) {
    if (error instanceof AuthVerificationError) {
      return c.json({ error: error.message }, 401);
    }
    throw error;
  }

  return withScopeRelocating503(c, async () => {
    const deps = productionAppDeps(c.env);
    const result = await createSessionForIdentity(deps.db, {
      ...verified,
      deviceId,
      jwtSecret: env.JWT_SECRET,
      getScopeStub: deps.getScopeStub,
    });
    return c.json(result, 200);
  });
});
