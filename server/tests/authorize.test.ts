import type { DatabaseSync } from 'node:sqlite';
import { createLocalJWKSet, exportJWK, generateKeyPair, SignJWT, type CryptoKey } from 'jose';
import { beforeAll, describe, expect, it } from 'vitest';
import { sha256Hex } from '../src/auth/crypto';
import type { KeySource } from '../src/auth/providers';
import type { DatabaseClient } from '../src/auth/session';
import {
  AUTHORIZE_LIMIT_PER_HOUR,
  bindCookieName,
  PENDING_TTL_MS,
  handleAppleCallback,
  handleAuthorizeGet,
  handleAuthorizePost,
  handleAuthorizeStart,
  type AuthorizeDeps,
} from '../src/oauth/authorize';
import { esc } from '../src/oauth/pages';
import { handleToken } from '../src/oauth/token';
import { sha256b64url } from '../src/oauth/tokens';
import { appleAuthorizeUrl, type WebIdentityConfig } from '../src/oauth/webIdentity';
import { createTestD1 } from './sqliteD1';

const ORIGIN = 'https://daydo-mcp.audichuang.app';
const NOW = 1_800_000_000_000;
const CLIENT_ID = 'mcp-client-a';
const REDIRECT_URI = 'https://claude.ai/api/mcp/auth_callback';
const VERIFIER = 'dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk';
const APPLE_WEB_AUDIENCE = 'com.audichuang.daydo.web';
const APPLE_AUTH_URL = 'https://appleid.apple.com/auth/authorize';
const KNOWN_APPLE_SUB = 'apple-sub-known';

type Row = Record<string, unknown>;

let applePrivateKey: CryptoKey;
let appleJwks: KeySource;

beforeAll(async () => {
  const { publicKey, privateKey } = await generateKeyPair('RS256');
  const jwk = await exportJWK(publicKey);
  jwk.kid = 'apple-web-1';
  jwk.alg = 'RS256';
  applePrivateKey = privateKey;
  appleJwks = createLocalJWKSet({ keys: [jwk] });
});

function webConfig(): WebIdentityConfig {
  return {
    apple: { authUrl: APPLE_AUTH_URL, audience: APPLE_WEB_AUDIENCE, keySource: appleJwks },
    google: {
      clientId: 'google-web-client-id',
      clientSecret: undefined,
      authUrl: 'https://accounts.google.com/o/oauth2/v2/auth',
      tokenUrl: 'https://oauth2.googleapis.com/token',
    },
  };
}

function setup(clientName = 'Claude') {
  const { db, sqlite } = createTestD1();
  sqlite.prepare('INSERT INTO user (id, createdAt, name) VALUES (?, ?, ?)').run('user-1', 0, 'Alice');
  sqlite
    .prepare('INSERT INTO identity (provider, sub, userId, email) VALUES (?, ?, ?, ?)')
    .run('apple', KNOWN_APPLE_SUB, 'user-1', null);
  sqlite
    .prepare('INSERT INTO oauthClient (clientId, clientName, redirectUris, ipHash, createdAt) VALUES (?, ?, ?, ?, ?)')
    .run(CLIENT_ID, clientName, JSON.stringify([REDIRECT_URI, 'http://localhost:3334/callback']), 'ip', 0);
  const database = db as unknown as DatabaseClient;
  const deps = (now = NOW): AuthorizeDeps => ({ database, web: webConfig(), now });
  return { sqlite, database, deps };
}

type Setup = ReturnType<typeof setup>;

function count(sqlite: DatabaseSync, table: string): number {
  return (sqlite.prepare(`SELECT COUNT(*) AS n FROM ${table}`).get() as { n: number }).n;
}

function pendingRow(sqlite: DatabaseSync, id: string): Row {
  return sqlite.prepare('SELECT * FROM oauthPending WHERE id = ?').get(id) as Row;
}

/** `cookie` is a full `name=value` pair, as a browser would send it. */
function cookieHeader(pair: string): Record<string, string> {
  return { Cookie: `other=1; ${pair}` };
}

function bindCookieFrom(res: Response): string {
  const match = /(daydo_oauth_bind_[A-Za-z0-9_-]+=[^;]+)/.exec(res.headers.get('Set-Cookie') ?? '');
  if (!match) throw new Error('no bind cookie');
  return match[1];
}

