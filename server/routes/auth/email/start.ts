import { defineHandler } from 'void';
import { createDb } from 'void/db';
import { handleEmailStart } from '../../../src/auth/email';
import { readJsonObject } from '../../../src/http';
import { selectMailer } from '../../../src/mail/mailer';

export const POST = defineHandler(async (c) => {
  const result = await handleEmailStart(createDb(c.env.DB, { session: 'first-primary' }), {
    body: await readJsonObject(c),
    ip: c.req.header('CF-Connecting-IP') ?? null,
    mailer: selectMailer({ binding: c.env.EMAIL }),
  });
  return c.json(result.body, result.status);
});
