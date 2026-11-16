import { defineHandler } from 'void';
import { env } from 'void/env';
import { productionAppDeps } from '../../../src/deps';
import { handleAuthorizeEmailVerify } from '../../../src/oauth/authorize';
import { webIdentityConfigFromEnv } from '../../../src/oauth/webIdentity';

export const POST = defineHandler(async (c) =>
  handleAuthorizeEmailVerify(c.req.raw, await c.req.parseBody(), {
    database: productionAppDeps(c.env).db,
    web: webIdentityConfigFromEnv(env),
  }),
);