function cookieValue(pair: string): string {
  return pair.slice(pair.indexOf('=') + 1);
}

/** Same cookie name as the flow's, someone else's value. */
function foreignCookie(pendingId: string): string {
  return `${bindCookieName(pendingId)}=someone-else`;
}

async function authorizeParams(overrides: Record<string, string | undefined> = {}) {
  const base: Record<string, string | undefined> = {
    response_type: 'code',
    client_id: CLIENT_ID,
    redirect_uri: REDIRECT_URI,
    scope: 'mcp offline_access',
    state: 'client-state-xyz',
    code_challenge: await sha256b64url(VERIFIER),
    code_challenge_method: 'S256',
    resource: `${ORIGIN}/`,
    ...overrides,
  };
  const params = new URLSearchParams();
  for (const [key, value] of Object.entries(base)) if (value !== undefined) params.set(key, value);
  return params;
}

async function startAuthorize(s: Setup, overrides: Record<string, string | undefined> = {}) {
  const res = await handleAuthorizeGet(
    new Request(`${ORIGIN}/authorize?${await authorizeParams(overrides)}`),
    s.deps(),
  );
  expect(res.status).toBe(200);
  const html = await res.text();
  const pendingId = /\/authorize\/start\?pending=([A-Za-z0-9_-]+)&amp;provider=apple/.exec(html)?.[1];
  if (!pendingId) throw new Error(`no start link in ${html}`);
  return { res, html, pendingId, cookie: bindCookieFrom(res) };
}

async function chooseApple(s: Setup, pendingId: string, cookie: string | null) {
  return handleAuthorizeStart(
    new Request(`${ORIGIN}/authorize/start?pending=${pendingId}&provider=apple`, {
      headers: cookie ? cookieHeader(cookie) : {},
    }),
    s.deps(),
  );
}

async function signAppleToken(claims: { sub: string; nonceHash: string; aud?: string }) {
  return new SignJWT({ nonce: claims.nonceHash })
    .setProtectedHeader({ alg: 'RS256', kid: 'apple-web-1' })
    .setIssuer('https://appleid.apple.com')
    .setAudience(claims.aud ?? APPLE_WEB_AUDIENCE)
    .setSubject(claims.sub)
    .setIssuedAt()
    .setExpirationTime('10m')
    .sign(applePrivateKey);
}

/** Runs GET /authorize and /authorize/start; returns what the Apple callback needs. */
async function toAppleCallback(s: Setup) {
  const started = await startAuthorize(s);
  const res = await chooseApple(s, started.pendingId, started.cookie);
  expect(res.status).toBe(302);
  const location = new URL(res.headers.get('Location') ?? '');
  return { ...started, nonceHash: location.searchParams.get('nonce') ?? '' };
}

async function appleCallback(s: Setup, form: Record<string, unknown>, cookie: string | null) {
  return handleAppleCallback(
    new Request(`${ORIGIN}/authorize/apple/callback`, {
      method: 'POST',
      headers: { Origin: 'https://appleid.apple.com', ...(cookie ? cookieHeader(cookie) : {}) },
    }),
    form,
    s.deps(),
  );
}

async function consentGet(s: Setup, pendingId: string, ct: string, cookie: string | null) {
  return handleAuthorizeGet(
    new Request(`${ORIGIN}/authorize?pending=${pendingId}&ct=${ct}`, { headers: cookie ? cookieHeader(cookie) : {} }),
    s.deps(),
  );
}

async function consentPost(s: Setup, form: Record<string, unknown>, cookie: string | null) {
  return handleAuthorizePost(
    new Request(`${ORIGIN}/authorize`, { method: 'POST', headers: cookie ? cookieHeader(cookie) : {} }),
    form,
    s.deps(),
  );
}

