import { defineHandler } from 'void';
import { createDb } from 'void/db';
import { env } from 'void/env';
import { handleAuthorizeEmailVerify } from '../../../src/oauth/authorize';
import { webIdentityConfigFromEnv } from '../../../src/oauth/webIdentity';

export const POST = defineHandler(async (c) =>
  handleAuthorizeEmailVerify(c.req.raw, await c.req.parseBody(), {
    database: createDb(c.env.DB, { session: 'first-primary' }),
    web: webIdentityConfigFromEnv(env),
  }),
);
