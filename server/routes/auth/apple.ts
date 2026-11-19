import { defineHandler } from 'void';
import { env } from 'void/env';
import { AuthVerificationError, verifyAppleToken } from '../../src/auth/providers';
import { createSessionForIdentity } from '../../src/auth/session';
import { productionAppDeps } from '../../src/deps';
import { nonEmptyString, readJsonObject, withScopeRelocating503 } from '../../src/http';

export const POST = defineHandler(async (c) => {
  const body = await readJsonObject(c);
  if (!body) {
    return c.json({ error: 'Invalid JSON body' }, 400);
  }
  const identityToken = nonEmptyString(body.identityToken);
  const nonce = nonEmptyString(body.nonce);
  const deviceId = nonEmptyString(body.deviceId);
  if (!identityToken || !nonce || !deviceId) {
    return c.json({ error: 'identityToken, nonce, and deviceId are required' }, 400);
  }

  let verified;
  try {
    verified = await verifyAppleToken({
      identityToken,
      nonce,
      audience: env.APPLE_AUDIENCE,
      jwksUrl: env.APPLE_JWKS_URL,
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
