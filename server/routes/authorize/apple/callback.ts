import { defineHandler } from 'void';
import { createDb } from 'void/db';
import { env } from 'void/env';
import { handleAppleCallback } from '../../../src/oauth/authorize';
import { webIdentityConfigFromEnv } from '../../../src/oauth/webIdentity';

// Apple form_post: a cross-site top-level POST, so the bind cookie is SameSite=None.
export const POST = defineHandler(async (c) =>
  handleAppleCallback(c.req.raw, await c.req.parseBody(), {
    database: createDb(c.env.DB, { session: 'first-primary' }),
    web: webIdentityConfigFromEnv(env),
  }),
);