/** Full happy path up to the consent page; returns the consent token. */
async function toConsent(s: Setup) {
  const flow = await toAppleCallback(s);
  const idToken = await signAppleToken({ sub: KNOWN_APPLE_SUB, nonceHash: flow.nonceHash });
  const res = await appleCallback(s, { state: flow.pendingId, id_token: idToken, code: 'ignored' }, flow.cookie);
  expect(res.status).toBe(303);
  const location = new URL(res.headers.get('Location') ?? '', ORIGIN);
  expect(location.pathname).toBe('/authorize');
  expect(location.searchParams.get('pending')).toBe(flow.pendingId);
  return { ...flow, ct: location.searchParams.get('ct') ?? '' };
}

function expectHtmlSecurityHeaders(res: Response) {
  expect(res.headers.get('Content-Type')).toContain('text/html');
  expect(res.headers.get('Content-Security-Policy')).toContain("frame-ancestors 'none'");
  expect(res.headers.get('X-Frame-Options')).toBe('DENY');
  expect(res.headers.get('Cache-Control')).toBe('no-store');
  expect(res.headers.get('Access-Control-Allow-Origin')).toBeNull();
}

describe('GET /authorize parameter validation', () => {
  it('creates a pending row, sets the bind cookie and shows the provider buttons', async () => {
    const s = setup();
    const { res, html, pendingId, cookie } = await startAuthorize(s);
    expectHtmlSecurityHeaders(res);

    const setCookie = res.headers.get('Set-Cookie') ?? '';
    for (const attr of ['HttpOnly', 'Secure', 'SameSite=None', 'Path=/authorize']) expect(setCookie).toContain(attr);
    expect(html).toContain('Claude');

    const row = pendingRow(s.sqlite, pendingId);
    expect(row).toMatchObject({
      clientId: CLIENT_ID,
      redirectUri: REDIRECT_URI,
      codeChallenge: await sha256b64url(VERIFIER),
      scope: 'mcp offline_access',
      clientState: 'client-state-xyz',
      resource: `${ORIGIN}/`,
      bindHash: await sha256Hex(cookieValue(cookie)),
      provider: '',
      userId: null,
      consentTokenHash: null,
      createdAt: NOW,
      expiresAt: NOW + PENDING_TTL_MS,
      consumedAt: null,
    });
    expect(pendingId).toMatch(/^[A-Za-z0-9_-]{43}$/);
    expect(String(row.nonce)).toMatch(/^[A-Za-z0-9_-]{43}$/);
    expect(row.bindHash).not.toBe(cookieValue(cookie));
  });

  it('accepts a missing resource and a resource on the same origin without trailing slash', async () => {
    const s = setup();
    const omitted = await startAuthorize(s, { resource: undefined });
    expect(pendingRow(s.sqlite, omitted.pendingId).resource).toBeNull();
    const bare = await startAuthorize(s, { resource: ORIGIN });
    expect(pendingRow(s.sqlite, bare.pendingId).resource).toBe(ORIGIN);
  });

  it.each([
    ['response_type', { response_type: 'token' }],
    ['missing code_challenge', { code_challenge: undefined }],
    ['plain PKCE', { code_challenge_method: 'plain' }],
    ['scope without mcp', { scope: 'offline_access' }],
    ['unsupported scope', { scope: 'mcp admin' }],
    ['missing client_id', { client_id: undefined }],
    ['unregistered client', { client_id: 'mcp-unknown' }],
    ['redirect not registered', { redirect_uri: 'https://evil.example/callback' }],
    ['redirect prefix of a registered one', { redirect_uri: 'https://claude.ai/api/mcp/auth_callback/x' }],
    ['redirect with extra query', { redirect_uri: `${REDIRECT_URI}?x=1` }],
    ['resource on another origin', { resource: 'https://evil.example/' }],
    ['resource not a URL', { resource: 'not a url' }],
  ])('rejects %s with an error page, no redirect and no pending row', async (_label, overrides) => {
    const s = setup();
    const res = await handleAuthorizeGet(
      new Request(`${ORIGIN}/authorize?${await authorizeParams(overrides)}`),
      s.deps(),
    );
    expect(res.status).toBe(400);
    expect(res.headers.get('Location')).toBeNull();
    expect(res.headers.get('Set-Cookie')).toBeNull();
    expectHtmlSecurityHeaders(res);
    expect(count(s.sqlite, 'oauthPending')).toBe(0);
  });

  it('escapes the client name on the login page', async () => {
    const s = setup('<script>alert(1)</script>');
    const { html } = await startAuthorize(s);
    expect(html).not.toContain('<script>alert(1)</script>');
    expect(html).toContain(esc('<script>alert(1)</script>'));
  });
});

