import type { DatabaseSync } from 'node:sqlite';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { EMAIL_CODE_MAX_ATTEMPTS, EMAIL_START_LIMIT_PER_EMAIL } from '../src/auth/email';
import type { DatabaseClient } from '../src/auth/session';
import type { MailMessage, Mailer } from '../src/mail/mailer';
import {
  PENDING_TTL_MS,
  bindCookieName,
  handleAuthorizeEmailStart,
  handleAuthorizeEmailVerify,
  handleAuthorizeGet,
  handleAuthorizePost,
  handleAuthorizeStart,
  type AuthorizeDeps,
} from '../src/oauth/authorize';
import { sha256b64url } from '../src/oauth/tokens';
import type { WebIdentityConfig } from '../src/oauth/webIdentity';
import { createTestD1 } from './sqliteD1';

// MCP authorize page, third option: email sign-in code for an existing user (spec/mcp.md 4.4 3b).

const ORIGIN = 'https://daydo-mcp.audichuang.app';
const NOW = 1_800_000_000_000;
const CLIENT_ID = 'mcp-client-a';
const REDIRECT_URI = 'https://claude.ai/api/mcp/auth_callback';
const VERIFIER = 'dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk';
const KNOWN_EMAIL = 'alice@example.com';

type Row = Record<string, unknown>;

function webConfig(): WebIdentityConfig {
  return {
    apple: { authUrl: 'https://appleid.apple.com/auth/authorize', audience: 'com.audichuang.daydo.web' },
    google: {
      clientId: 'google-web-client-id',
      clientSecret: undefined,
      authUrl: 'https://accounts.google.com/o/oauth2/v2/auth',
      tokenUrl: 'https://oauth2.googleapis.com/token',
    },
  };
}

function fakeMailer() {
  const sent: MailMessage[] = [];
  const mailer: Mailer = {
    async send(message) {
      sent.push(message);
      return { ok: true };
    },
  };
  return {
    mailer,
    sent,
    codeFor(address: string): string {
      const last = sent.filter((m) => m.to === address).at(-1);
      const code = last ? /\b(\d{6})\b/.exec(last.text)?.[1] : undefined;
      if (!code) throw new Error(`no code mailed to ${address}`);
      return code;
    },
  };
}

function setup() {
  const { db, sqlite } = createTestD1();
  sqlite.prepare('INSERT INTO user (id, createdAt, name) VALUES (?, ?, ?)').run('user-1', 0, 'Alice');
  sqlite
    .prepare('INSERT INTO identity (provider, sub, userId, email) VALUES (?, ?, ?, ?)')
    .run('email', KNOWN_EMAIL, 'user-1', KNOWN_EMAIL);
  sqlite
    .prepare('INSERT INTO oauthClient (clientId, clientName, redirectUris, ipHash, createdAt) VALUES (?, ?, ?, ?, ?)')
    .run(CLIENT_ID, 'Claude', JSON.stringify([REDIRECT_URI]), 'ip', 0);
  const database = db as unknown as DatabaseClient;
  const deps = (now = NOW): AuthorizeDeps => ({ database, web: webConfig(), now });
  return { sqlite, database, deps, mail: fakeMailer() };
}

type Setup = ReturnType<typeof setup>;

function count(sqlite: DatabaseSync, table: string): number {
  return (sqlite.prepare(`SELECT COUNT(*) AS n FROM ${table}`).get() as { n: number }).n;
}

function pendingRow(sqlite: DatabaseSync, id: string): Row {
  return sqlite.prepare('SELECT * FROM oauthPending WHERE id = ?').get(id) as Row;
}

function cookieHeader(pair: string | null): Record<string, string> {
  return pair ? { Cookie: `other=1; ${pair}` } : {};
}

function expectHtmlSecurityHeaders(res: Response) {
  expect(res.headers.get('Content-Type')).toContain('text/html');
  expect(res.headers.get('Content-Security-Policy')).toContain("frame-ancestors 'none'");
  expect(res.headers.get('X-Frame-Options')).toBe('DENY');
  expect(res.headers.get('Cache-Control')).toBe('no-store');
}

