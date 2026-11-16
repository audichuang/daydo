import type { DatabaseSync } from 'node:sqlite';
import { afterEach, describe, expect, it, vi } from 'vitest';
import {
  EMAIL_CODE_MAX_ATTEMPTS,
  EMAIL_CODE_TTL_MS,
  EMAIL_LOCKOUT_FAILURES,
  EMAIL_LOCKOUT_WINDOW_MS,
  EMAIL_START_LIMIT_PER_EMAIL,
  EMAIL_START_LIMIT_PER_IP,
  generateEmailCode,
  handleEmailStart,
  handleEmailVerify,
  normalizeEmail,
  startEmailCode,
  verifyEmailCode,
} from '../src/auth/email';
import { createSessionForIdentity, type DatabaseClient } from '../src/auth/session';
import { EMAIL_CODE_RETENTION_MS, cleanupExpiredOAuth } from '../src/oauth/cleanup';
import type { MailMessage, MailResult, Mailer } from '../src/mail/mailer';
import { createTestD1 } from './sqliteD1';

const NOW = Date.UTC(2027, 0, 15, 10, 0, 0);
const HOUR = 60 * 60 * 1000;
const JWT_SECRET = 'unit-test-jwt-secret-32-bytes-minimum';
const EMAIL = 'pokemon@example.com';
const IP = '203.0.113.7';

function setup() {
  const { db, sqlite } = createTestD1();
  return { sqlite, database: db as unknown as DatabaseClient };
}

function fakeMailer(result: MailResult = { ok: true }) {
  const sent: MailMessage[] = [];
  const mailer: Mailer = {
    async send(message) {
      sent.push(message);
      return result;
    },
  };
  return {
    mailer,
    sent,
    lastCode(): string {
      const last = sent.at(-1);
      if (!last) throw new Error('no mail sent');
      const code = /\b(\d{6})\b/.exec(last.text)?.[1];
      if (!code) throw new Error('no code in mail');
      return code;
    },
  };
}

function captureLogs() {
  const lines: string[] = [];
  for (const level of ['log', 'info', 'warn', 'error', 'debug'] as const) {
    vi.spyOn(console, level).mockImplementation((...args: unknown[]) => {
      lines.push(args.map((a) => (typeof a === 'string' ? a : JSON.stringify(a))).join(' '));
    });
  }
  return lines;
}

function rows(sqlite: DatabaseSync) {
  return sqlite
    .prepare('SELECT email, codeHash, salt, attempts, createdAt, expiresAt, usedAt, pendingId, ipHash FROM emailCode ORDER BY createdAt')
    .all() as Array<Record<string, unknown>>;
}

async function start(database: DatabaseClient, mail: ReturnType<typeof fakeMailer>, over: Partial<{ email: string; ip: string | null; now: number; pendingId: string | null }> = {}) {
  return startEmailCode(database, {
    email: over.email ?? EMAIL,
    ip: over.ip === undefined ? IP : over.ip,
    mailer: mail.mailer,
    pendingId: over.pendingId,
    now: over.now ?? NOW,
  });
}

afterEach(() => vi.restoreAllMocks());

describe('email code helpers', () => {
  it('normalizes the address (trim, lowercase) and rejects non-addresses', () => {
    expect(normalizeEmail('  Pokemon@Example.COM ')).toBe('pokemon@example.com');
    for (const bad of [undefined, null, 42, '', '   ', 'no-at-sign', '@example.com', 'a@', 'a b@example.com', `${'a'.repeat(250)}@example.com`]) {
      expect(normalizeEmail(bad), String(bad)).toBeNull();
    }
  });

  it('generates six-digit codes, keeping leading zeros', () => {
    for (let i = 0; i < 200; i++) expect(generateEmailCode()).toMatch(/^\d{6}$/);
  });
});

