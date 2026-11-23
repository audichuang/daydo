// Email sign-in codes (spec/sync.md "信箱驗證碼"; MCP authorize reuses the same store, spec/mcp.md 3b).
// Passwordless: start mails a 6-digit code, verify consumes it. D1 keeps only SHA-256(code + salt).
// Logs carry outcomes only: never the code, and not the address.
import { emailCode } from '@schema';
import { and, count, desc, eq, gt, isNull, lt, sql } from 'void/db';
import { randomB64url } from '../base64url';
import { systemNow } from '../clock';
import { ipRateKey } from '../ipRateKey';
import { logEvent } from '../log';
import { renderCodeEmail } from '../mail/code-email';
import type { Mailer } from '../mail/mailer';
import { sha256Hex } from './crypto';
import type { DatabaseClient } from './session';

export const EMAIL_CODE_TTL_MS = 10 * 60 * 1000;
export const EMAIL_CODE_MAX_ATTEMPTS = 5;
export const EMAIL_START_LIMIT_PER_EMAIL = 5;
export const EMAIL_START_LIMIT_PER_IP = 20;
/** Wrong guesses one address may make across all its codes (both flows) before it is locked. */
export const EMAIL_LOCKOUT_FAILURES = 10;
/** Failures count while their code was issued less than this long ago (spec/sync.md "信箱驗證碼"). */
export const EMAIL_LOCKOUT_WINDOW_MS = 24 * 60 * 60 * 1000;
const LIMIT_WINDOW_MS = 60 * 60 * 1000;
const MAX_EMAIL_LENGTH = 254;

/** Trimmed, lowercased address, or null when it is not shaped like one. */
export function normalizeEmail(raw: unknown): string | null {
  if (typeof raw !== 'string') return null;
  const email = raw.trim().toLowerCase();
  if (email.length > MAX_EMAIL_LENGTH || !/^[^\s@]+@[^\s@]+$/.test(email)) return null;
  return email;
}

/** Uniform 6-digit code (rejection sampling avoids modulo bias). */
export function generateEmailCode(): string {
  const limit = Math.floor(0x1_0000_0000 / 1_000_000) * 1_000_000;
  const buf = new Uint32Array(1);
  for (;;) {
    crypto.getRandomValues(buf);
    if (buf[0] < limit) return String(buf[0] % 1_000_000).padStart(6, '0');
  }
}

function hashCode(code: string, salt: string): Promise<string> {
  return sha256Hex(code + salt);
}

function pendingMatches(pendingId: string | null) {
  return pendingId === null ? isNull(emailCode.pendingId) : eq(emailCode.pendingId, pendingId);
}

/**
 * True while `email` has fewer than EMAIL_LOCKOUT_FAILURES wrong guesses on codes issued inside
 * the window. `attempts` counts wrong guesses only, so the sum is the failure count. A subquery
 * (aliased so it never binds to an outer emailCode) lets the guess UPDATE check it atomically.
 */
function notLockedOut(email: string, now: number) {
  return sql`(SELECT coalesce(sum(f.attempts), 0) FROM ${emailCode} AS f WHERE f.email = ${email} AND f.createdAt > ${now - EMAIL_LOCKOUT_WINDOW_MS}) < ${EMAIL_LOCKOUT_FAILURES}`;
}

export type EmailStartOutcome = 'sent' | 'mail_failed' | 'locked' | 'rate_limited_email' | 'rate_limited_ip';

/**
 * Issues a code for `email` and mails it. While the address is locked out, or over the
 * per-address or per-IP hourly limit, nothing is stored or sent. A new code replaces the older
 * live codes of the same flow only: App codes (no pending) or codes of the same pending. Never
 * reveals whether an account exists: the identity table is not consulted.
 */
