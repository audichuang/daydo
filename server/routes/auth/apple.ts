import { defineHandler } from 'void';
import { env } from 'void/env';
import { createSessionForIdentity } from '../../src/auth/session';
import { verifyCredential } from '../../src/auth/verifyCredential';
import { productionAppDeps } from '../../src/deps';
import { nonEmptyString, readJsonObject, withScopeRelocating503 } from '../../src/http';

export const POST = defineHandler(async (c) => {
  const body = await readJsonObject(c);
  if (!body) {
    return c.json({ error: 'Invalid JSON body' }, 400);
  }
  const deviceId = nonEmptyString(body.deviceId);
  if (!deviceId) {
    return c.json({ error: 'identityToken, nonce, and deviceId are required' }, 400);
  }

  const verified = await verifyCredential({
    provider: 'apple',
    identityToken: body.identityToken,
    nonce: body.nonce,
    audience: env.APPLE_AUDIENCE,
    jwksUrl: env.APPLE_JWKS_URL,
  });
  if (!verified.ok) {
    const error =
      verified.status === 400 ? 'identityToken, nonce, and deviceId are required' : verified.error;
    return c.json({ error }, verified.status);
  }

  return withScopeRelocating503(c, async () => {
    const deps = productionAppDeps(c.env);
    const result = await createSessionForIdentity(deps.db, {
      ...verified.identity,
      deviceId,
      jwtSecret: env.JWT_SECRET,
      getScopeStub: deps.getScopeStub,
    });
    return c.json(result, 200);
  });
});
