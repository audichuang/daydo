import { defineHandler } from 'void';
import { renderCodeEmail } from '../../src/mail/code-email';
import { lastDevMail, selectMailer } from '../../src/mail/mailer';

// Development builds only: read the last message sent to an address (e2e reads sign-in codes here).
export const GET = defineHandler(async (c) => {
  const to = c.req.query('to');
  if (!to) return c.json({ error: 'to is required' }, 400);
  const mail = lastDevMail(to);
  if (!mail) return c.json({ error: 'no mail' }, 404);
  const code = /\b(\d{6})\b/.exec(mail.text)?.[1] ?? null;
  return c.json({ ...mail, code }, 200);
});

// Development builds only: send a sign-in code email through the selected mailer, so e2e can
// prove a message stored in one request is readable from the next.
export const POST = defineHandler(async (c) => {
  const body = await c.req.json().catch(() => null);
  const to = body && typeof body.to === 'string' ? body.to : null;
  const code = body && typeof body.code === 'string' ? body.code : null;
  if (!to || !code) return c.json({ error: 'to and code are required' }, 400);
  const result = await selectMailer({ binding: c.env.EMAIL }).send({ to, ...renderCodeEmail(code) });
  return c.json(result, result.ok ? 200 : 502);
});