describe('GET /authorize/start', () => {
  it('records the provider and redirects to Apple with state and hashed nonce', async () => {
    const s = setup();
    const { pendingId, cookie } = await startAuthorize(s);
    const res = await chooseApple(s, pendingId, cookie);
    expect(res.status).toBe(302);
    const row = pendingRow(s.sqlite, pendingId);
    expect(row.provider).toBe('apple');

    const location = new URL(res.headers.get('Location') ?? '');
    expect(`${location.origin}${location.pathname}`).toBe(APPLE_AUTH_URL);
    expect(Object.fromEntries(location.searchParams)).toEqual({
      client_id: APPLE_WEB_AUDIENCE,
      redirect_uri: `${ORIGIN}/authorize/apple/callback`,
      response_type: 'code id_token',
      response_mode: 'form_post',
      state: pendingId,
      nonce: await sha256Hex(String(row.nonce)),
    });
    expect(res.headers.get('Location')).toBe(
      await appleAuthorizeUrl(webConfig().apple, { origin: ORIGIN, state: pendingId, rawNonce: String(row.nonce) }),
    );
  });

  it('refuses a browser without the bind cookie and does not record the provider', async () => {
    const s = setup();
    const { pendingId } = await startAuthorize(s);
    for (const cookie of [null, foreignCookie(pendingId)]) {
      const res = await chooseApple(s, pendingId, cookie);
      expect(res.status).toBe(400);
      expect(res.headers.get('Location')).toBeNull();
    }
    expect(pendingRow(s.sqlite, pendingId).provider).toBe('');
  });

  it('refuses unknown providers, an unconfigured Google and expired pendings', async () => {
    const s = setup();
    const { pendingId, cookie } = await startAuthorize(s);
    for (const provider of ['github', 'google']) {
      const res = await handleAuthorizeStart(
        new Request(`${ORIGIN}/authorize/start?pending=${pendingId}&provider=${provider}`, { headers: cookieHeader(cookie) }),
        s.deps(),
      );
      expect(res.status).toBe(400);
      expect(res.headers.get('Location')).toBeNull();
    }
    const expired = await handleAuthorizeStart(
      new Request(`${ORIGIN}/authorize/start?pending=${pendingId}&provider=apple`, { headers: cookieHeader(cookie) }),
      s.deps(NOW + PENDING_TTL_MS),
    );
    expect(expired.status).toBe(400);
    expect(pendingRow(s.sqlite, pendingId).provider).toBe('');
  });
});