describe('startEmailCode', () => {
  it('stores only a salted hash of the code, with a 10-minute expiry, and mails the code', async () => {
    const { sqlite, database } = setup();
    vi.spyOn(console, 'log').mockImplementation(() => {});
    const mail = fakeMailer();
    expect(await start(database, mail, { email: '  Pokemon@Example.com' })).toBe('sent');

    expect(mail.sent).toHaveLength(1);
    expect(mail.sent[0].to).toBe(EMAIL);
    expect(mail.sent[0].subject).toBe('你的 DayDo 驗證碼');
    const code = mail.lastCode();

    const [row] = rows(sqlite);
    expect(row.email).toBe(EMAIL);
    expect(row.attempts).toBe(0);
    expect(row.expiresAt).toBe(NOW + EMAIL_CODE_TTL_MS);
    expect(EMAIL_CODE_TTL_MS).toBe(10 * 60 * 1000);
    expect(row.usedAt).toBeNull();
    expect(row.pendingId).toBeNull();
    expect(typeof row.salt).toBe('string');
    expect(row.codeHash).not.toContain(code);
    expect(JSON.stringify(row)).not.toContain(code);
    expect(row.ipHash).not.toContain(IP);
  });

  it('invalidates older live codes for the same address', async () => {
    const { database } = setup();
    vi.spyOn(console, 'log').mockImplementation(() => {});
    const mail = fakeMailer();
    await start(database, mail);
    const first = mail.lastCode();
    await start(database, mail, { now: NOW + 1000 });
    const second = mail.lastCode();

    if (first !== second) {
      expect(await verifyEmailCode(database, { email: EMAIL, code: first, now: NOW + 2000 })).toBe(false);
    }
    expect(await verifyEmailCode(database, { email: EMAIL, code: second, now: NOW + 2000 })).toBe(true);
  });

  it('a new App start leaves a code bound to an MCP pending for the address live', async () => {
    const { sqlite, database } = setup();
    vi.spyOn(console, 'log').mockImplementation(() => {});
    const mail = fakeMailer();
    await start(database, mail, { pendingId: 'pending-a' });
    const mcpCode = mail.lastCode();
    await start(database, mail, { now: NOW + 1000 });
    const appCode = mail.lastCode();
    expect(rows(sqlite)[0].usedAt).toBeNull();
    expect(await verifyEmailCode(database, { email: EMAIL, code: mcpCode, pendingId: 'pending-a', now: NOW + 2000 })).toBe(true);
    expect(await verifyEmailCode(database, { email: EMAIL, code: appCode, now: NOW + 2000 })).toBe(true);
  });

  it("an MCP start replaces only its own pending's older code, leaving App and other pendings' codes live", async () => {
    const { database } = setup();
    vi.spyOn(console, 'log').mockImplementation(() => {});
    const mail = fakeMailer();
    await start(database, mail);
    const appCode = mail.lastCode();
    await start(database, mail, { pendingId: 'pending-a', now: NOW + 1 });
    const a1 = mail.lastCode();
    await start(database, mail, { pendingId: 'pending-b', now: NOW + 2 });
    const b1 = mail.lastCode();
    await start(database, mail, { pendingId: 'pending-a', now: NOW + 3 });
    const a2 = mail.lastCode();

    if (a1 !== a2) {
      expect(await verifyEmailCode(database, { email: EMAIL, code: a1, pendingId: 'pending-a', now: NOW + 10 })).toBe(false);
    }
    expect(await verifyEmailCode(database, { email: EMAIL, code: b1, pendingId: 'pending-b', now: NOW + 10 })).toBe(true);
    expect(await verifyEmailCode(database, { email: EMAIL, code: a2, pendingId: 'pending-a', now: NOW + 10 })).toBe(true);
    expect(await verifyEmailCode(database, { email: EMAIL, code: appCode, now: NOW + 10 })).toBe(true);
  });

  it('a new start leaves other addresses alone', async () => {
    const { database } = setup();
    vi.spyOn(console, 'log').mockImplementation(() => {});
    const mail = fakeMailer();
    await start(database, mail, { email: 'other@example.com' });
    const otherCode = mail.lastCode();
    await start(database, mail, { now: NOW + 1000 });
    expect(await verifyEmailCode(database, { email: 'other@example.com', code: otherCode, now: NOW + 2000 })).toBe(true);
  });

  it(`limits each address to ${EMAIL_START_LIMIT_PER_EMAIL} starts per hour without sending more mail`, async () => {
    const { sqlite, database } = setup();
    const lines = captureLogs();
    const mail = fakeMailer();
    expect(EMAIL_START_LIMIT_PER_EMAIL).toBe(5);
    for (let i = 0; i < 5; i++) {
      // Different IPs so only the per-address limit applies.
      expect(await start(database, mail, { ip: `198.51.100.${i + 1}`, now: NOW + i })).toBe('sent');
    }
    const lastLiveCode = mail.lastCode();
    expect(await start(database, mail, { ip: '198.51.100.99', now: NOW + 10 })).toBe('rate_limited_email');
    expect(mail.sent).toHaveLength(5);
    expect(rows(sqlite)).toHaveLength(5);
    expect(lines.some((l) => l.includes('"event":"auth.email.start"') && l.includes('rate_limited_email'))).toBe(true);
    // A rejected start does not invalidate the live code.
    expect(await verifyEmailCode(database, { email: EMAIL, code: lastLiveCode, now: NOW + 20 })).toBe(true);

    // The window slides: an hour after the first start, one more is allowed.
    expect(await start(database, mail, { ip: '198.51.100.99', now: NOW + HOUR + 1 })).toBe('sent');
  });

  it(`limits each source IP to ${EMAIL_START_LIMIT_PER_IP} starts per hour, IPv6 by /64`, async () => {
    const { database } = setup();
    captureLogs();
    const mail = fakeMailer();
    expect(EMAIL_START_LIMIT_PER_IP).toBe(20);
    for (let i = 0; i < 20; i++) {
      const ip = `2001:db8:1:2::${(i + 1).toString(16)}`;
      expect(await start(database, mail, { email: `u${i}@example.com`, ip, now: NOW + i })).toBe('sent');
    }
    expect(await start(database, mail, { email: 'u99@example.com', ip: '2001:db8:1:2:ffff::1', now: NOW + 30 })).toBe(
      'rate_limited_ip',
    );
    expect(mail.sent).toHaveLength(20);
    // Another /64 is unaffected.
    expect(await start(database, mail, { email: 'u99@example.com', ip: '2001:db8:1:3::1', now: NOW + 31 })).toBe('sent');
  });

  it('reports a mail failure but keeps the row (it still counts toward the limits)', async () => {
    const { sqlite, database } = setup();
    captureLogs();
    const mail = fakeMailer({ ok: false, reason: 'send_failed' });
    expect(await start(database, mail)).toBe('mail_failed');
    expect(rows(sqlite)).toHaveLength(1);
  });
});

