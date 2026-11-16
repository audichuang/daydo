import type { DatabaseSync } from 'node:sqlite';
import { createLocalJWKSet, exportJWK, generateKeyPair, SignJWT, type CryptoKey } from 'jose';
import { beforeAll, describe, expect, it } from 'vitest';
import type { KeySource } from '../src/auth/providers';
import type { DatabaseClient } from '../src/auth/session';
import {
  bindCookieName,
  handleAuthorizeGet,
  handleAuthorizeStart,
  type AuthorizeDeps,
} from '../src/oauth/authorize';
import { handleGoogleCallback } from '../src/oauth/googleCallback';
import type { WebIdentityConfig } from '../src/oauth/webIdentity';
import { createTestD1 } from './sqliteD1';

const ORIGIN = 'https://daydo-mcp.audichuang.app';
const NOW = 1_800_000_000_000;
const CLIENT_ID = 'mcp-client-a';
const REDIRECT_URI = 'https://claude.ai/api/mcp/auth_callback';
const GOOGLE_CLIENT_ID = 'google-web-client-id';
const GOOGLE_SECRET = 'google-secret';
const KNOWN_SUB = 'google-sub-known';

let privateKey: CryptoKey;
let jwks: KeySource;

beforeAll(async () => {
  const pair = await generateKeyPair('RS256');
  const jwk = await exportJWK(pair.publicKey);
  jwk.kid = 'google-web-1';
  jwk.alg = 'RS256';
  privateKey = pair.privateKey;
  jwks = createLocalJWKSet({ keys: [jwk] });
});

function webConfig(clientSecret: string | undefined): WebIdentityConfig {
  return {
    apple: { authUrl: 'https://appleid.apple.com/auth/authorize', audience: 'com.audichuang.daydo.web' },
    google: {
      clientId: GOOGLE_CLIENT_ID,
      clientSecret,
      authUrl: 'https://accounts.google.com/o/oauth2/v2/auth',
      tokenUrl: 'https://oauth2.googleapis.com/token',
      keySource: jwks,
    },
  };
}

function setup(clientSecret?: string) {
  const { db, sqlite } = createTestD1();
  sqlite.prepare('INSERT INTO user (id, createdAt, name) VALUES (?, ?, ?)').run('user-1', 0, 'Alice');
  sqlite
    .prepare('INSERT INTO identity (provider, sub, userId, email) VALUES (?, ?, ?, ?)')
    .run('google', KNOWN_SUB, 'user-1', null);
  sqlite
    .prepare('INSERT INTO oauthClient (clientId, clientName, redirectUris, ipHash, createdAt) VALUES (?, ?, ?, ?, ?)')
    .run(CLIENT_ID, 'Claude', JSON.stringify([REDIRECT_URI]), 'ip', 0);
  const database = db as unknown as DatabaseClient;
  const secret = arguments.length === 0 ? GOOGLE_SECRET : clientSecret;
  const deps: AuthorizeDeps = { database, web: webConfig(secret), now: NOW };
  return { sqlite, deps };
}

type Setup = ReturnType<typeof setup>;

function pendingRow(sqlite: DatabaseSync, id: string) {
  return sqlite.prepare('SELECT * FROM oauthPending WHERE id = ?').get(id) as Record<string, unknown>;
}

/** Runs GET /authorize and /authorize/start with Google; returns what the callback needs. */
async function toGoogleCallback(s: Setup) {
  const params = new URLSearchParams({
    response_type: 'code',
    client_id: CLIENT_ID,
    redirect_uri: REDIRECT_URI,
    scope: 'mcp',
    state: 'client-state',
    code_challenge: 'x'.repeat(43),
    code_challenge_method: 'S256',
  });
  const page = await handleAuthorizeGet(new Request(`${ORIGIN}/authorize?${params}`), s.deps);
  const html = await page.text();
  const pendingId = /\/authorize\/start\?pending=([A-Za-z0-9_-]+)&amp;provider=google/.exec(html)?.[1];
  if (!pendingId) throw new Error(`no google link in ${html}`);
  const cookie = /(daydo_oauth_bind_[A-Za-z0-9_-]+=[^;]+)/.exec(page.headers.get('Set-Cookie') ?? '')?.[1] ?? '';
  const res = await handleAuthorizeStart(
    new Request(`${ORIGIN}/authorize/start?pending=${pendingId}&provider=google`, {
      headers: { Cookie: cookie },
    }),
    s.deps,
  );
  expect(res.status).toBe(302);
  const location = new URL(res.headers.get('Location') ?? '');
  return { pendingId, cookie, location, nonce: location.searchParams.get('nonce') ?? '' };
}

