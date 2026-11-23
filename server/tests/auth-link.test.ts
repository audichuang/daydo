import { createLocalJWKSet, exportJWK, generateKeyPair, SignJWT } from 'jose';
import { drizzle } from 'drizzle-orm/d1';
import type { CloudContext } from 'void';
import { afterEach, describe, expect, it, vi } from 'vitest';
import * as schema from '../db/schema';
import { sha256Hex, signAccessToken } from '../src/auth/crypto';
import {
  EMAIL_CODE_MAX_ATTEMPTS,
  EMAIL_CODE_TTL_MS,
  EMAIL_LOCKOUT_FAILURES,
  startEmailCode,
} from '../src/auth/email';
import {
  handleAuthLink,
  linkIdentity,
  listUserIdentities,
} from '../src/auth/identities';
import { createSessionForIdentity, type DatabaseClient } from '../src/auth/session';
import type { MailMessage, Mailer } from '../src/mail/mailer';
import { signMcpAccessToken } from '../src/oauth/tokens';
import { createTestD1 } from './sqliteD1';

const TEST_JWT_SECRET = 'link-test-jwt-secret-must-be-at-least-32-bytes';
const APPLE_AUD = 'com.audichuang.daydo';
const GOOGLE_AUD = 'google-ios-client-id';
const NOW = Date.UTC(2027, 1, 10, 12, 0, 0);
const IP = '203.0.113.42';

let activeD1: D1Database | null = null;

vi.mock('void', () => ({
  defineHandler: (handler: unknown) => handler,
  defineMiddleware: (mw: unknown) => mw,
}));

vi.mock('void/db', async () => {
  const orm = await import('drizzle-orm');
  return {
    ...orm,
    createDb: (d1: D1Database) => drizzle(d1 ?? activeD1!, { schema }),
  };
});

vi.mock('void/env', () => ({
  env: {
    JWT_SECRET: TEST_JWT_SECRET,
    APPLE_AUDIENCE: APPLE_AUD,
    APPLE_JWKS_URL: 'https://appleid.apple.com/auth/keys',
    GOOGLE_AUDIENCE: GOOGLE_AUD,
    GOOGLE_JWKS_URL: 'https://www.googleapis.com/oauth2/v3/certs',
  },
}));

const { POST: postLinkRoute } = await import('../routes/auth/link');
const { GET: getIdentitiesRoute } = await import('../routes/me/identities');
const callPostLink = postLinkRoute as unknown as (c: CloudContext) => Promise<Response>;
const callGetIdentities = getIdentitiesRoute as unknown as (c: CloudContext) => Promise<Response>;

afterEach(() => vi.restoreAllMocks());

async function makeKeyFixture(alg: 'RS256' | 'ES256', kid: string) {
  const { publicKey, privateKey } = await generateKeyPair(alg);
  const jwk = await exportJWK(publicKey);
  jwk.kid = kid;
  jwk.alg = alg;
  jwk.use = 'sig';
  return {
    privateKey,
    jwks: createLocalJWKSet({ keys: [jwk] }),
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
    lastCode(): string {
      const last = sent.at(-1);
      if (!last) throw new Error('no mail sent');
      const code = /\b(\d{6})\b/.exec(last.text)?.[1];
      if (!code) throw new Error('no code in mail');
      return code;
    },
  };
}

function makeRouteContext(params: {
  d1: D1Database;
  authorization?: string;
  jsonBody?: unknown;
  rawBody?: string;
}): CloudContext {
  const vars = new Map<string, unknown>();
  const headers = new Map<string, string>();
  if (params.authorization !== undefined) {
    headers.set('authorization', params.authorization);
  }
  return {
    env: { DB: params.d1 },
    req: {
      header: (name?: string) => (name ? headers.get(name.toLowerCase()) : undefined),
      json: async () => {
        if (params.rawBody !== undefined) {
          return JSON.parse(params.rawBody);
        }
        return params.jsonBody;
      },
    },
    set: (key: string, value: unknown) => {
      vars.set(key, value);
    },
    get: (key: string) => vars.get(key),
    json: (body: unknown, status = 200) =>
      new Response(JSON.stringify(body), {
        status,
        headers: { 'Content-Type': 'application/json' },
      }),
  } as unknown as CloudContext;
}