export async function startEmailCode(
  database: DatabaseClient,
  params: { email: string; ip: string | null; mailer: Mailer; pendingId?: string | null; now?: number },
): Promise<EmailStartOutcome> {
  const now = params.now ?? systemNow();
  const email = params.email.trim().toLowerCase();
  const ipHash = await sha256Hex(`email|${ipRateKey(params.ip)}`);
  const since = now - LIMIT_WINDOW_MS;
  const pendingId = params.pendingId ?? null;

  const [[recent], [byEmail], [byIp]] = await database.batch([
    database
      .select({ failures: sql<number>`coalesce(sum(${emailCode.attempts}), 0)` })
      .from(emailCode)
      .where(and(eq(emailCode.email, email), gt(emailCode.createdAt, now - EMAIL_LOCKOUT_WINDOW_MS))),
    database
      .select({ n: count() })
      .from(emailCode)
      .where(and(eq(emailCode.email, email), gt(emailCode.createdAt, since))),
    database
      .select({ n: count() })
      .from(emailCode)
      .where(and(eq(emailCode.ipHash, ipHash), gt(emailCode.createdAt, since))),
  ]);
  if (Number(recent.failures) >= EMAIL_LOCKOUT_FAILURES) {
    logEvent('warn', 'auth.email.start', { outcome: 'locked' });
    return 'locked';
  }
  if (byEmail.n >= EMAIL_START_LIMIT_PER_EMAIL || byIp.n >= EMAIL_START_LIMIT_PER_IP) {
    const outcome = byEmail.n >= EMAIL_START_LIMIT_PER_EMAIL ? 'rate_limited_email' : 'rate_limited_ip';
    logEvent('warn', 'auth.email.start', { outcome });
    return outcome;
  }

  const code = generateEmailCode();
  const salt = randomB64url(16);
  await database.batch([
    // Rows are kept (not deleted) because they are the rate-limit ledger.
    database
      .update(emailCode)
      .set({ usedAt: now })
      .where(
        and(eq(emailCode.email, email), pendingMatches(pendingId), isNull(emailCode.usedAt), gt(emailCode.expiresAt, now)),
      ),
    database.insert(emailCode).values({
      id: crypto.randomUUID(),
      email,
      codeHash: await hashCode(code, salt),
      salt,
      attempts: 0,
      createdAt: now,
      expiresAt: now + EMAIL_CODE_TTL_MS,
      usedAt: null,
      pendingId,
      ipHash,
    }),
  ]);

  const result = await params.mailer.send({ to: email, ...renderCodeEmail(code) });
  const outcome = result.ok ? 'sent' : 'mail_failed';
  logEvent(result.ok ? 'log' : 'warn', 'auth.email.start', { outcome });
  return outcome;
}

/**
 * Consumes the live code for `email` (and `pendingId`; null for App sign-in). A wrong guess spends
 * one attempt and the right one consumes the code, both in one conditional UPDATE that also
 * re-checks the per-address lockout, so concurrent guesses cannot exceed either limit and a code
 * is accepted at most once. A locked address is refused without touching any row.
 */
export async function verifyEmailCode(
  database: DatabaseClient,
  params: { email: string; code: string; pendingId?: string | null; now?: number },
): Promise<boolean> {
  const now = params.now ?? systemNow();
  const email = params.email.trim().toLowerCase();
  const pendingId = params.pendingId ?? null;
  const live = and(
    isNull(emailCode.usedAt),
    gt(emailCode.expiresAt, now),
    lt(emailCode.attempts, EMAIL_CODE_MAX_ATTEMPTS),
    notLockedOut(email, now),
  );

  const row = await database
    .select({ id: emailCode.id, codeHash: emailCode.codeHash, salt: emailCode.salt })
    .from(emailCode)
    .where(and(eq(emailCode.email, email), pendingMatches(pendingId), live))
    .orderBy(desc(emailCode.createdAt))
    .get();
  if (!row) return false;

  const matched = /^\d{6}$/.test(params.code) && (await hashCode(params.code, row.salt)) === row.codeHash;
  const updated = await database
    .update(emailCode)
    .set(matched ? { usedAt: now } : { attempts: sql`${emailCode.attempts} + 1` })
    .where(and(eq(emailCode.id, row.id), live))
    .returning({ id: emailCode.id });
  return matched && updated.length === 1;
}
