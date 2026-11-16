import { defineHandler } from 'void';
import { env } from 'void/env';
import { productionAppDeps } from '../../src/deps';
import { handleAuthorizeStart } from '../../src/oauth/authorize';
import { webIdentityConfigFromEnv } from '../../src/oauth/webIdentity';

export const GET = defineHandler(async (c) =>
  handleAuthorizeStart(c.req.raw, {
    database: productionAppDeps(c.env).db,
    web: webIdentityConfigFromEnv(env),
  }),
);