async function beginAuthorize(s: Setup) {
  const params = new URLSearchParams({
    response_type: 'code',
    client_id: CLIENT_ID,
    redirect_uri: REDIRECT_URI,
    scope: 'mcp offline_access',
    state: 'client-state-xyz',
    code_challenge: await sha256b64url(VERIFIER),
    code_challenge_method: 'S256',
  });
  const res = await handleAuthorizeGet(new Request(`${ORIGIN}/authorize?${params}`), s.deps());
  expect(res.status).toBe(200);
  const html = await res.text();
  const cookie = /(daydo_oauth_bind_[A-Za-z0-9_-]+=[^;]+)/.exec(res.headers.get('Set-Cookie') ?? '')?.[1];
  if (!cookie) throw new Error('no bind cookie');
  const pendingId = /\/authorize\/start\?pending=([A-Za-z0-9_-]+)&amp;provider=apple/.exec(html)?.[1];
  if (!pendingId) throw new Error(`no pending in ${html}`);
  return { html, pendingId, cookie };
}

async function emailStart(
  s: Setup,
  form: Record<string, unknown>,
  cookie: string | null,
  opts: { now?: number; ip?: string } = {},
) {
  return handleAuthorizeEmailStart(
    new Request(`${ORIGIN}/authorize/email/start`, {
      method: 'POST',
      headers: { 'CF-Connecting-IP': opts.ip ?? '203.0.113.7', ...cookieHeader(cookie) },
    }),
    form,
    s.deps(opts.now),
    s.mail.mailer,
  );
}

async function emailVerify(s: Setup, form: Record<string, unknown>, cookie: string | null, now?: number) {
  return handleAuthorizeEmailVerify(
    new Request(`${ORIGIN}/authorize/email/verify`, { method: 'POST', headers: cookieHeader(cookie) }),
    form,
    s.deps(now),
  );
}

function wrongCode(code: string): string {
  return code === '000000' ? '111111' : '000000';
}

function emailCodeRows(sqlite: DatabaseSync): Row[] {
  return sqlite.prepare('SELECT email, pendingId, attempts, usedAt FROM emailCode ORDER BY createdAt').all() as Row[];
}

afterEach(() => vi.restoreAllMocks());

describe('login page email option', () => {
  it('shows an email form that posts the pending id to /authorize/email/start', async () => {
    const s = setup();
    const { html, pendingId } = await beginAuthorize(s);
    expect(html).toContain('action="/authorize/email/start"');
    expect(html).toContain(`name="pending" value="${pendingId}"`);
    expect(html).toMatch(/<input[^>]+type="email"[^>]+name="email"/);
  });
});