describe('verifyEmailCode', () => {
  it('accepts the code once (single use)', async () => {
    const { sqlite, database } = setup();
    vi.spyOn(console, 'log').mockImplementation(() => {});
    const mail = fakeMailer();
    await start(database, mail);
    const code = mail.lastCode();
    expect(await verifyEmailCode(database, { email: ' POKEMON@example.com ', code, now: NOW + 1 })).toBe(true);
    expect(rows(sqlite)[0].usedAt).toBe(NOW + 1);
    expect(await verifyEmailCode(database, { email: EMAIL, code, now: NOW + 2 })).toBe(false);
  });

  it('accepts the code only once when two verifies race', async () => {
    const { database } = setup();
    vi.spyOn(console, 'log').mockImplementation(() => {});
    const mail = fakeMailer();
    await start(database, mail);
    const code = mail.lastCode();
    const results = await Promise.all([
      verifyEmailCode(database, { email: EMAIL, code, now: NOW + 1 }),
      verifyEmailCode(database, { email: EMAIL, code, now: NOW + 1 }),
    ]);
    expect(results.filter(Boolean)).toHaveLength(1);
  });

  it('rejects an expired code', async () => {
    const { database } = setup();
    vi.spyOn(console, 'log').mockImplementation(() => {});
    const mail = fakeMailer();
    await start(database, mail);
    const code = mail.lastCode();
    expect(await verifyEmailCode(database, { email: EMAIL, code, now: NOW + EMAIL_CODE_TTL_MS })).toBe(false);
  });

  it(`counts every attempt; after ${EMAIL_CODE_MAX_ATTEMPTS} wrong ones even the right code fails`, async () => {
    const { sqlite, database } = setup();
    vi.spyOn(console, 'log').mockImplementation(() => {});
    const mail = fakeMailer();
    await start(database, mail);
    const code = mail.lastCode();
    const wrong = code === '000000' ? '111111' : '000000';
    expect(EMAIL_CODE_MAX_ATTEMPTS).toBe(5);
    for (let i = 0; i < 5; i++) {
      expect(await verifyEmailCode(database, { email: EMAIL, code: wrong, now: NOW + 1 + i })).toBe(false);
      expect(rows(sqlite)[0].attempts).toBe(i + 1);
    }
    expect(await verifyEmailCode(database, { email: EMAIL, code, now: NOW + 10 })).toBe(false);
    expect(rows(sqlite)[0].attempts).toBe(5);
    expect(rows(sqlite)[0].usedAt).toBeNull();
  });

  it('accepts the right code on the fifth attempt', async () => {
    const { database } = setup();
    vi.spyOn(console, 'log').mockImplementation(() => {});
    const mail = fakeMailer();
    await start(database, mail);
    const code = mail.lastCode();
    const wrong = code === '000000' ? '111111' : '000000';
    for (let i = 0; i < 4; i++) await verifyEmailCode(database, { email: EMAIL, code: wrong, now: NOW + 1 });
    expect(await verifyEmailCode(database, { email: EMAIL, code, now: NOW + 2 })).toBe(true);
  });

  it('counts only wrong guesses as attempts: the accepted guess is not a failure', async () => {
    const { sqlite, database } = setup();
    vi.spyOn(console, 'log').mockImplementation(() => {});
    const mail = fakeMailer();
    await start(database, mail);
    const code = mail.lastCode();
    const wrong = code === '000000' ? '111111' : '000000';
    for (let i = 0; i < 4; i++) await verifyEmailCode(database, { email: EMAIL, code: wrong, now: NOW + 1 });
    expect(await verifyEmailCode(database, { email: EMAIL, code, now: NOW + 2 })).toBe(true);
    expect(rows(sqlite)[0]).toMatchObject({ attempts: 4, usedAt: NOW + 2 });
  });

  it('does not let a code verify for another address', async () => {
    const { database } = setup();
    vi.spyOn(console, 'log').mockImplementation(() => {});
    const mail = fakeMailer();
    await start(database, mail);
    const code = mail.lastCode();
    expect(await verifyEmailCode(database, { email: 'someone-else@example.com', code, now: NOW + 1 })).toBe(false);
  });

  it('binds a code to its pending id: App codes have none, MCP codes only verify for their pending', async () => {
    const { database } = setup();
    vi.spyOn(console, 'log').mockImplementation(() => {});
    const mail = fakeMailer();
    await start(database, mail, { pendingId: 'pending-a' });
    const code = mail.lastCode();
    expect(await verifyEmailCode(database, { email: EMAIL, code, now: NOW + 1 })).toBe(false);
    expect(await verifyEmailCode(database, { email: EMAIL, code, pendingId: 'pending-b', now: NOW + 1 })).toBe(false);
    expect(await verifyEmailCode(database, { email: EMAIL, code, pendingId: 'pending-a', now: NOW + 1 })).toBe(true);
  });
});

