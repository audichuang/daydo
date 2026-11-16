// Outgoing mail (spec/mcp.md section 10, `EMAIL` binding). Production sends through the
// Cloudflare Email Service `send_email` binding; development builds keep the last message per
// recipient in memory so e2e can read it via routes/test/mail.dev.ts. Logs never carry the
// subject or body, because the body contains the sign-in code.
import { logEvent } from '../log';

export interface MailMessage {
  to: string;
  subject: string;
  text: string;
  html: string;
}

/** `send` never throws: callers (e.g. `/auth/email/start`) answer 202 whatever the outcome. */
export type MailResult = { ok: true } | { ok: false; reason: 'send_failed' | 'binding_missing' };

export interface Mailer {
  send(message: MailMessage): Promise<MailResult>;
}

export const MAIL_FROM = { name: 'DayDo', email: 'no-reply@audichuang.app' } as const;

export interface DevMail extends MailMessage {
  sentAt: number;
}

function normalizeAddress(address: string): string {
  return address.trim().toLowerCase();
}

// Module-level store: the Void dev server runs the worker in a single isolate, so the map is
// shared across requests (proved by scripts/e2e.mjs). It is only written in development builds.
const devMailbox = new Map<string, DevMail>();

const devMailer: Mailer = {
  async send(message) {
    const to = normalizeAddress(message.to);
    devMailbox.set(to, { ...message, to, sentAt: Date.now() });
    logEvent('log', 'mail.dev', { stored: true });
    return { ok: true };
  },
};

export function lastDevMail(address: string): DevMail | null {
  return devMailbox.get(normalizeAddress(address)) ?? null;
}

export function clearDevMail(): void {
  devMailbox.clear();
}

class CloudflareMailer implements Mailer {
  constructor(private readonly binding: SendEmail) {}

  async send(message: MailMessage): Promise<MailResult> {
    try {
      await this.binding.send({
        from: { ...MAIL_FROM },
        to: message.to,
        subject: message.subject,
        text: message.text,
        html: message.html,
      });
      logEvent('log', 'mail.send', { outcome: 'ok' });
      return { ok: true };
    } catch (e) {
      const code = e && typeof e === 'object' && 'code' in e && typeof e.code === 'string' ? e.code : null;
      logEvent('warn', 'mail.send', { outcome: 'error', code });
      return { ok: false, reason: 'send_failed' };
    }
  }
}

const missingBindingMailer: Mailer = {
  async send() {
    logEvent('warn', 'mail.skipped', { reason: 'binding_missing' });
    return { ok: false, reason: 'binding_missing' };
  },
};

/**
 * Development builds always use the in-memory mailer, whatever bindings the dev server exposes.
 * Production uses the `EMAIL` binding; without it nothing is sent and `mail.skipped` is logged.
 */
export function selectMailer(params: { binding: SendEmail | undefined; isDev?: boolean }): Mailer {
  const isDev = import.meta.env.DEV && (params.isDev ?? true);
  if (isDev) return devMailer;
  if (params.binding && typeof params.binding.send === 'function') return new CloudflareMailer(params.binding);
  return missingBindingMailer;
}