describe('POST /authorize/apple/callback', () => {
  it('verifies a locally signed Apple token, binds the user and redirects to consent', async () => {
    const s = setup();
    const { pendingId, ct } = await toConsent(s);
    const row = pendingRow(s.sqlite, pendingId);
    expect(row.userId).toBe('user-1');
    expect(row.consentTokenHash).toBe(await sha256Hex(ct));
    expect(row.consumedAt).toBeNull();
  });

  it('shows an error for an unknown identity without creating a user or identity', async () => {
    const s = setup();
    const flow = await toAppleCallback(s);
    const users = count(s.sqlite, 'user');
    const identities = count(s.sqlite, 'identity');
    const idToken = await signAppleToken({ sub: 'apple-sub-stranger', nonceHash: flow.nonceHash });
    const res = await appleCallback(s, { state: flow.pendingId, id_token: idToken }, flow.cookie);
    expect(res.status).toBe(403);
    expectHtmlSecurityHeaders(res);
    expect(await res.text()).toContain('請先在 DayDo App 用同一個帳號登入一次');
    expect(count(s.sqlite, 'user')).toBe(users);
    expect(count(s.sqlite, 'identity')).toBe(identities);
    expect(count(s.sqlite, 'session')).toBe(0);
    expect(pendingRow(s.sqlite, flow.pendingId)).toMatchObject({ userId: null, consentTokenHash: null, consumedAt: null });
  });

  it('fails when the browser finishing sign-in is not the one that started (and ends the pending)', async () => {
    const s = setup();
    const flow = await toAppleCallback(s);
    const idToken = await signAppleToken({ sub: KNOWN_APPLE_SUB, nonceHash: flow.nonceHash });

    // The victim's browser has its own (or no) bind cookie.
    const victim = await appleCallback(s, { state: flow.pendingId, id_token: idToken }, foreignCookie(flow.pendingId));
    expect(victim.status).toBe(400);
    expect(victim.headers.get('Location')).toBeNull();
    const row = pendingRow(s.sqlite, flow.pendingId);
    expect(row.userId).toBeNull();
    expect(row.consumedAt).toBe(NOW);

    // The attacker's browser (correct cookie) cannot resume it afterwards.
    const attacker = await appleCallback(s, { state: flow.pendingId, id_token: idToken }, flow.cookie);
    expect(attacker.status).toBe(400);
    expect(pendingRow(s.sqlite, flow.pendingId).userId).toBeNull();
  });

  it('fails without any cookie', async () => {
    const s = setup();
    const flow = await toAppleCallback(s);
    const idToken = await signAppleToken({ sub: KNOWN_APPLE_SUB, nonceHash: flow.nonceHash });
    const res = await appleCallback(s, { state: flow.pendingId, id_token: idToken }, null);
    expect(res.status).toBe(400);
    expect(pendingRow(s.sqlite, flow.pendingId)).toMatchObject({ userId: null, consumedAt: NOW });
  });

  it('keeps the pending after a provider error so the user can retry', async () => {
    const s = setup();
    const flow = await toAppleCallback(s);
    const cancelled = await appleCallback(s, { state: flow.pendingId, error: 'user_cancelled_authorize' }, flow.cookie);
    expect(cancelled.status).toBe(400);
    expect(await cancelled.text()).toContain('已取消');
    expect(pendingRow(s.sqlite, flow.pendingId)).toMatchObject({ userId: null, consumedAt: null });

    const retry = await chooseApple(s, flow.pendingId, flow.cookie);
    expect(retry.status).toBe(302);
    const idToken = await signAppleToken({ sub: KNOWN_APPLE_SUB, nonceHash: flow.nonceHash });
    const res = await appleCallback(s, { state: flow.pendingId, id_token: idToken }, flow.cookie);
    expect(res.status).toBe(303);
    expect(pendingRow(s.sqlite, flow.pendingId).userId).toBe('user-1');
  });

  it('rejects a token with the wrong nonce or audience without binding', async () => {
    const s = setup();
    const flow = await toAppleCallback(s);
    for (const idToken of [
      await signAppleToken({ sub: KNOWN_APPLE_SUB, nonceHash: await sha256Hex('other-nonce') }),
      await signAppleToken({ sub: KNOWN_APPLE_SUB, nonceHash: flow.nonceHash, aud: 'com.audichuang.daydo' }),
    ]) {
      const res = await appleCallback(s, { state: flow.pendingId, id_token: idToken }, flow.cookie);
      expect(res.status).toBe(400);
      expect(pendingRow(s.sqlite, flow.pendingId)).toMatchObject({ userId: null, consumedAt: null });
    }
    // A missing or non-string id_token is a provider error too.
    for (const id_token of [undefined, new File(['x'], 'x.txt')]) {
      const res = await appleCallback(s, { state: flow.pendingId, id_token }, flow.cookie);
      expect(res.status).toBe(400);
    }
    expect(pendingRow(s.sqlite, flow.pendingId)).toMatchObject({ userId: null, consumedAt: null });
  });

  it('rejects a callback for a pending started with another provider, unknown state, or after expiry', async () => {
    const s = setup();
    const started = await startAuthorize(s);
    const idToken = await signAppleToken({ sub: KNOWN_APPLE_SUB, nonceHash: 'x' });
    // provider was never chosen ('' ≠ apple)
    const noProvider = await appleCallback(s, { state: started.pendingId, id_token: idToken }, started.cookie);
    expect(noProvider.status).toBe(400);
    const unknown = await appleCallback(s, { state: 'nope', id_token: idToken }, started.cookie);
    expect(unknown.status).toBe(400);

    const flow = await toAppleCallback(s);
    const fresh = await signAppleToken({ sub: KNOWN_APPLE_SUB, nonceHash: flow.nonceHash });
    const expired = await handleAppleCallback(
      new Request(`${ORIGIN}/authorize/apple/callback`, { method: 'POST', headers: cookieHeader(flow.cookie) }),
      { state: flow.pendingId, id_token: fresh },
      s.deps(NOW + PENDING_TTL_MS),
    );
    expect(expired.status).toBe(400);
    expect(pendingRow(s.sqlite, flow.pendingId).userId).toBeNull();
  });

  it('two concurrent callbacks bind the pending exactly once', async () => {
    const s = setup();
    const flow = await toAppleCallback(s);
    const idToken = await signAppleToken({ sub: KNOWN_APPLE_SUB, nonceHash: flow.nonceHash });
    const results = await Promise.all([
      appleCallback(s, { state: flow.pendingId, id_token: idToken }, flow.cookie),
      appleCallback(s, { state: flow.pendingId, id_token: idToken }, flow.cookie),
    ]);
    expect(results.map((r) => r.status).sort()).toEqual([303, 400]);
    const winner = results.find((r) => r.status === 303);
    const ct = new URL(winner?.headers.get('Location') ?? '', ORIGIN).searchParams.get('ct') ?? '';
    expect(pendingRow(s.sqlite, flow.pendingId).consentTokenHash).toBe(await sha256Hex(ct));
  });

  it('cannot bind the same pending twice', async () => {
    const s = setup();
    const flow = await toConsent(s);
    const idToken = await signAppleToken({ sub: KNOWN_APPLE_SUB, nonceHash: flow.nonceHash });
    const again = await appleCallback(s, { state: flow.pendingId, id_token: idToken }, flow.cookie);
    expect(again.status).toBe(400);
    expect(pendingRow(s.sqlite, flow.pendingId).consentTokenHash).toBe(await sha256Hex(flow.ct));
  });
});

