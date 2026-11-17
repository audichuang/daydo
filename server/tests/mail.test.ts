import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { renderCodeEmail } from '../src/mail/code-email';
import { clearDevMail, lastDevMail, MAIL_FROM, selectMailer } from '../src/mail/mailer';

const CODE = '482913';

function captureLogs() {
  const lines: string[] = [];
  for (const level of ['log', 'info', 'warn', 'error', 'debug'] as const) {
    vi.spyOn(console, level).mockImplementation((...args: unknown[]) => {
      lines.push(args.map((a) => (typeof a === 'string' ? a : JSON.stringify(a))).join(' '));
    });
  }
  return lines;
}

function fakeBinding(impl?: (msg: unknown) => Promise<unknown>) {
  const sent: unknown[] = [];
  const binding = {
    send: vi.fn(async (msg: unknown) => {
      sent.push(msg);
      return impl ? impl(msg) : { messageId: 'm-1' };
    }),
  };
  return { binding: binding as unknown as SendEmail, sent, send: binding.send };
}

beforeEach(() => clearDevMail());
afterEach(() => vi.restoreAllMocks());

describe('renderCodeEmail', () => {
  it('uses the fixed subject and puts the code and the 10-minute note in text and html', () => {
    const mail = renderCodeEmail(CODE);
    expect(mail.subject).toBe('你的 DayDo 驗證碼');
    for (const body of [mail.text, mail.html]) {
      expect(body).toContain(CODE);
      expect(body).toContain('10 分鐘內有效');
    }
    expect(mail.html).toMatch(/^<!doctype html>/i);
  });
});

describe('selectMailer', () => {
  it('dev build uses the in-memory mailer even when a binding exists, readable per recipient', async () => {
    const { binding, send } = fakeBinding();
    const logs = captureLogs();
    const mailer = selectMailer({ binding, isDev: true });
    const res = await mailer.send({ to: ' Someone@Example.com ', ...renderCodeEmail(CODE) });
    await mailer.send({ to: 'other@example.com', ...renderCodeEmail('111111') });

    expect(res).toEqual({ ok: true });
    expect(send).not.toHaveBeenCalled();
    const last = lastDevMail('someone@example.com');
    expect(last?.text).toContain(CODE);
    expect(last?.to).toBe('someone@example.com');
    expect(lastDevMail('other@example.com')?.text).toContain('111111');
    expect(lastDevMail('nobody@example.com')).toBeNull();
    expect(logs.join('\n')).not.toContain(CODE);
  });

  it('dev mailbox keeps only the latest message per recipient', async () => {
    const mailer = selectMailer({ binding: undefined, isDev: true });
    await mailer.send({ to: 'a@example.com', ...renderCodeEmail('111111') });
    await mailer.send({ to: 'a@example.com', ...renderCodeEmail('222222') });
    expect(lastDevMail('A@example.com')?.text).toContain('222222');
  });

  it('production with the EMAIL binding sends a structured message from DayDo without logging the code', async () => {
    const { binding, sent } = fakeBinding();
    const logs = captureLogs();
    const mailer = selectMailer({ binding, isDev: false });
    const mail = renderCodeEmail(CODE);
    const res = await mailer.send({ to: 'user@example.com', ...mail });

    expect(res).toEqual({ ok: true });
    expect(sent).toEqual([
      {
        from: { name: 'DayDo', email: 'no-reply@daydoapp.com' },
        to: 'user@example.com',
        subject: mail.subject,
        text: mail.text,
        html: mail.html,
      },
    ]);
    expect(MAIL_FROM).toEqual({ name: 'DayDo', email: 'no-reply@daydoapp.com' });
    expect(lastDevMail('user@example.com')).toBeNull();
    const joined = logs.join('\n');
    expect(joined).toContain('"event":"mail.send"');
    expect(joined).not.toContain(CODE);
  });

  it('production send failure resolves to ok:false with the error code logged, never throws or logs the code', async () => {
    const err = Object.assign(new Error(`rejected ${CODE}`), { code: 'E_SENDER_NOT_VERIFIED' });
    const { binding } = fakeBinding(async () => {
      throw err;
    });
    const logs = captureLogs();
    const res = await selectMailer({ binding, isDev: false }).send({ to: 'user@example.com', ...renderCodeEmail(CODE) });

    expect(res).toEqual({ ok: false, reason: 'send_failed' });
    const joined = logs.join('\n');
    expect(joined).toContain('E_SENDER_NOT_VERIFIED');
    expect(joined).not.toContain(CODE);
  });

  it('production without the binding does not send and logs mail.skipped', async () => {
    const logs = captureLogs();
    const res = await selectMailer({ binding: undefined, isDev: false }).send({
      to: 'user@example.com',
      ...renderCodeEmail(CODE),
    });

    expect(res).toEqual({ ok: false, reason: 'binding_missing' });
    expect(lastDevMail('user@example.com')).toBeNull();
    const joined = logs.join('\n');
    expect(joined).toContain('"event":"mail.skipped"');
    expect(joined).not.toContain(CODE);
  });
});