describe('POST /authorize/email/start', () => {
  it('mails a code bound to the pending, marks the pending as email and shows the code form', async () => {
    const s = setup();
    const { pendingId, cookie } = await beginAuthorize(s);
    const res = await emailStart(s, { pending: pendingId, email: '  Alice@Example.com ' }, cookie);
    expect(res.status).toBe(200);
    expectHtmlSecurityHeaders(res);
    const html = await res.text();
    expect(html).toContain('action="/authorize/email/verify"');
    expect(html).toContain(`name="pending" value="${pendingId}"`);
    expect(html).toContain(`name="email" value="${KNOWN_EMAIL}"`);
    expect(html).toContain('已寄出');

    expect(s.mail.sent).toHaveLength(1);
    expect(s.mail.sent[0].to).toBe(KNOWN_EMAIL);
    expect(emailCodeRows(s.sqlite)).toEqual([{ email: KNOWN_EMAIL, pendingId, attempts: 0, usedAt: null }]);
    expect(pendingRow(s.sqlite, pendingId)).toMatchObject({ provider: 'email', userId: null, consumedAt: null });
  });

  it('shows the same page for an unknown address (the identity table is not consulted)', async () => {
    const s = setup();
    const { pendingId, cookie } = await beginAuthorize(s);
    const res = await emailStart(s, { pending: pendingId, email: 'nobody@example.com' }, cookie);
    expect(res.status).toBe(200);
    expect(await res.text()).toContain('已寄出');
    expect(s.mail.sent).toHaveLength(1);
  });

  it('shows the same "sent" page without mailing when the address is over its hourly limit', async () => {
    const s = setup();
    const { pendingId, cookie } = await beginAuthorize(s);
    for (let i = 0; i < EMAIL_START_LIMIT_PER_EMAIL; i += 1) {
      expect((await emailStart(s, { pending: pendingId, email: KNOWN_EMAIL }, cookie)).status).toBe(200);
    }
    expect(s.mail.sent).toHaveLength(EMAIL_START_LIMIT_PER_EMAIL);
    const limited = await emailStart(s, { pending: pendingId, email: KNOWN_EMAIL }, cookie);
    expect(limited.status).toBe(200);
    expect(await limited.text()).toContain('已寄出');
    expect(s.mail.sent).toHaveLength(EMAIL_START_LIMIT_PER_EMAIL);
  });

  it('refuses a browser without the matching bind cookie: no mail, no code, pending kept', async () => {
    const s = setup();
    const { pendingId, cookie } = await beginAuthorize(s);
    for (const bad of [null, `${bindCookieName(pendingId)}=someone-else`]) {
      const res = await emailStart(s, { pending: pendingId, email: KNOWN_EMAIL }, bad);
      expect(res.status).toBe(400);
      expect(await res.text()).toContain('同一個瀏覽器');
    }
    expect(s.mail.sent).toHaveLength(0);
    expect(count(s.sqlite, 'emailCode')).toBe(0);
    expect(pendingRow(s.sqlite, pendingId)).toMatchObject({ provider: '', consumedAt: null });
    // The real browser can still continue.
    expect((await emailStart(s, { pending: pendingId, email: KNOWN_EMAIL }, cookie)).status).toBe(200);
  });

  it('refuses an expired, unknown or already bound pending without mailing', async () => {
    const s = setup();
    const { pendingId, cookie } = await beginAuthorize(s);
    const expired = await emailStart(s, { pending: pendingId, email: KNOWN_EMAIL }, cookie, {
      now: NOW + PENDING_TTL_MS,
    });
    expect(expired.status).toBe(400);
    expect(await expired.text()).toContain('已失效或已完成');
    const unknown = await emailStart(s, { pending: 'nope', email: KNOWN_EMAIL }, cookie);
    expect(unknown.status).toBe(400);
    expect(s.mail.sent).toHaveLength(0);
    expect(count(s.sqlite, 'emailCode')).toBe(0);

    // Bound: sign in once, then a second start on the same pending is refused.
    expect((await emailStart(s, { pending: pendingId, email: KNOWN_EMAIL }, cookie)).status).toBe(200);
    const code = s.mail.codeFor(KNOWN_EMAIL);
    expect((await emailVerify(s, { pending: pendingId, email: KNOWN_EMAIL, code }, cookie)).status).toBe(303);
    const bound = await emailStart(s, { pending: pendingId, email: KNOWN_EMAIL }, cookie);
    expect(bound.status).toBe(400);
    expect(await bound.text()).toContain('已失效或已完成');
    expect(s.mail.sent).toHaveLength(1);
  });

  it('shows the same "sent" page when the mail fails', async () => {
    const s = setup();
    const { pendingId, cookie } = await beginAuthorize(s);
    const failing: Mailer = { send: async () => ({ ok: false, reason: 'send_failed' }) };
    const res = await handleAuthorizeEmailStart(
      new Request(`${ORIGIN}/authorize/email/start`, { method: 'POST', headers: cookieHeader(cookie) }),
      { pending: pendingId, email: KNOWN_EMAIL },
      s.deps(),
      failing,
    );
    expect(res.status).toBe(200);
    expect(await res.text()).toContain('驗證碼已寄出');
  });

  it('rejects a malformed address without mailing', async () => {
    const s = setup();
    const { pendingId, cookie } = await beginAuthorize(s);
    const res = await emailStart(s, { pending: pendingId, email: 'not-an-email' }, cookie);
    expect(res.status).toBe(400);
    expect(s.mail.sent).toHaveLength(0);
  });

  it('escapes the address on the code page', async () => {
    const s = setup();
    const { pendingId, cookie } = await beginAuthorize(s);
    const res = await emailStart(s, { pending: pendingId, email: '"><script>x</script>@example.com' }, cookie);
    expect(res.status).toBe(200);
    const html = await res.text();
    expect(html).not.toContain('<script>');
    expect(html).toContain('&quot;&gt;&lt;script&gt;x&lt;/script&gt;@example.com');
  });
});