describe('per-address failure lockout', () => {
  const DAY = 24 * HOUR;

  /** Starts a code (App flow unless `pendingId`) and guesses wrong `n` times; returns the code. */
  async function failWith(
    database: DatabaseClient,
    mail: ReturnType<typeof fakeMailer>,
    n: number,
    over: { now: number; pendingId?: string | null },
  ): Promise<string> {
    expect(await start(database, mail, over)).toBe('sent');
    const code = mail.lastCode();
    const wrong = code === '000000' ? '111111' : '000000';
    for (let i = 0; i < n; i++) {
      await verifyEmailCode(database, { email: EMAIL, code: wrong, pendingId: over.pendingId, now: over.now + 1 });
    }
    return code;
  }

  function totalAttempts(sqlite: DatabaseSync): number {
    return rows(sqlite).reduce((sum, r) => sum + Number(r.attempts), 0);
  }

  it(`locks verify after ${EMAIL_LOCKOUT_FAILURES} wrong guesses across codes, even with the right code`, async () => {
    const { sqlite, database } = setup();
    captureLogs();
    const mail = fakeMailer();
    expect(EMAIL_LOCKOUT_FAILURES).toBe(10);
    expect(EMAIL_LOCKOUT_WINDOW_MS).toBe(DAY);
    await failWith(database, mail, 5, { now: NOW });
    await failWith(database, mail, 4, { now: NOW + 1000 });
    // The third code has spent only one of its own five attempts.
    const third = await failWith(database, mail, 1, { now: NOW + 2000 });
    expect(totalAttempts(sqlite)).toBe(10);

    expect(await verifyEmailCode(database, { email: EMAIL, code: third, now: NOW + 3000 })).toBe(false);
    // A locked verify spends nothing and consumes nothing.
    expect(rows(sqlite)[2]).toMatchObject({ attempts: 1, usedAt: null });
  });

  it('counts failures from both flows toward the same address', async () => {
    const { database } = setup();
    captureLogs();
    const mail = fakeMailer();
    await failWith(database, mail, 5, { now: NOW });
    await failWith(database, mail, 4, { now: NOW + 1000, pendingId: 'pending-a' });
    const mcp = await failWith(database, mail, 1, { now: NOW + 2000, pendingId: 'pending-a' });
    expect(await verifyEmailCode(database, { email: EMAIL, code: mcp, pendingId: 'pending-a', now: NOW + 3000 })).toBe(false);
  });

  it('a locked address gets no new code: start stores and sends nothing and logs "locked"', async () => {
    const { sqlite, database } = setup();
    const lines = captureLogs();
    const mail = fakeMailer();
    await failWith(database, mail, 5, { now: NOW });
    const liveCode = await failWith(database, mail, 4, { now: NOW + 1000 });
    await failWith(database, mail, 5, { now: NOW + 2000, pendingId: 'pending-a' });

    expect(await start(database, mail, { now: NOW + 3000 })).toBe('locked');
    expect(await start(database, mail, { now: NOW + 3001, pendingId: 'pending-b' })).toBe('locked');
    expect(mail.sent).toHaveLength(3);
    expect(rows(sqlite)).toHaveLength(3);
    expect(lines.some((l) => l.includes('"event":"auth.email.start"') && l.includes('"outcome":"locked"'))).toBe(true);
    // The route still answers 202 {sent:true}.
    expect(
      await handleEmailStart(database, { body: { email: EMAIL, deviceId: 'd' }, ip: IP, mailer: mail.mailer, now: NOW + 3002 }),
    ).toEqual({ status: 202, body: { sent: true } });
    expect(mail.sent).toHaveLength(3);
    // The App code still live from before the lock is locked too.
    expect(await verifyEmailCode(database, { email: EMAIL, code: liveCode, now: NOW + 3003 })).toBe(false);
  });

  it('lifts once the failed codes are 24 hours old', async () => {
    const { database } = setup();
    captureLogs();
    const mail = fakeMailer();
    await failWith(database, mail, 5, { now: NOW });
    await failWith(database, mail, 5, { now: NOW + 1000 });

    expect(await start(database, mail, { now: NOW + DAY - 1 })).toBe('locked');
    expect(mail.sent).toHaveLength(2);
    // The first code's five failures leave the window; five remain.
    expect(await start(database, mail, { now: NOW + DAY })).toBe('sent');
    expect(await verifyEmailCode(database, { email: EMAIL, code: mail.lastCode(), now: NOW + DAY + 1 })).toBe(true);
  });

  it('an accepted guess does not count toward the lockout', async () => {
    const { database } = setup();
    captureLogs();
    const mail = fakeMailer();
    await failWith(database, mail, 5, { now: NOW });
    const second = await failWith(database, mail, 4, { now: NOW + 1000 });
    expect(await verifyEmailCode(database, { email: EMAIL, code: second, now: NOW + 2000 })).toBe(true);
    // Nine failures: the address can still sign in.
    expect(await start(database, mail, { now: NOW + 3000 })).toBe('sent');
    expect(await verifyEmailCode(database, { email: EMAIL, code: mail.lastCode(), now: NOW + 3001 })).toBe(true);
  });

  it('concurrent wrong guesses on several live codes cannot pass the lockout', async () => {
    const { sqlite, database } = setup();
    captureLogs();
    const mail = fakeMailer();
    await failWith(database, mail, 5, { now: NOW });
    const mcp = await failWith(database, mail, 4, { now: NOW + 1000, pendingId: 'pending-a' });
    const app = await failWith(database, mail, 0, { now: NOW + 2000 });
    expect(totalAttempts(sqlite)).toBe(9);
    const wrongApp = app === '000000' ? '111111' : '000000';
    const wrongMcp = mcp === '000000' ? '111111' : '000000';

    await Promise.all([
      ...Array.from({ length: 3 }, () => verifyEmailCode(database, { email: EMAIL, code: wrongApp, now: NOW + 3000 })),
      ...Array.from({ length: 3 }, () =>
        verifyEmailCode(database, { email: EMAIL, code: wrongMcp, pendingId: 'pending-a', now: NOW + 3000 }),
      ),
    ]);
    expect(totalAttempts(sqlite)).toBe(10);
  });

  it('the hourly cleanup keeps the rows the lockout still counts', async () => {
    const { database } = setup();
    captureLogs();
    const mail = fakeMailer();
    await failWith(database, mail, 5, { now: NOW });
    await failWith(database, mail, 5, { now: NOW + 1000 });
    expect(EMAIL_CODE_RETENTION_MS).toBeGreaterThanOrEqual(EMAIL_LOCKOUT_WINDOW_MS);

    await cleanupExpiredOAuth(database, NOW + DAY - 1);
    expect(await start(database, mail, { now: NOW + DAY - 1 })).toBe('locked');
  });
});

