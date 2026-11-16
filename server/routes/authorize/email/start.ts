import { defineHandler } from 'void';
import { createDb } from 'void/db';
import { env } from 'void/env';
import { selectMailer } from '../../../src/mail/mailer';
import { handleAuthorizeEmailStart } from '../../../src/oauth/authorize';
import { webIdentityConfigFromEnv } from '../../../src/oauth/webIdentity';

// Same-origin form POST from the login page; the bind cookie (Path=/authorize) comes along.
export const POST = defineHandler(async (c) =>
  handleAuthorizeEmailStart(
    c.req.raw,
    await c.req.parseBody(),
    { database: createDb(c.env.DB, { session: 'first-primary' }), web: webIdentityConfigFromEnv(env) },
    selectMailer({ binding: c.env.EMAIL }),
  ),
);