async function signGoogleToken(claims: { sub: string; nonce: string; aud?: string }) {
  return new SignJWT({ nonce: claims.nonce })
    .setProtectedHeader({ alg: 'RS256', kid: 'google-web-1' })
    .setIssuer('https://accounts.google.com')
    .setAudience(claims.aud ?? GOOGLE_CLIENT_ID)
    .setSubject(claims.sub)
    .setIssuedAt()
    .setExpirationTime('10m')
    .sign(privateKey);
}

interface TokenCall {
  url: string;
  body: URLSearchParams;
}

function tokenEndpoint(idToken: string | null, calls: TokenCall[] = []): typeof fetch {
  return (async (input: RequestInfo | URL, init?: RequestInit) => {
    calls.push({ url: String(input), body: new URLSearchParams(String(init?.body)) });
    if (idToken === null) return new Response('{"error":"invalid_grant"}', { status: 400 });
    return Response.json({ access_token: 'unused', id_token: idToken });
  }) as typeof fetch;
}

function callbackRequest(query: Record<string, string>, cookie: string | null) {
  return new Request(`${ORIGIN}/authorize/google/callback?${new URLSearchParams(query)}`, {
    headers: cookie ? { Cookie: cookie } : {},
  });
}

describe('Google web sign-in', () => {
  it('sends the authorize URL with state, raw nonce and select_account', async () => {
    const s = setup();
    const flow = await toGoogleCallback(s);
    const q = flow.location.searchParams;
    expect(flow.location.origin + flow.location.pathname).toBe('https://accounts.google.com/o/oauth2/v2/auth');
    expect(Object.fromEntries(q)).toEqual({
      client_id: GOOGLE_CLIENT_ID,
      redirect_uri: `${ORIGIN}/authorize/google/callback`,
      response_type: 'code',
      scope: 'openid email profile',
      state: flow.pendingId,
      nonce: String(pendingRow(s.sqlite, flow.pendingId).nonce),
      prompt: 'select_account',
    });
  });

  it('shows the Google button as unconfigured without a client secret', async () => {
    const s = setup(undefined);
    const params = new URLSearchParams({
      response_type: 'code',
      client_id: CLIENT_ID,
      redirect_uri: REDIRECT_URI,
      code_challenge: 'x'.repeat(43),
      code_challenge_method: 'S256',
    });
    const html = await (await handleAuthorizeGet(new Request(`${ORIGIN}/authorize?${params}`), s.deps)).text();
    expect(html).not.toContain('provider=google');
    expect(html).toContain('使用 Google 繼續');
  });

  it('exchanges the code with the client secret, verifies the token and binds the user', async () => {
    const s = setup();
    const flow = await toGoogleCallback(s);
    const calls: TokenCall[] = [];
    const idToken = await signGoogleToken({ sub: KNOWN_SUB, nonce: flow.nonce });
    const res = await handleGoogleCallback(
      callbackRequest({ state: flow.pendingId, code: 'auth-code' }, flow.cookie),
      s.deps,
      tokenEndpoint(idToken, calls),
    );
    expect(res.status).toBe(303);
    expect(res.headers.get('Location')).toContain(`/authorize?pending=${flow.pendingId}&ct=`);
    expect(calls).toHaveLength(1);
    expect(calls[0]?.url).toBe('https://oauth2.googleapis.com/token');
    expect(Object.fromEntries(calls[0]?.body ?? [])).toEqual({
      grant_type: 'authorization_code',
      code: 'auth-code',
      client_id: GOOGLE_CLIENT_ID,
      client_secret: GOOGLE_SECRET,
      redirect_uri: `${ORIGIN}/authorize/google/callback`,
    });
    expect(pendingRow(s.sqlite, flow.pendingId).userId).toBe('user-1');
  });

  it('rejects a wrong nonce or audience without binding, keeping the pending', async () => {
    const s = setup();
    const flow = await toGoogleCallback(s);
    for (const idToken of [
      await signGoogleToken({ sub: KNOWN_SUB, nonce: 'other-nonce' }),
      await signGoogleToken({ sub: KNOWN_SUB, nonce: flow.nonce, aud: 'ios-client-id' }),
    ]) {
      const res = await handleGoogleCallback(
        callbackRequest({ state: flow.pendingId, code: 'c' }, flow.cookie),
        s.deps,
        tokenEndpoint(idToken),
      );
      expect(res.status).toBe(400);
      expect(res.headers.get('Location')).toBeNull();
    }
    const row = pendingRow(s.sqlite, flow.pendingId);
    expect(row.userId).toBeNull();
    expect(row.consumedAt).toBeNull();
  });

  it('shows a retryable error when Google refuses the code', async () => {
    const s = setup();
    const flow = await toGoogleCallback(s);
    const res = await handleGoogleCallback(
      callbackRequest({ state: flow.pendingId, code: 'bad' }, flow.cookie),
      s.deps,
      tokenEndpoint(null),
    );
    expect(res.status).toBe(400);
    expect(pendingRow(s.sqlite, flow.pendingId).consumedAt).toBeNull();
  });

  it('ends the pending when the cookie does not match, without calling Google', async () => {
    const s = setup();
    const flow = await toGoogleCallback(s);
    const calls: TokenCall[] = [];
    const idToken = await signGoogleToken({ sub: KNOWN_SUB, nonce: flow.nonce });
    for (const cookie of [`${bindCookieName(flow.pendingId)}=victim-cookie`, null]) {
      const res = await handleGoogleCallback(
        callbackRequest({ state: flow.pendingId, code: 'c' }, cookie),
        s.deps,
        tokenEndpoint(idToken, calls),
      );
      expect(res.status).toBe(400);
    }
    expect(calls).toHaveLength(0);
    const row = pendingRow(s.sqlite, flow.pendingId);
    expect(row.consumedAt).not.toBeNull();
    expect(row.userId).toBeNull();
  });

  it('keeps the pending after access_denied so the user can retry', async () => {
    const s = setup();
    const flow = await toGoogleCallback(s);
    const calls: TokenCall[] = [];
    const res = await handleGoogleCallback(
      callbackRequest({ state: flow.pendingId, error: 'access_denied' }, flow.cookie),
      s.deps,
      tokenEndpoint(null, calls),
    );
    expect(res.status).toBe(400);
    expect(calls).toHaveLength(0);
    expect(pendingRow(s.sqlite, flow.pendingId).consumedAt).toBeNull();

    const retry = await handleAuthorizeStart(
      new Request(`${ORIGIN}/authorize/start?pending=${flow.pendingId}&provider=google`, {
        headers: { Cookie: flow.cookie },
      }),
      s.deps,
    );
    expect(retry.status).toBe(302);
  });

  it('shows an error for an unknown Google account without creating anything', async () => {
    const s = setup();
    const flow = await toGoogleCallback(s);
    const idToken = await signGoogleToken({ sub: 'google-sub-stranger', nonce: flow.nonce });
    const res = await handleGoogleCallback(
      callbackRequest({ state: flow.pendingId, code: 'c' }, flow.cookie),
      s.deps,
      tokenEndpoint(idToken),
    );
    expect(res.status).toBe(403);
    expect(pendingRow(s.sqlite, flow.pendingId).userId).toBeNull();
    expect(s.sqlite.prepare('SELECT COUNT(*) AS n FROM user').get()).toEqual({ n: 1 });
  });
});