describe('handleEmailStart (POST /auth/email/start)', () => {
  it('rejects a malformed body with 400', async () => {
    const { database } = setup();
    const mail = fakeMailer();
    for (const body of [null, {}, { email: 'not-an-email', deviceId: 'd' }, { email: EMAIL }]) {
      const res = await handleEmailStart(database, { body, ip: IP, mailer: mail.mailer, now: NOW });
      expect(res.status, JSON.stringify(body)).toBe(400);
    }
    expect(mail.sent).toHaveLength(0);
  });

  it('answers 202 {sent:true} whether or not the account exists, when limited, and when mail fails', async () => {
    const { database } = setup();
    captureLogs();
    const ok = fakeMailer();
    // Existing account.
    await createSessionForIdentity(database, { provider: 'email', sub: EMAIL, email: EMAIL, deviceId: 'd0', jwtSecret: JWT_SECRET, now: NOW - HOUR * 2 });
    const responses = [
      await handleEmailStart(database, { body: { email: EMAIL, deviceId: 'd' }, ip: IP, mailer: ok.mailer, now: NOW }),
      await handleEmailStart(database, { body: { email: 'new@example.com', deviceId: 'd' }, ip: IP, mailer: ok.mailer, now: NOW }),
      await handleEmailStart(database, { body: { email: 'fail@example.com', deviceId: 'd' }, ip: IP, mailer: fakeMailer({ ok: false, reason: 'send_failed' }).mailer, now: NOW }),
    ];
    for (let i = 0; i < 5; i++) {
      await handleEmailStart(database, { body: { email: 'busy@example.com', deviceId: 'd' }, ip: `192.0.2.${i}`, mailer: ok.mailer, now: NOW });
    }
    responses.push(await handleEmailStart(database, { body: { email: 'busy@example.com', deviceId: 'd' }, ip: '192.0.2.200', mailer: ok.mailer, now: NOW }));
    for (const res of responses) expect(res).toEqual({ status: 202, body: { sent: true } });
    // The existing and new addresses got the same kind of mail.
    expect(ok.sent.slice(0, 2).map((m) => m.subject)).toEqual(['你的 DayDo 驗證碼', '你的 DayDo 驗證碼']);
  });
});