describe('consent page and POST /authorize', () => {
  it('shows the user, client and redirect host with anti-framing and no-store headers', async () => {
    const s = setup();
    const { pendingId, ct, cookie } = await toConsent(s);
    const res = await consentGet(s, pendingId, ct, cookie);
    expect(res.status).toBe(200);
    expectHtmlSecurityHeaders(res);
    const html = await res.text();
    expect(html).toContain('Alice');
    expect(html).toContain('Claude');
    expect(html).toContain('claude.ai');
    expect(html).toContain('method="post"');
  });

  it('refuses the consent page when the cookie or consent token does not match', async () => {
    const s = setup();
    const { pendingId, ct } = await toConsent(s);
    expect((await consentGet(s, pendingId, ct, 'other-browser')).status).toBe(400);
    expect((await consentGet(s, pendingId, ct, null)).status).toBe(400);

    const s2 = setup();
    const flow2 = await toConsent(s2);
    expect((await consentGet(s2, flow2.pendingId, 'wrong-ct', flow2.cookie)).status).toBe(400);
    expect((await consentGet(s2, flow2.pendingId, ct, flow2.cookie)).status).toBe(400);
    expect(pendingRow(s2.sqlite, flow2.pendingId).consumedAt).toBeNull();
  });

  it('refuses the consent page before sign-in has bound a user', async () => {
    const s = setup();
    const { pendingId, cookie } = await startAuthorize(s);
    expect((await consentGet(s, pendingId, 'anything', cookie)).status).toBe(400);
  });

  it('approves once: issues a code bound to the user that /token accepts', async () => {
    const s = setup();
    const { pendingId, ct, cookie } = await toConsent(s);
    const res = await consentPost(s, { pending: pendingId, ct, decision: 'approve' }, cookie);
    expect(res.status).toBe(302);
    const location = new URL(res.headers.get('Location') ?? '');
    expect(`${location.origin}${location.pathname}`).toBe(REDIRECT_URI);
    expect(location.searchParams.get('state')).toBe('client-state-xyz');
    const code = location.searchParams.get('code') ?? '';
    expect(code).toMatch(/^[A-Za-z0-9_-]{43}$/);
    expect(pendingRow(s.sqlite, pendingId).consumedAt).toBe(NOW);

    const codeRow = s.sqlite.prepare('SELECT * FROM oauthCode').get() as Row;
    expect(codeRow).toMatchObject({
      codeHash: await sha256Hex(code),
      clientId: CLIENT_ID,
      redirectUri: REDIRECT_URI,
      scope: 'mcp offline_access',
      resource: `${ORIGIN}/`,
      userId: 'user-1',
    });

    const tokenRes = await handleToken(
      new Request(`${ORIGIN}/token`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: new URLSearchParams({
          grant_type: 'authorization_code',
          code,
          code_verifier: VERIFIER,
          client_id: CLIENT_ID,
          redirect_uri: REDIRECT_URI,
        }).toString(),
      }),
      { database: s.database, secret: 'unit-test-jwt-secret-32-bytes-minimum', now: NOW },
    );
    expect(tokenRes.status).toBe(200);

    // The pending can only be consumed once.
    const replay = await consentPost(s, { pending: pendingId, ct, decision: 'approve' }, cookie);
    expect(replay.status).toBe(400);
    expect(replay.headers.get('Location')).toBeNull();
    expect(count(s.sqlite, 'oauthCode')).toBe(1);
  });

  it('two concurrent approvals produce exactly one code', async () => {
    const s = setup();
    const { pendingId, ct, cookie } = await toConsent(s);
    const results = await Promise.all([
      consentPost(s, { pending: pendingId, ct, decision: 'approve' }, cookie),
      consentPost(s, { pending: pendingId, ct, decision: 'approve' }, cookie),
    ]);
    expect(results.map((r) => r.status).sort()).toEqual([302, 400]);
    expect(count(s.sqlite, 'oauthCode')).toBe(1);
  });

  it('deny redirects with access_denied and consumes the pending without a code', async () => {
    const s = setup();
    const { pendingId, ct, cookie } = await toConsent(s);
    const res = await consentPost(s, { pending: pendingId, ct, decision: 'deny' }, cookie);
    expect(res.status).toBe(302);
    const location = new URL(res.headers.get('Location') ?? '');
    expect(location.searchParams.get('error')).toBe('access_denied');
    expect(location.searchParams.get('state')).toBe('client-state-xyz');
    expect(location.searchParams.get('code')).toBeNull();
    expect(count(s.sqlite, 'oauthCode')).toBe(0);
    expect(pendingRow(s.sqlite, pendingId).consumedAt).toBe(NOW);
  });

  it('refuses POST when the cookie or consent token does not match, without consuming', async () => {
    const s = setup();
    const { pendingId, ct, cookie } = await toConsent(s);
    for (const [form, c] of [
      [{ pending: pendingId, ct, decision: 'approve' }, 'other-browser'],
      [{ pending: pendingId, ct, decision: 'approve' }, null],
      [{ pending: pendingId, ct: 'wrong', decision: 'approve' }, cookie],
      [{ pending: pendingId, ct, decision: 'maybe' }, cookie],
    ] as const) {
      const res = await consentPost(s, form, c);
      expect(res.status).toBe(400);
      expect(res.headers.get('Location')).toBeNull();
    }
    expect(count(s.sqlite, 'oauthCode')).toBe(0);
    expect(pendingRow(s.sqlite, pendingId).consumedAt).toBeNull();

    const ok = await consentPost(s, { pending: pendingId, ct, decision: 'approve' }, cookie);
    expect(ok.status).toBe(302);
  });

  it('refuses POST after the pending expires', async () => {
    const s = setup();
    const { pendingId, ct, cookie } = await toConsent(s);
    const res = await handleAuthorizePost(
      new Request(`${ORIGIN}/authorize`, { method: 'POST', headers: cookieHeader(cookie) }),
      { pending: pendingId, ct, decision: 'approve' },
      s.deps(NOW + PENDING_TTL_MS),
    );
    expect(res.status).toBe(400);
    expect(count(s.sqlite, 'oauthCode')).toBe(0);
  });
});

