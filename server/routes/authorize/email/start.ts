import { defineHandler } from 'void';
import { env } from 'void/env';
import { productionAppDeps } from '../../../src/deps';
import { handleAuthorizeEmailStart } from '../../../src/oauth/authorize';
import { webIdentityConfigFromEnv } from '../../../src/oauth/webIdentity';

// Same-origin form POST from the login page; the bind cookie (Path=/authorize) comes along.
export const POST = defineHandler(async (c) => {
  const body = await c.req.parseBody();
  const deps = productionAppDeps(c.env);
  return handleAuthorizeEmailStart(c.req.raw, body, { database: deps.db, web: webIdentityConfigFromEnv(env) }, deps.mailer);
});