describe('POST /authorize/email/verify', () => {
  async function toCodeForm(s: Setup, email = KNOWN_EMAIL) {
    const flow = await beginAuthorize(s);
    expect((await emailStart(s, { pending: flow.pendingId, email }, flow.cookie)).status).toBe(200);
    return { ...flow, code: s.mail.codeFor(email) };
  }

  it('binds the existing user and goes on to the consent page, which approves into a code', async () => {
    const s = setup();
    const { pendingId, cookie, code } = await toCodeForm(s);
    const res = await emailVerify(s, { pending: pendingId, email: 'ALICE@example.com', code: ` ${code} ` }, cookie);
    expect(res.status).toBe(303);
    const location = new URL(res.headers.get('Location') ?? '', ORIGIN);
    expect(location.pathname).toBe('/authorize');
    expect(location.searchParams.get('pending')).toBe(pendingId);
    const ct = location.searchParams.get('ct') ?? '';
    expect(pendingRow(s.sqlite, pendingId)).toMatchObject({ userId: 'user-1', consumedAt: null });
    expect(emailCodeRows(s.sqlite)[0].usedAt).toBe(NOW);

    const consent = await handleAuthorizeGet(
      new Request(`${ORIGIN}/authorize?pending=${pendingId}&ct=${ct}`, { headers: cookieHeader(cookie) }),
      s.deps(),
    );
    expect(consent.status).toBe(200);
    expect(await consent.text()).toContain('Alice');

    const approve = await handleAuthorizePost(
      new Request(`${ORIGIN}/authorize`, { method: 'POST', headers: cookieHeader(cookie) }),
      { pending: pendingId, ct, decision: 'approve' },
      s.deps(),
    );
    expect(approve.status).toBe(302);
    expect(new URL(approve.headers.get('Location') ?? '').searchParams.get('code')).toMatch(/^[A-Za-z0-9_-]{43}$/);
    expect((s.sqlite.prepare('SELECT userId FROM oauthCode').get() as Row).userId).toBe('user-1');
  });

  it('re-shows the code form after a wrong code and keeps the pending, so the right code still works', async () => {
    const s = setup();
    const { pendingId, cookie, code } = await toCodeForm(s);
    const wrong = await emailVerify(s, { pending: pendingId, email: KNOWN_EMAIL, code: wrongCode(code) }, cookie);
    expect(wrong.status).toBe(400);
    expectHtmlSecurityHeaders(wrong);
    const html = await wrong.text();
    expect(html).toContain('驗證碼錯誤');
    expect(html).toContain('action="/authorize/email/verify"');
    expect(pendingRow(s.sqlite, pendingId)).toMatchObject({ userId: null, consumedAt: null });
    expect(emailCodeRows(s.sqlite)[0]).toMatchObject({ attempts: 1, usedAt: null });

    const right = await emailVerify(s, { pending: pendingId, email: KNOWN_EMAIL, code }, cookie);
    expect(right.status).toBe(303);
  });

  it(`stops accepting the code after ${EMAIL_CODE_MAX_ATTEMPTS} wrong attempts`, async () => {
    const s = setup();
    const { pendingId, cookie, code } = await toCodeForm(s);
    for (let i = 0; i < EMAIL_CODE_MAX_ATTEMPTS; i += 1) {
      expect((await emailVerify(s, { pending: pendingId, email: KNOWN_EMAIL, code: wrongCode(code) }, cookie)).status).toBe(400);
    }
    expect((await emailVerify(s, { pending: pendingId, email: KNOWN_EMAIL, code }, cookie)).status).toBe(400);
    expect(pendingRow(s.sqlite, pendingId).userId).toBeNull();
  });

  it('shows the unknown-identity page for an address without a DayDo account and creates nothing', async () => {
    const s = setup();
    const email = 'stranger@example.com';
    const { pendingId, cookie, code } = await toCodeForm(s, email);
    const users = count(s.sqlite, 'user');
    const identities = count(s.sqlite, 'identity');
    const res = await emailVerify(s, { pending: pendingId, email, code }, cookie);
    expect(res.status).toBe(403);
    expectHtmlSecurityHeaders(res);
    expect(await res.text()).toContain('還沒有 DayDo 帳號');
    expect(count(s.sqlite, 'user')).toBe(users);
    expect(count(s.sqlite, 'identity')).toBe(identities);
    expect(count(s.sqlite, 'session')).toBe(0);
    expect(pendingRow(s.sqlite, pendingId)).toMatchObject({ userId: null, consentTokenHash: null });
  });

  it('a cookie mismatch ends the pending without spending a code attempt', async () => {
    const s = setup();
    const { pendingId, cookie, code } = await toCodeForm(s);
    const res = await emailVerify(
      s,
      { pending: pendingId, email: KNOWN_EMAIL, code },
      `${bindCookieName(pendingId)}=someone-else`,
    );
    expect(res.status).toBe(400);
    expect(await res.text()).toContain('同一個瀏覽器');
    expect(pendingRow(s.sqlite, pendingId).consumedAt).toBe(NOW);
    expect(emailCodeRows(s.sqlite)[0]).toMatchObject({ attempts: 0, usedAt: null });

    const retry = await emailVerify(s, { pending: pendingId, email: KNOWN_EMAIL, code }, cookie);
    expect(retry.status).toBe(400);
    expect(await retry.text()).toContain('已失效或已完成');
    expect(pendingRow(s.sqlite, pendingId).userId).toBeNull();
  });

  it('refuses after the pending expires, without binding or spending the code', async () => {
    const s = setup();
    const { pendingId, cookie, code } = await toCodeForm(s);
    const res = await emailVerify(s, { pending: pendingId, email: KNOWN_EMAIL, code }, cookie, NOW + PENDING_TTL_MS);
    expect(res.status).toBe(400);
    expect(await res.text()).toContain('已失效或已完成');
    expect(pendingRow(s.sqlite, pendingId).userId).toBeNull();
    expect(emailCodeRows(s.sqlite)[0]).toMatchObject({ attempts: 0, usedAt: null });
  });

  it("does not accept another pending's code", async () => {
    const s = setup();
    const a = await toCodeForm(s, KNOWN_EMAIL);
    const b = await toCodeForm(s, 'bob@example.com');
    // B's pending, A's address and code: the code is bound to A's pending.
    const cross = await emailVerify(s, { pending: b.pendingId, email: KNOWN_EMAIL, code: a.code }, b.cookie);
    expect(cross.status).toBe(400);
    expect(pendingRow(s.sqlite, b.pendingId).userId).toBeNull();
    // A's code still works on A.
    const own = await emailVerify(s, { pending: a.pendingId, email: KNOWN_EMAIL, code: a.code }, a.cookie);
    expect(own.status).toBe(303);
  });

  it('refuses when the pending was switched to another provider after the code was sent', async () => {
    const s = setup();
    const { pendingId, cookie, code } = await toCodeForm(s);
    const apple = await handleAuthorizeStart(
      new Request(`${ORIGIN}/authorize/start?pending=${pendingId}&provider=apple`, { headers: cookieHeader(cookie) }),
      s.deps(),
    );
    expect(apple.status).toBe(302);
    const res = await emailVerify(s, { pending: pendingId, email: KNOWN_EMAIL, code }, cookie);
    expect(res.status).toBe(400);
    expect(pendingRow(s.sqlite, pendingId).userId).toBeNull();
  });

  it('logs the outcome without the code or the address', async () => {
    const s = setup();
    const lines: string[] = [];
    for (const level of ['log', 'warn', 'error'] as const) {
      vi.spyOn(console, level).mockImplementation((...args: unknown[]) => {
        lines.push(args.map(String).join(' '));
      });
    }
    const { pendingId, cookie, code } = await toCodeForm(s);
    await emailVerify(s, { pending: pendingId, email: KNOWN_EMAIL, code: wrongCode(code) }, cookie);
    await emailVerify(s, { pending: pendingId, email: KNOWN_EMAIL, code }, cookie);
    const authorizeLines = lines.filter((l) => l.includes('"oauth.authorize"')).map((l) => JSON.parse(l) as Row);
    expect(authorizeLines).toEqual([
      { event: 'oauth.authorize', provider: 'email', outcome: 'provider_error' },
      { event: 'oauth.authorize', provider: 'email', outcome: 'ok' },
    ]);
    for (const line of lines) {
      expect(line).not.toContain(code);
      expect(line).not.toContain(KNOWN_EMAIL);
    }
  });
});
