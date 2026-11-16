import { defineHandler } from 'void';
import { createDb } from 'void/db';
import { env } from 'void/env';
import { handleAuthorizeStart } from '../../src/oauth/authorize';
import { webIdentityConfigFromEnv } from '../../src/oauth/webIdentity';

export const GET = defineHandler(async (c) =>
  handleAuthorizeStart(c.req.raw, {
    database: createDb(c.env.DB, { session: 'first-primary' }),
    web: webIdentityConfigFromEnv(env),
  }),
);
