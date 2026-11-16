import { defineHandler } from 'void';
import { env } from 'void/env';
import { productionAppDeps } from '../../../src/deps';
import { handleGoogleCallback } from '../../../src/oauth/googleCallback';
import { webIdentityConfigFromEnv } from '../../../src/oauth/webIdentity';

// Google redirects back with a top-level GET (code, state, or error).
export const GET = defineHandler(async (c) =>
  handleGoogleCallback(c.req.raw, {
    database: productionAppDeps(c.env).db,
    web: webIdentityConfigFromEnv(env),
  }),
);
