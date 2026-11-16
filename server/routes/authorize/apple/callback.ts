import { defineHandler } from 'void';
import { env } from 'void/env';
import { productionAppDeps } from '../../../src/deps';
import { handleAppleCallback } from '../../../src/oauth/authorize';
import { webIdentityConfigFromEnv } from '../../../src/oauth/webIdentity';

// Apple form_post: a cross-site top-level POST, so the bind cookie is SameSite=None.
export const POST = defineHandler(async (c) =>
  handleAppleCallback(c.req.raw, await c.req.parseBody(), {
    database: productionAppDeps(c.env).db,
    web: webIdentityConfigFromEnv(env),
  }),
);