describe('two authorize flows in one browser', () => {
  it('both complete, because each pending has its own bind cookie', async () => {
    const s = setup();
    const first = await startAuthorize(s);
    const second = await startAuthorize(s, { state: 'second-state' });
    expect(bindCookieName(first.pendingId)).not.toBe(bindCookieName(second.pendingId));
    const jar = `${first.cookie}; ${second.cookie}`;

    const flows = [first, second];
    const cts: string[] = [];
    for (const flow of flows) {
      const start = await handleAuthorizeStart(
        new Request(`${ORIGIN}/authorize/start?pending=${flow.pendingId}&provider=apple`, { headers: { Cookie: jar } }),
        s.deps(),
      );
      expect(start.status).toBe(302);
      const nonceHash = new URL(start.headers.get('Location') ?? '').searchParams.get('nonce') ?? '';
      const idToken = await signAppleToken({ sub: KNOWN_APPLE_SUB, nonceHash });
      const callback = await handleAppleCallback(
        new Request(`${ORIGIN}/authorize/apple/callback`, {
          method: 'POST',
          headers: { Origin: 'https://appleid.apple.com', Cookie: jar },
        }),
        { state: flow.pendingId, id_token: idToken },
        s.deps(),
      );
      expect(callback.status).toBe(303);
      cts.push(new URL(callback.headers.get('Location') ?? '', ORIGIN).searchParams.get('ct') ?? '');
    }

    for (const [index, flow] of flows.entries()) {
      const res = await handleAuthorizePost(
        new Request(`${ORIGIN}/authorize`, { method: 'POST', headers: { Cookie: jar } }),
        { pending: flow.pendingId, ct: cts[index], decision: 'approve' },
        s.deps(),
      );
      expect(res.status).toBe(302);
    }
    expect(count(s.sqlite, 'oauthCode')).toBe(2);
  });

  it('a cookie of one flow does not open another', async () => {
    const s = setup();
    const first = await startAuthorize(s);
    const second = await startAuthorize(s);
    const res = await chooseApple(s, first.pendingId, second.cookie);
    expect(res.status).toBe(400);
  });
});