describe('handleEmailVerify (POST /auth/email/verify)', () => {
  async function signIn(database: DatabaseClient, mail: ReturnType<typeof fakeMailer>, email: string, deviceId: string, now: number) {
    await handleEmailStart(database, { body: { email, deviceId }, ip: IP, mailer: mail.mailer, now });
    return handleEmailVerify(database, { body: { email, code: mail.lastCode(), deviceId }, jwtSecret: JWT_SECRET, now: now + 1 });
  }

  it('signs up on the first verify and logs the same user in afterwards, with the Google/Apple response shape', async () => {
    const { sqlite, database } = setup();
    captureLogs();
    const mail = fakeMailer();
    const first = await signIn(database, mail, 'New.User@Example.com ', 'dev-1', NOW);
    expect(first.status).toBe(200);
    const body1 = first.body as Record<string, unknown>;
    expect(Object.keys(body1).sort()).toEqual(
      ['accessToken', 'avatarUrl', 'hasData', 'inboxProjectId', 'isNewAccount', 'meMemberId', 'refreshToken', 'user'].sort(),
    );
    expect(body1).toMatchObject({ isNewAccount: true, hasData: false, meMemberId: null, inboxProjectId: null, avatarUrl: null });
    const userId = (body1.user as { id: string }).id;
    expect(sqlite.prepare('SELECT provider, sub, userId, email FROM identity').all()).toEqual([
      { provider: 'email', sub: 'new.user@example.com', userId, email: 'new.user@example.com' },
    ]);

    const second = await signIn(database, mail, 'new.user@example.com', 'dev-2', NOW + 60_000);
    expect(second.status).toBe(200);
    expect(second.body).toMatchObject({ isNewAccount: false, user: { id: userId } });
  });

  it('does not merge with a Google account that has the same address', async () => {
    const { database } = setup();
    captureLogs();
    const google = await createSessionForIdentity(database, { provider: 'google', sub: 'g-1', email: EMAIL, deviceId: 'd', jwtSecret: JWT_SECRET, now: NOW });
    const res = await signIn(database, fakeMailer(), EMAIL, 'd', NOW);
    expect(res.status).toBe(200);
    expect(res.body).toMatchObject({ isNewAccount: true });
    expect((res.body as { user: { id: string } }).user.id).not.toBe(google.user.id);
  });

  it('answers the same 401 for a wrong, reused, expired, locked or unknown code', async () => {
    const { database } = setup();
    captureLogs();
    const mail = fakeMailer();
    const verify = (email: string, code: string, now: number) =>
      handleEmailVerify(database, { body: { email, code, deviceId: 'd' }, jwtSecret: JWT_SECRET, now });

    const failures = [];
    // No code was ever sent.
    failures.push(await verify('nobody@example.com', '123456', NOW));
    // Malformed code.
    failures.push(await verify(EMAIL, '12ab', NOW));

    await handleEmailStart(database, { body: { email: EMAIL, deviceId: 'd' }, ip: IP, mailer: mail.mailer, now: NOW });
    const code = mail.lastCode();
    const wrong = code === '000000' ? '111111' : '000000';
    failures.push(await verify(EMAIL, wrong, NOW + 1));
    expect((await verify(EMAIL, code, NOW + 2)).status).toBe(200);
    // Reused.
    failures.push(await verify(EMAIL, code, NOW + 3));

    // Expired.
    await handleEmailStart(database, { body: { email: 'late@example.com', deviceId: 'd' }, ip: IP, mailer: mail.mailer, now: NOW });
    failures.push(await verify('late@example.com', mail.lastCode(), NOW + EMAIL_CODE_TTL_MS + 1));

    // Locked after five wrong attempts.
    await handleEmailStart(database, { body: { email: 'locked@example.com', deviceId: 'd' }, ip: IP, mailer: mail.mailer, now: NOW });
    const lockedCode = mail.lastCode();
    const lockedWrong = lockedCode === '000000' ? '111111' : '000000';
    for (let i = 0; i < 5; i++) await verify('locked@example.com', lockedWrong, NOW + 1);
    failures.push(await verify('locked@example.com', lockedCode, NOW + 2));

    // Right code, but the address is locked after ten wrong guesses across codes.
    const lockedOut = 'locked-out@example.com';
    for (const n of [5, 4, 1]) {
      await handleEmailStart(database, { body: { email: lockedOut, deviceId: 'd' }, ip: IP, mailer: mail.mailer, now: NOW });
      const c = mail.lastCode();
      for (let i = 0; i < n; i++) await verify(lockedOut, c === '000000' ? '111111' : '000000', NOW + 1);
    }
    failures.push(await verify(lockedOut, mail.lastCode(), NOW + 2));

    const [firstFailure] = failures;
    expect(firstFailure.status).toBe(401);
    for (const res of failures) expect(res).toEqual(firstFailure);
  });

  it('rejects a malformed body with 400', async () => {
    const { database } = setup();
    for (const body of [null, {}, { email: EMAIL, code: '123456' }, { email: 'bad', code: '123456', deviceId: 'd' }, { email: EMAIL, deviceId: 'd' }]) {
      const res = await handleEmailVerify(database, { body, jwtSecret: JWT_SECRET, now: NOW });
      expect(res.status, JSON.stringify(body)).toBe(400);
    }
  });

  it('never writes the code to any log line', async () => {
    const { database } = setup();
    const lines = captureLogs();
    const mail = fakeMailer();
    await handleEmailStart(database, { body: { email: EMAIL, deviceId: 'd' }, ip: IP, mailer: mail.mailer, now: NOW });
    const code = mail.lastCode();
    const wrong = code === '000000' ? '111111' : '000000';
    await handleEmailVerify(database, { body: { email: EMAIL, code: wrong, deviceId: 'd' }, jwtSecret: JWT_SECRET, now: NOW + 1 });
    await handleEmailVerify(database, { body: { email: EMAIL, code, deviceId: 'd' }, jwtSecret: JWT_SECRET, now: NOW + 2 });
    expect(lines.length).toBeGreaterThan(0);
    for (const line of lines) {
      expect(line).not.toContain(code);
      expect(line).not.toContain(wrong);
    }
  });
});