describe('GET /me/identities route', () => {
  it('rejects unauthenticated requests, bad JWTs, and MCP access tokens with 401', async () => {
    const { d1 } = createTestD1();
    activeD1 = d1;

    const noAuth = await callGetIdentities(makeRouteContext({ d1 }));
    expect(noAuth.status).toBe(401);
    expect(await noAuth.json()).toEqual({ error: 'Unauthorized' });

    const badJwt = await callGetIdentities(makeRouteContext({ d1, authorization: 'Bearer invalid' }));
    expect(badJwt.status).toBe(401);

    const mcpToken = await signMcpAccessToken(TEST_JWT_SECRET, {
      origin: 'https://mcp.daydoapp.com',
      userId: 'user-1',
      scope: 'mcp',
      clientId: 'mcp-client',
    });
    const mcpRes = await callGetIdentities(makeRouteContext({ d1, authorization: `Bearer ${mcpToken}` }));
    expect(mcpRes.status).toBe(401);
  });

  it('returns caller identities only, preserves Apple relay email, omits null email, and falls back to user.createdAt for legacy rows', async () => {
    const { d1, db, sqlite } = createTestD1();
    activeD1 = d1;
    const database = db as unknown as DatabaseClient;

    const alice = await createSessionForIdentity(database, {
      provider: 'apple',
      sub: 'apple-alice',
      email: 'hidden@privaterelay.appleid.com',
      deviceId: 'dev-a',
      jwtSecret: TEST_JWT_SECRET,
      now: NOW,
    });
    const bob = await createSessionForIdentity(database, {
      provider: 'google',
      sub: 'google-bob',
      email: 'bob@gmail.com',
      deviceId: 'dev-b',
      jwtSecret: TEST_JWT_SECRET,
      now: NOW + 100,
    });

    // Simulate a pre-migration row with NULL createdAt and NULL email on Alice.
    sqlite
      .prepare('INSERT INTO identity (provider, sub, userId, email, createdAt) VALUES (?, ?, ?, ?, ?)')
      .run('google', 'google-legacy', alice.user.id, null, null);

    const res = await callGetIdentities(
      makeRouteContext({ d1, authorization: `Bearer ${alice.accessToken}` }),
    );
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual([
      { provider: 'apple', email: 'hidden@privaterelay.appleid.com', createdAt: NOW },
      { provider: 'google', createdAt: NOW },
    ]);

    // Bob sees only his own identity.
    const bobRes = await callGetIdentities(
      makeRouteContext({ d1, authorization: `Bearer ${bob.accessToken}` }),
    );
    expect(bobRes.status).toBe(200);
    expect(await bobRes.json()).toEqual([
      { provider: 'google', email: 'bob@gmail.com', createdAt: NOW + 100 },
    ]);

    // Deleted/unknown user returns 404.
    const ghostToken = await signAccessToken('ghost-user', TEST_JWT_SECRET);
    const ghostRes = await callGetIdentities(
      makeRouteContext({ d1, authorization: `Bearer ${ghostToken}` }),
    );
    expect(ghostRes.status).toBe(404);
  });
});

describe('POST /auth/link route auth boundary', () => {
  it('returns 401 and writes no identity when access token is missing or invalid', async () => {
    const { d1, sqlite } = createTestD1();
    activeD1 = d1;

    const res = await callPostLink(
      makeRouteContext({
        d1,
        jsonBody: { provider: 'google', idToken: 'anything' },
      }),
    );
    expect(res.status).toBe(401);
    expect(await res.json()).toEqual({ error: 'Unauthorized' });
    expect(sqlite.prepare('SELECT COUNT(*) AS n FROM identity').get()).toEqual({ n: 0 });

    const badTokenRes = await callPostLink(
      makeRouteContext({
        d1,
        authorization: 'Bearer bad-token',
        jsonBody: { provider: 'email', email: 'a@example.com', code: '123456' },
      }),
    );
    expect(badTokenRes.status).toBe(401);
    expect(sqlite.prepare('SELECT COUNT(*) AS n FROM identity').get()).toEqual({ n: 0 });
  });
});

