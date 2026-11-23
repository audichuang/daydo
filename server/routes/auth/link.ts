import { defineHandler } from 'void';
import { env } from 'void/env';
import { handleAuthLink } from '../../src/auth/identities';
import { requireUser } from '../../src/auth/middleware';
import { productionAppDeps } from '../../src/deps';
import { readJsonObject } from '../../src/http';

export const POST = defineHandler(async (c) => {
  const userId = await requireUser(c);
  if (userId instanceof Response) return userId;

  const deps = productionAppDeps(c.env);
  const result = await handleAuthLink(deps.db, {
    userId,
    body: await readJsonObject(c),
    appleAudience: env.APPLE_AUDIENCE,
    appleJwksUrl: env.APPLE_JWKS_URL,
    googleAudience: env.GOOGLE_AUDIENCE,
    googleJwksUrl: env.GOOGLE_JWKS_URL,
  });
  return c.json(result.body, result.status);
});
