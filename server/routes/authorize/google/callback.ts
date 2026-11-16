import { defineHandler } from 'void';
import { createDb } from 'void/db';
import { env } from 'void/env';
import { handleGoogleCallback } from '../../../src/oauth/googleCallback';
import { webIdentityConfigFromEnv } from '../../../src/oauth/webIdentity';

// Google redirects back with a top-level GET (code, state, or error).
export const GET = defineHandler(async (c) =>
  handleGoogleCallback(c.req.raw, {
    database: createDb(c.env.DB, { session: 'first-primary' }),
    web: webIdentityConfigFromEnv(env),
  }),
);