describe('handleAuthLink', () => {
  it('rejects malformed bodies and missing fields with 400 without writing any identity', async () => {
    const { db, sqlite } = createTestD1();
    const database = db as unknown as DatabaseClient;
    const apple = await makeKeyFixture('RS256', 'a-400');
    const google = await makeKeyFixture('RS256', 'g-400');

    const user = await createSessionForIdentity(database, {
      provider: 'apple',
      sub: 'apple-400',
      email: 'a@privaterelay.appleid.com',
      deviceId: 'dev-1',
      jwtSecret: TEST_JWT_SECRET,
      now: NOW,
    });

    const badBodies: Array<Record<string, unknown> | null> = [
      null,
      {},
      { provider: 'github' },
      { provider: 'apple', identityToken: 't' },
      { provider: 'apple', nonce: 'n' },
      { provider: 'google' },
      { provider: 'google', idToken: '' },
      { provider: 'email', email: 'bad', code: '123456' },
      { provider: 'email', email: 'a@example.com' },
    ];

    for (const body of badBodies) {
      const res = await handleAuthLink(database, {
        userId: user.user.id,
        body,
        appleAudience: APPLE_AUD,
        appleKeySource: apple.jwks,
        googleAudience: GOOGLE_AUD,
        googleKeySource: google.jwks,
        now: NOW,
      });
      expect(res.status, JSON.stringify(body)).toBe(400);
    }

    expect(sqlite.prepare('SELECT COUNT(*) AS n FROM identity').get()).toEqual({ n: 1 });
  });

  it('links Google and Email to an Apple account, returns full identity list, and lets all providers sign into the same userId', async () => {
    const { db } = createTestD1();
    const database = db as unknown as DatabaseClient;
    vi.spyOn(console, 'log').mockImplementation(() => {});
    const google = await makeKeyFixture('RS256', 'g-link-1');
    const mail = fakeMailer();

    const initial = await createSessionForIdentity(database, {
      provider: 'apple',
      sub: 'apple-sub-main',
      email: 'relay@privaterelay.appleid.com',
      deviceId: 'dev-iphone',
      jwtSecret: TEST_JWT_SECRET,
      now: NOW,
    });

    const googleToken = await new SignJWT({ email: 'me@gmail.com' })
      .setProtectedHeader({ alg: 'RS256', kid: 'g-link-1' })
      .setIssuer('https://accounts.google.com')
      .setAudience(GOOGLE_AUD)
      .setSubject('google-sub-main')
      .setIssuedAt(Math.floor(NOW / 1000))
      .setExpirationTime(Math.floor(NOW / 1000) + 600)
      .sign(google.privateKey);

    const afterGoogle = await handleAuthLink(database, {
      userId: initial.user.id,
      body: { provider: 'google', idToken: googleToken },
      appleAudience: APPLE_AUD,
      googleAudience: GOOGLE_AUD,
      googleKeySource: google.jwks,
      now: NOW + 1000,
    });
    expect(afterGoogle).toEqual({
      status: 200,
      body: [
        { provider: 'apple', email: 'relay@privaterelay.appleid.com', createdAt: NOW },
        { provider: 'google', email: 'me@gmail.com', createdAt: NOW + 1000 },
      ],
    });

    // Idempotent re-link of the same Google identity keeps original createdAt and returns 200.
    const repeatGoogle = await handleAuthLink(database, {
      userId: initial.user.id,
      body: { provider: 'google', idToken: googleToken },
      appleAudience: APPLE_AUD,
      googleAudience: GOOGLE_AUD,
      googleKeySource: google.jwks,
      now: NOW + 5000,
    });
    expect(repeatGoogle).toEqual(afterGoogle);

    // Link Email via startEmailCode + handleAuthLink.
    expect(
      await startEmailCode(database, {
        email: '  Me@Example.COM ',
        ip: IP,
        mailer: mail.mailer,
        now: NOW + 2000,
      }),
    ).toBe('sent');
    const code = mail.lastCode();

    const afterEmail = await handleAuthLink(database, {
      userId: initial.user.id,
      body: { provider: 'email', email: 'Me@Example.COM', code },
      appleAudience: APPLE_AUD,
      googleAudience: GOOGLE_AUD,
      now: NOW + 3000,
    });
    expect(afterEmail).toEqual({
      status: 200,
      body: [
        { provider: 'apple', email: 'relay@privaterelay.appleid.com', createdAt: NOW },
        { provider: 'google', email: 'me@gmail.com', createdAt: NOW + 1000 },
        { provider: 'email', email: 'me@example.com', createdAt: NOW + 3000 },
      ],
    });

    // The email code was consumed and cannot be reused.
    const replayEmail = await handleAuthLink(database, {
      userId: initial.user.id,
      body: { provider: 'email', email: 'me@example.com', code },
      appleAudience: APPLE_AUD,
      now: NOW + 3001,
    });
    expect(replayEmail).toEqual({ status: 401, body: { error: 'Invalid or expired code' } });

    // Signing in on Mac with Google or Email resolves to the exact same userId!
    const macGoogle = await createSessionForIdentity(database, {
      provider: 'google',
      sub: 'google-sub-main',
      email: 'me@gmail.com',
      deviceId: 'dev-mac',
      jwtSecret: TEST_JWT_SECRET,
      now: NOW + 10_000,
    });
    expect(macGoogle.user.id).toBe(initial.user.id);
    expect(macGoogle.isNewAccount).toBe(false);

    const macEmail = await createSessionForIdentity(database, {
      provider: 'email',
      sub: 'me@example.com',
      email: 'me@example.com',
      deviceId: 'dev-mac',
      jwtSecret: TEST_JWT_SECRET,
      now: NOW + 10_001,
    });
    expect(macEmail.user.id).toBe(initial.user.id);
    expect(macEmail.isNewAccount).toBe(false);
  });

  it('links Apple to a Google account and rejects invalid Apple/Google tokens with 401 (never "Unauthorized")', async () => {
    const { db, sqlite } = createTestD1();
    const database = db as unknown as DatabaseClient;
    const apple = await makeKeyFixture('ES256', 'a-link-1');
    const google = await makeKeyFixture('RS256', 'g-link-2');
    const otherKey = await makeKeyFixture('ES256', 'a-wrong');

    const user = await createSessionForIdentity(database, {
      provider: 'google',
      sub: 'google-starter',
      email: 'starter@gmail.com',
      deviceId: 'dev-1',
      jwtSecret: TEST_JWT_SECRET,
      now: NOW,
    });

    const rawNonce = 'apple-link-nonce';
    const validAppleToken = await new SignJWT({
      nonce: await sha256Hex(rawNonce),
      email: 'starter@privaterelay.appleid.com',
    })
      .setProtectedHeader({ alg: 'ES256', kid: 'a-link-1' })
      .setIssuer('https://appleid.apple.com')
      .setAudience(APPLE_AUD)
      .setSubject('apple-linked-sub')
      .setIssuedAt(Math.floor(NOW / 1000))
      .setExpirationTime(Math.floor(NOW / 1000) + 600)
      .sign(apple.privateKey);

    // Wrong nonce -> 401, no write
    const badNonce = await handleAuthLink(database, {
      userId: user.user.id,
      body: { provider: 'apple', identityToken: validAppleToken, nonce: 'wrong-nonce' },
      appleAudience: APPLE_AUD,
      appleKeySource: apple.jwks,
      now: NOW + 10,
    });
    expect(badNonce.status).toBe(401);
    expect(badNonce.body).not.toEqual({ error: 'Unauthorized' });

    // Wrong signature -> 401, no write
    const badSigToken = await new SignJWT({ nonce: await sha256Hex(rawNonce) })
      .setProtectedHeader({ alg: 'ES256', kid: 'a-wrong' })
      .setIssuer('https://appleid.apple.com')
      .setAudience(APPLE_AUD)
      .setSubject('apple-bad-sig')
      .setIssuedAt(Math.floor(NOW / 1000))
      .setExpirationTime(Math.floor(NOW / 1000) + 600)
      .sign(otherKey.privateKey);
    const badSig = await handleAuthLink(database, {
      userId: user.user.id,
      body: { provider: 'apple', identityToken: badSigToken, nonce: rawNonce },
      appleAudience: APPLE_AUD,
      appleKeySource: apple.jwks,
      now: NOW + 11,
    });
    expect(badSig.status).toBe(401);

    // Invalid Google token -> 401, no write
    const badGoogle = await handleAuthLink(database, {
      userId: user.user.id,
      body: { provider: 'google', idToken: 'not-a-jwt' },
      appleAudience: APPLE_AUD,
      googleAudience: GOOGLE_AUD,
      googleKeySource: google.jwks,
      now: NOW + 12,
    });
    expect(badGoogle.status).toBe(401);
    expect(badGoogle.body).not.toEqual({ error: 'Unauthorized' });

    // Still only the original Google identity in DB.
    expect(sqlite.prepare('SELECT COUNT(*) AS n FROM identity').get()).toEqual({ n: 1 });

    // Valid Apple link succeeds.
    const ok = await handleAuthLink(database, {
      userId: user.user.id,
      body: { provider: 'apple', identityToken: validAppleToken, nonce: rawNonce },
      appleAudience: APPLE_AUD,
      appleKeySource: apple.jwks,
      now: NOW + 100,
    });
    expect(ok).toEqual({
      status: 200,
      body: [
        { provider: 'google', email: 'starter@gmail.com', createdAt: NOW },
        { provider: 'apple', email: 'starter@privaterelay.appleid.com', createdAt: NOW + 100 },
      ],
    });
  });

  it('returns 409 identity_in_use when the identity belongs to another user, without merging or transferring', async () => {
    const { db } = createTestD1();
    const database = db as unknown as DatabaseClient;
    vi.spyOn(console, 'log').mockImplementation(() => {});
    const google = await makeKeyFixture('RS256', 'g-conflict');
    const mail = fakeMailer();

    const userA = await createSessionForIdentity(database, {
      provider: 'apple',
      sub: 'apple-a',
      email: 'a@privaterelay.appleid.com',
      deviceId: 'dev-a',
      jwtSecret: TEST_JWT_SECRET,
      now: NOW,
    });
    const userB = await createSessionForIdentity(database, {
      provider: 'google',
      sub: 'google-b',
      email: 'b@gmail.com',
      deviceId: 'dev-b',
      jwtSecret: TEST_JWT_SECRET,
      now: NOW + 1,
    });
    const userC = await createSessionForIdentity(database, {
      provider: 'email',
      sub: 'c@example.com',
      email: 'c@example.com',
      deviceId: 'dev-c',
      jwtSecret: TEST_JWT_SECRET,
      now: NOW + 2,
    });

    // User A tries to link User B's Google account -> 409 identity_in_use
    const googleBToken = await new SignJWT({ email: 'b@gmail.com' })
      .setProtectedHeader({ alg: 'RS256', kid: 'g-conflict' })
      .setIssuer('https://accounts.google.com')
      .setAudience(GOOGLE_AUD)
      .setSubject('google-b')
      .setIssuedAt(Math.floor(NOW / 1000))
      .setExpirationTime(Math.floor(NOW / 1000) + 600)
      .sign(google.privateKey);

    const conflictGoogle = await handleAuthLink(database, {
      userId: userA.user.id,
      body: { provider: 'google', idToken: googleBToken },
      appleAudience: APPLE_AUD,
      googleAudience: GOOGLE_AUD,
      googleKeySource: google.jwks,
      now: NOW + 50,
    });
    expect(conflictGoogle).toEqual({ status: 409, body: { error: 'identity_in_use' } });

    // User A tries to link User C's Email -> 409 identity_in_use (after verifying email code)
    await startEmailCode(database, { email: 'c@example.com', ip: IP, mailer: mail.mailer, now: NOW + 60 });
    const conflictEmail = await handleAuthLink(database, {
      userId: userA.user.id,
      body: { provider: 'email', email: 'c@example.com', code: mail.lastCode() },
      appleAudience: APPLE_AUD,
      now: NOW + 61,
    });
    expect(conflictEmail).toEqual({ status: 409, body: { error: 'identity_in_use' } });

    // None of the accounts were merged or modified.
    expect(await listUserIdentities(database, userA.user.id)).toEqual([
      { provider: 'apple', email: 'a@privaterelay.appleid.com', createdAt: NOW },
    ]);
    expect(await listUserIdentities(database, userB.user.id)).toEqual([
      { provider: 'google', email: 'b@gmail.com', createdAt: NOW + 1 },
    ]);
    expect(await listUserIdentities(database, userC.user.id)).toEqual([
      { provider: 'email', email: 'c@example.com', createdAt: NOW + 2 },
    ]);
  });

  it('enforces email code attempt limits, expiry, MCP pending isolation, and 24h lockout', async () => {
    const { db, sqlite } = createTestD1();
    const database = db as unknown as DatabaseClient;
    vi.spyOn(console, 'log').mockImplementation(() => {});
    vi.spyOn(console, 'warn').mockImplementation(() => {});
    const mail = fakeMailer();

    const user = await createSessionForIdentity(database, {
      provider: 'apple',
      sub: 'apple-email-rules',
      email: null,
      deviceId: 'dev-1',
      jwtSecret: TEST_JWT_SECRET,
      now: NOW,
    });

    // MCP pending code is not accepted by App /auth/link.
    await startEmailCode(database, {
      email: 'rules@example.com',
      ip: IP,
      mailer: mail.mailer,
      pendingId: 'mcp-pending-1',
      now: NOW + 1,
    });
    const mcpCodeRes = await handleAuthLink(database, {
      userId: user.user.id,
      body: { provider: 'email', email: 'rules@example.com', code: mail.lastCode() },
      appleAudience: APPLE_AUD,
      now: NOW + 2,
    });
    expect(mcpCodeRes).toEqual({ status: 401, body: { error: 'Invalid or expired code' } });

    // Expired code rejected.
    await startEmailCode(database, { email: 'exp@example.com', ip: IP, mailer: mail.mailer, now: NOW + 10 });
    const expiredRes = await handleAuthLink(database, {
      userId: user.user.id,
      body: { provider: 'email', email: 'exp@example.com', code: mail.lastCode() },
      appleAudience: APPLE_AUD,
      now: NOW + 10 + EMAIL_CODE_TTL_MS,
    });
    expect(expiredRes).toEqual({ status: 401, body: { error: 'Invalid or expired code' } });

    // After EMAIL_CODE_MAX_ATTEMPTS wrong guesses, even the right code fails; after EMAIL_LOCKOUT_FAILURES
    // across codes, the address is locked out.
    const targetEmail = 'lock@example.com';
    for (const batch of [EMAIL_CODE_MAX_ATTEMPTS, EMAIL_LOCKOUT_FAILURES - EMAIL_CODE_MAX_ATTEMPTS]) {
      await startEmailCode(database, { email: targetEmail, ip: IP, mailer: mail.mailer, now: NOW + 100 });
      const real = mail.lastCode();
      const wrong = real === '000000' ? '111111' : '000000';
      for (let i = 0; i < batch; i++) {
        const res = await handleAuthLink(database, {
          userId: user.user.id,
          body: { provider: 'email', email: targetEmail, code: wrong },
          appleAudience: APPLE_AUD,
          now: NOW + 101 + i,
        });
        expect(res).toEqual({ status: 401, body: { error: 'Invalid or expired code' } });
      }
      // Even right code fails once attempts hit max.
      const afterMax = await handleAuthLink(database, {
        userId: user.user.id,
        body: { provider: 'email', email: targetEmail, code: real },
        appleAudience: APPLE_AUD,
        now: NOW + 200,
      });
      expect(afterMax).toEqual({ status: 401, body: { error: 'Invalid or expired code' } });
    }

    // No email identity was written.
    expect(sqlite.prepare('SELECT COUNT(*) AS n FROM identity').get()).toEqual({ n: 1 });
  });

  it('handles concurrent link races so only one user claims an unbound identity', async () => {
    const { db } = createTestD1();
    const database = db as unknown as DatabaseClient;

    const u1 = await createSessionForIdentity(database, {
      provider: 'apple',
      sub: 'race-u1',
      email: null,
      deviceId: 'd1',
      jwtSecret: TEST_JWT_SECRET,
      now: NOW,
    });
    const u2 = await createSessionForIdentity(database, {
      provider: 'apple',
      sub: 'race-u2',
      email: null,
      deviceId: 'd2',
      jwtSecret: TEST_JWT_SECRET,
      now: NOW + 1,
    });

    // Interleave u2's complete link right before u1 executes its atomic claim batch.
    let intercepted = false;
    let r2: Awaited<ReturnType<typeof linkIdentity>> | undefined;
    const proxiedDb = new Proxy(database, {
      get(target, prop, receiver) {
        if (prop === 'batch') {
          return async (...args: Parameters<DatabaseClient['batch']>) => {
            if (!intercepted) {
              intercepted = true;
              r2 = await linkIdentity(database, {
                userId: u2.user.id,
                provider: 'google',
                sub: 'shared-google-race',
                email: 'race@gmail.com',
                now: NOW + 10,
              });
            }
            return target.batch(...args);
          };
        }
        return Reflect.get(target, prop, receiver);
      },
    });

    const r1 = await linkIdentity(proxiedDb, {
      userId: u1.user.id,
      provider: 'google',
      sub: 'shared-google-race',
      email: 'race@gmail.com',
      now: NOW + 10,
    });

    expect(intercepted).toBe(true);
    expect(r2?.ok).toBe(true);
    expect(r1).toEqual({ ok: false, reason: 'identity_in_use' });
    expect(await listUserIdentities(database, u1.user.id)).toHaveLength(1);
    expect(await listUserIdentities(database, u2.user.id)).toHaveLength(2);
  });

  it('reads back the identity list inside the same write batch (no separate post-write SELECT)', async () => {
    const { db, trace } = createTestD1();
    const database = db as unknown as DatabaseClient;

    const u = await createSessionForIdentity(database, {
      provider: 'apple',
      sub: 'batch-u1',
      email: 'batch@privaterelay.appleid.com',
      deviceId: 'd1',
      jwtSecret: TEST_JWT_SECRET,
      now: NOW,
    });

    trace.reset();
    const res = await linkIdentity(database, {
      userId: u.user.id,
      provider: 'google',
      sub: 'batch-g1',
      email: 'batch@gmail.com',
      now: NOW + 10,
    });

    expect(res).toEqual({
      ok: true,
      identities: [
        { provider: 'apple', email: 'batch@privaterelay.appleid.com', createdAt: NOW },
        { provider: 'google', email: 'batch@gmail.com', createdAt: NOW + 10 },
      ],
    });
    // 1 direct SELECT (caller check) + 1 atomic 3-statement batch (insert + owner check + list readback).
    expect(trace.direct).toBe(1);
    expect(trace.batches).toEqual([3]);
  });
});