describe('GET /authorize rate limit (spec/mcp.md 4.4)', () => {
  async function begin(s: Setup, ip: string | null, now: number) {
    const headers: Record<string, string> = ip ? { 'CF-Connecting-IP': ip } : {};
    return handleAuthorizeGet(new Request(`${ORIGIN}/authorize?${await authorizeParams()}`, { headers }), s.deps(now));
  }

  it('allows 30 pending rows per IP per hour, then shows a 429 page without inserting', async () => {
    const s = setup();
    expect(AUTHORIZE_LIMIT_PER_HOUR).toBe(30);
    for (let i = 0; i < 30; i++) expect((await begin(s, '198.51.100.9', NOW + i)).status).toBe(200);
    expect(count(s.sqlite, 'oauthPending')).toBe(30);

    const limited = await begin(s, '198.51.100.9', NOW + 30);
    expect(limited.status).toBe(429);
    expect(limited.headers.get('Set-Cookie')).toBeNull();
    expect(count(s.sqlite, 'oauthPending')).toBe(30);

    expect((await begin(s, '198.51.100.10', NOW + 31)).status).toBe(200);
    expect((await begin(s, '198.51.100.9', NOW + 3_600_000 - 1)).status).toBe(429);
    expect((await begin(s, '198.51.100.9', NOW + 3_600_000)).status).toBe(200);
    expect(count(s.sqlite, 'oauthPending')).toBe(32);
  });

  it('stores the authorize-scoped hash, keys IPv6 by /64 and uses local without the header', async () => {
    const s = setup();
    for (let i = 0; i < 30; i++) expect((await begin(s, `2001:db8:5:6::${(i + 1).toString(16)}`, NOW + i)).status).toBe(200);
    expect((await begin(s, '2001:db8:5:6:aaaa::1', NOW + 30)).status).toBe(429);
    expect((await begin(s, '2001:db8:5:7::1', NOW + 31)).status).toBe(200);
    expect((await begin(s, null, NOW + 32)).status).toBe(200);

    const hashes = (s.sqlite.prepare('SELECT DISTINCT ipHash FROM oauthPending ORDER BY createdAt').all() as Row[]).map(
      (r) => r.ipHash,
    );
    expect(hashes).toEqual([
      await sha256Hex('authorize|2001:db8:5:6::/64'),
      await sha256Hex('authorize|2001:db8:5:7::/64'),
      await sha256Hex('authorize|local'),
    ]);
  });
});
