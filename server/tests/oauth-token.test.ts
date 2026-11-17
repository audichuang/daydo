import type { DatabaseSync } from 'node:sqlite';
import { drizzle } from 'drizzle-orm/d1';
import { describe, expect, it } from 'vitest';
import * as schema from '../db/schema';
import { sha256Hex } from '../src/auth/crypto';
import type { DatabaseClient } from '../src/auth/session';
import { CODE_TTL_MS, createAuthorizationCode } from '../src/oauth/codes';
import { REFRESH_GRACE_MS, REFRESH_TTL_MS, issueRefreshToken } from '../src/oauth/refresh';
import { handleToken } from '../src/oauth/token';
import { sha256b64url, successorToken, verifyMcpAccessToken } from '../src/oauth/tokens';
import { createTestD1 } from './sqliteD1';

const SECRET = 'unit-test-jwt-secret-32-bytes-minimum';
const ORIGIN = 'https://mcp.daydoapp.com';
const TOKEN_URL = `${ORIGIN}/token`;
const NOW = 1_800_000_000_000;
const CLIENT_ID = 'mcp-client-a';
const REDIRECT_URI = 'https://claude.ai/api/mcp/auth_callback';
const VERIFIER = 'dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk';

type Json = Record<string, unknown>;

function setup() {
  const { db, sqlite, d1 } = createTestD1();
  sqlite.prepare('INSERT INTO user (id, createdAt) VALUES (?, ?)').run('user-1', 0);
  return { database: db as unknown as DatabaseClient, sqlite, d1 };
}

function formRequest(params: Record<string, string>, method = 'POST'): Request {
  return new Request(TOKEN_URL, {
    method,
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: method === 'GET' ? undefined : new URLSearchParams(params).toString(),
  });
}

function jsonRequest(body: string): Request {
  return new Request(TOKEN_URL, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body,
  });
}

async function call(database: DatabaseClient, request: Request, now = NOW) {
  const res = await handleToken(request, { database, secret: SECRET, now });
  return { res, status: res.status, body: (await res.json()) as Json };
}

async function newCode(database: DatabaseClient, overrides: { scope?: string; now?: number } = {}) {
  return createAuthorizationCode(database, {
    clientId: CLIENT_ID,
    redirectUri: REDIRECT_URI,
    codeChallenge: await sha256b64url(VERIFIER),
    scope: overrides.scope ?? 'mcp offline_access',
    resource: ORIGIN,
    userId: 'user-1',
    now: overrides.now ?? NOW,
  });
}

function codeGrant(code: string, extra: Record<string, string> = {}) {
  return formRequest({ grant_type: 'authorization_code', code, code_verifier: VERIFIER, ...extra });
}

function refreshGrant(refreshToken: string, extra: Record<string, string> = {}) {
  return formRequest({ grant_type: 'refresh_token', refresh_token: refreshToken, ...extra });
}

async function refreshRow(sqlite: DatabaseSync, token: string): Promise<Json | undefined> {
  return sqlite.prepare('SELECT * FROM oauthRefresh WHERE refreshHash = ?').get(await sha256Hex(token)) as
    | Json
    | undefined;
}

async function seedRefresh(database: DatabaseClient, now = NOW): Promise<string> {
  return issueRefreshToken(database, {
    familyId: 'family-1',
    userId: 'user-1',
    clientId: CLIENT_ID,
    scope: 'mcp',
    resource: ORIGIN,
    now,
  });
}

function expectNoStore(res: Response) {
  expect(res.headers.get('Cache-Control')).toBe('no-store');
  expect(res.headers.get('Pragma')).toBe('no-cache');
}

describe('/token request handling (spec/mcp.md 4.5)', () => {
  it('rejects non-POST with 405 and the OAuth error shape', async () => {
    const { database } = setup();
    const { res, status, body } = await call(database, formRequest({}, 'GET'));
    expect(status).toBe(405);
    expect(body).toMatchObject({ error: 'invalid_request' });
    expect(typeof body.error_description).toBe('string');
    expectNoStore(res);
  });

  it('rejects an unknown or missing grant_type with 400 unsupported_grant_type', async () => {
    const { database } = setup();
    const cases: Array<Record<string, string>> = [{ grant_type: 'password' }, {}];
    for (const params of cases) {
      const { res, status, body } = await call(database, formRequest(params));
      expect(status).toBe(400);
      expect(body.error).toBe('unsupported_grant_type');
      expectNoStore(res);
    }
  });

  it('rejects an unparseable JSON body with 400 invalid_request', async () => {
    const { database } = setup();
    for (const raw of ['{not json', '[1,2]', 'null']) {
      const { status, body } = await call(database, jsonRequest(raw));
      expect(status, raw).toBe(400);
      expect(body.error, raw).toBe('invalid_request');
    }
  });
});

describe('authorization_code grant', () => {
  it('createAuthorizationCode stores only the hash, a fresh familyId and a 120s expiry', async () => {
    const { database, sqlite } = setup();
    const code = await newCode(database);
    const rows = sqlite.prepare('SELECT * FROM oauthCode').all() as Json[];
    expect(rows).toHaveLength(1);
    expect(rows[0]).toMatchObject({
      codeHash: await sha256Hex(code),
      clientId: CLIENT_ID,
      redirectUri: REDIRECT_URI,
      scope: 'mcp offline_access',
      resource: ORIGIN,
      userId: 'user-1',
      expiresAt: NOW + CODE_TTL_MS,
      usedAt: null,
    });
    expect(CODE_TTL_MS).toBe(120_000);
    expect(rows[0].familyId).toEqual(expect.any(String));
    expect(JSON.stringify(rows[0])).not.toContain(code);
    const other = await newCode(database);
    const familyIds = (sqlite.prepare('SELECT familyId FROM oauthCode').all() as Json[]).map((r) => r.familyId);
    expect(other).not.toBe(code);
    expect(new Set(familyIds).size).toBe(2);
  });

  it('exchanges a code for access + refresh tokens (form body, client_id and redirect_uri matching)', async () => {
    const { database, sqlite } = setup();
    const code = await newCode(database);
    const { res, status, body } = await call(
      database,
      codeGrant(code, { client_id: CLIENT_ID, redirect_uri: REDIRECT_URI }),
    );
    expect(status).toBe(200);
    expectNoStore(res);
    expect(body).toMatchObject({ token_type: 'Bearer', expires_in: 3600, scope: 'mcp offline_access' });
    await expect(verifyMcpAccessToken(body.access_token as string, SECRET, ORIGIN)).resolves.toEqual({
      userId: 'user-1',
      clientId: CLIENT_ID,
      scope: 'mcp offline_access',
    });

    const familyId = (sqlite.prepare('SELECT familyId FROM oauthCode').get() as Json).familyId;
    expect(await refreshRow(sqlite, body.refresh_token as string)).toMatchObject({
      familyId,
      userId: 'user-1',
      clientId: CLIENT_ID,
      scope: 'mcp offline_access',
      resource: ORIGIN,
      createdAt: NOW,
      expiresAt: NOW + REFRESH_TTL_MS,
      revokedAt: null,
      replacedBy: null,
    });
    expect((sqlite.prepare('SELECT usedAt FROM oauthCode').get() as Json).usedAt).toBe(NOW);
  });

  it('accepts a JSON body and an absent client_id (lead override of 4.5, like REF)', async () => {
    const { database } = setup();
    const code = await newCode(database);
    const { status, body } = await call(
      database,
      jsonRequest(JSON.stringify({ grant_type: 'authorization_code', code, code_verifier: VERIFIER })),
    );
    expect(status).toBe(200);
    expect(body.refresh_token).toEqual(expect.any(String));
  });

  it('still issues a refresh token when scope lacks offline_access', async () => {
    const { database } = setup();
    const code = await newCode(database, { scope: 'mcp' });
    const { status, body } = await call(database, codeGrant(code));
    expect(status).toBe(200);
    expect(body.scope).toBe('mcp');
    expect(body.refresh_token).toEqual(expect.any(String));
  });

  it('rejects reuse of a code with invalid_grant', async () => {
    const { database } = setup();
    const code = await newCode(database);
    expect((await call(database, codeGrant(code))).status).toBe(200);
    const again = await call(database, codeGrant(code), NOW + 1);
    expect(again.status).toBe(400);
    expect(again.body.error).toBe('invalid_grant');
    expectNoStore(again.res);
  });

  it('rejects an expired or unknown code with invalid_grant', async () => {
    const { database } = setup();
    const code = await newCode(database);
    const expired = await call(database, codeGrant(code), NOW + CODE_TTL_MS);
    expect(expired.status).toBe(400);
    expect(expired.body.error).toBe('invalid_grant');
    const unknown = await call(database, codeGrant('no-such-code'));
    expect(unknown.body.error).toBe('invalid_grant');
  });

  it('rejects a wrong PKCE verifier without burning the code', async () => {
    const { database } = setup();
    const code = await newCode(database);
    const bad = await call(database, codeGrant(code, { code_verifier: `${VERIFIER}x` }));
    expect(bad.status).toBe(400);
    expect(bad.body.error).toBe('invalid_grant');
    expect((await call(database, codeGrant(code))).status).toBe(200);
  });

  it('rejects a mismatched client_id or redirect_uri without burning the code', async () => {
    const { database } = setup();
    const code = await newCode(database);
    const cases: Array<Record<string, string>> = [
      { client_id: 'mcp-other' },
      { redirect_uri: 'https://evil.example/cb' },
    ];
    for (const extra of cases) {
      const bad = await call(database, codeGrant(code, extra));
      expect(bad.status, JSON.stringify(extra)).toBe(400);
      expect(bad.body.error, JSON.stringify(extra)).toBe('invalid_grant');
    }
    expect((await call(database, codeGrant(code))).status).toBe(200);
  });

  it('rejects missing code or code_verifier with invalid_request', async () => {
    const { database } = setup();
    const noCode = await call(database, formRequest({ grant_type: 'authorization_code', code_verifier: VERIFIER }));
    expect(noCode.status).toBe(400);
    expect(noCode.body.error).toBe('invalid_request');
    const code = await newCode(database);
    const noVerifier = await call(database, formRequest({ grant_type: 'authorization_code', code }));
    expect(noVerifier.status).toBe(400);
    expect(noVerifier.body.error).toBe('invalid_request');
  });

  it('two concurrent exchanges of one code: exactly one succeeds', async () => {
    const { d1, sqlite } = setup();
    // Hold the consuming UPDATE until both requests have passed the read-side checks.
    let arrived = 0;
    let releaseAll!: () => void;
    const bothArrived = new Promise<void>((resolve) => {
      releaseAll = resolve;
    });
    const gate = async () => {
      arrived += 1;
      if (arrived === 2) releaseAll();
      await bothArrived;
    };
    const gated = {
      ...d1,
      prepare(query: string) {
        const stmt = d1.prepare(query);
        if (!/^update "oauthCode"/i.test(query)) return stmt;
        return {
          bind(...values: unknown[]) {
            const bound = stmt.bind(...values);
            return {
              all: async () => (await gate(), bound.all()),
              raw: async () => (await gate(), bound.raw()),
              run: async () => (await gate(), bound.run()),
              first: async (col?: string) => (await gate(), bound.first(col as string)),
            };
          },
        };
      },
    };
    const database = drizzle(gated as unknown as D1Database, { schema }) as unknown as DatabaseClient;

    const code = await newCode(database);
    const results = await Promise.all([call(database, codeGrant(code)), call(database, codeGrant(code))]);
    expect(arrived).toBe(2);
    expect(results.map((r) => r.status).sort()).toEqual([200, 400]);
    expect(results.find((r) => r.status === 400)?.body.error).toBe('invalid_grant');
    expect(sqlite.prepare('SELECT COUNT(*) AS n FROM oauthRefresh').get()).toEqual({ n: 1 });
  });

  it('rejects the code once the user has been deleted, issuing no refresh row', async () => {
    const { database, sqlite } = setup();
    const code = await newCode(database);
    sqlite.prepare('DELETE FROM user WHERE id = ?').run('user-1');
    const { status, body } = await call(database, codeGrant(code));
    expect(status).toBe(400);
    expect(body.error).toBe('invalid_grant');
    expect(sqlite.prepare('SELECT COUNT(*) AS n FROM oauthRefresh').get()).toEqual({ n: 0 });
  });
});

describe('refresh_token grant', () => {
  it('rotates to the deterministic HMAC successor and revokes the presented row', async () => {
    const { database, sqlite } = setup();
    const rt = await seedRefresh(database);
    const later = NOW + 5_000;
    const { res, status, body } = await call(database, refreshGrant(rt, { client_id: CLIENT_ID }), later);
    expect(status).toBe(200);
    expectNoStore(res);
    const successor = await successorToken(SECRET, rt);
    expect(body).toMatchObject({ refresh_token: successor, token_type: 'Bearer', expires_in: 3600, scope: 'mcp' });
    await expect(verifyMcpAccessToken(body.access_token as string, SECRET, ORIGIN)).resolves.toEqual({
      userId: 'user-1',
      clientId: CLIENT_ID,
      scope: 'mcp',
    });
    expect(await refreshRow(sqlite, rt)).toMatchObject({ revokedAt: later, replacedBy: await sha256Hex(successor) });
    expect(await refreshRow(sqlite, successor)).toMatchObject({
      familyId: 'family-1',
      userId: 'user-1',
      clientId: CLIENT_ID,
      scope: 'mcp',
      resource: ORIGIN,
      createdAt: later,
      expiresAt: later + REFRESH_TTL_MS,
      revokedAt: null,
    });
  });

  it('accepts an absent client_id (lead override of 4.5, like REF)', async () => {
    const { database } = setup();
    const rt = await seedRefresh(database);
    const { status, body } = await call(database, refreshGrant(rt));
    expect(status).toBe(200);
    expect(body.refresh_token).toBe(await successorToken(SECRET, rt));
  });

  it('rejects a mismatched client_id without rotating or revoking', async () => {
    const { database, sqlite } = setup();
    const rt = await seedRefresh(database);
    const { status, body } = await call(database, refreshGrant(rt, { client_id: 'mcp-other' }));
    expect(status).toBe(400);
    expect(body.error).toBe('invalid_grant');
    expect(await refreshRow(sqlite, rt)).toMatchObject({ revokedAt: null, replacedBy: null });
    expect(sqlite.prepare('SELECT COUNT(*) AS n FROM oauthRefresh').get()).toEqual({ n: 1 });
  });

  it('a grace retry within 10 minutes returns the same successor and a new access token', async () => {
    const { database, sqlite } = setup();
    const rt = await seedRefresh(database);
    const first = await call(database, refreshGrant(rt), NOW);
    const retry = await call(database, refreshGrant(rt), NOW + REFRESH_GRACE_MS);
    expect(REFRESH_GRACE_MS).toBe(10 * 60 * 1000);
    expect(retry.status).toBe(200);
    expect(retry.body.refresh_token).toBe(first.body.refresh_token);
    await expect(verifyMcpAccessToken(retry.body.access_token as string, SECRET, ORIGIN)).resolves.toMatchObject({
      userId: 'user-1',
    });
    expect(await refreshRow(sqlite, first.body.refresh_token as string)).toMatchObject({ revokedAt: null });
    expect(sqlite.prepare('SELECT COUNT(*) AS n FROM oauthRefresh').get()).toEqual({ n: 2 });
  });

  it('a retry past the grace window revokes the whole family', async () => {
    const { database, sqlite } = setup();
    const rt = await seedRefresh(database);
    const first = await call(database, refreshGrant(rt), NOW);
    const late = await call(database, refreshGrant(rt), NOW + REFRESH_GRACE_MS + 1);
    expect(late.status).toBe(400);
    expect(late.body.error).toBe('invalid_grant');
    expect(await refreshRow(sqlite, first.body.refresh_token as string)).toMatchObject({
      revokedAt: NOW + REFRESH_GRACE_MS + 1,
    });
    const successorUse = await call(database, refreshGrant(first.body.refresh_token as string), NOW + REFRESH_GRACE_MS + 2);
    expect(successorUse.body.error).toBe('invalid_grant');
  });

  it('reusing the old token after its successor was used revokes the family, killing the newest token', async () => {
    const { database, sqlite } = setup();
    const rt = await seedRefresh(database);
    const first = await call(database, refreshGrant(rt), NOW);
    const second = await call(database, refreshGrant(first.body.refresh_token as string), NOW + 1_000);
    expect(second.status).toBe(200);
    const newest = second.body.refresh_token as string;

    const replay = await call(database, refreshGrant(rt), NOW + 2_000);
    expect(replay.status).toBe(400);
    expect(replay.body.error).toBe('invalid_grant');
    const live = sqlite.prepare('SELECT COUNT(*) AS n FROM oauthRefresh WHERE revokedAt IS NULL').get();
    expect(live).toEqual({ n: 0 });

    const afterRevoke = await call(database, refreshGrant(newest), NOW + 3_000);
    expect(afterRevoke.status).toBe(400);
    expect(afterRevoke.body.error).toBe('invalid_grant');
  });

  it('two concurrent refreshes of the same token both succeed with the same refresh_token', async () => {
    const { d1, sqlite } = setup();
    // Hold every batch until both requests have read the unrevoked row, then run the
    // batches one after another (as D1 does), so one conditional UPDATE must lose.
    let arrived = 0;
    let releaseAll!: () => void;
    const bothArrived = new Promise<void>((resolve) => {
      releaseAll = resolve;
    });
    let chain: Promise<unknown> = Promise.resolve();
    const gated = {
      ...d1,
      async batch(statements: D1PreparedStatement[]) {
        arrived += 1;
        if (arrived === 2) releaseAll();
        await bothArrived;
        const run = chain.then(() => d1.batch(statements));
        chain = run.catch(() => undefined);
        return run;
      },
    };
    const database = drizzle(gated as unknown as D1Database, { schema }) as unknown as DatabaseClient;

    const rt = await seedRefresh(database);
    const [a, b] = await Promise.all([
      call(database, refreshGrant(rt), NOW + 5),
      call(database, refreshGrant(rt), NOW + 1),
    ]);
    expect(arrived).toBeGreaterThanOrEqual(2);
    expect(a.status).toBe(200);
    expect(b.status).toBe(200);
    expect(a.body.refresh_token).toBe(b.body.refresh_token);
    expect(await refreshRow(sqlite, a.body.refresh_token as string)).toMatchObject({ revokedAt: null });
  });

  it('a race loser whose clock reads earlier than the winner\'s revokedAt still gets the same successor', async () => {
    const { database, sqlite } = setup();
    const rt = await seedRefresh(database);
    const winner = await call(database, refreshGrant(rt), NOW + 5);
    const loser = await call(database, refreshGrant(rt), NOW + 1);
    expect(loser.status).toBe(200);
    expect(loser.body.refresh_token).toBe(winner.body.refresh_token);
    expect(await refreshRow(sqlite, winner.body.refresh_token as string)).toMatchObject({ revokedAt: null });
  });

  it('rejects after the user is deleted', async () => {
    const { database, sqlite } = setup();
    const rt = await seedRefresh(database);
    sqlite.prepare('DELETE FROM user WHERE id = ?').run('user-1');
    const { status, body } = await call(database, refreshGrant(rt));
    expect(status).toBe(400);
    expect(body.error).toBe('invalid_grant');
    expect(await refreshRow(sqlite, rt)).toMatchObject({ revokedAt: null });
  });

  it('rejects an expired, unknown or missing refresh token', async () => {
    const { database } = setup();
    const rt = await seedRefresh(database);
    const expired = await call(database, refreshGrant(rt), NOW + REFRESH_TTL_MS);
    expect(expired.status).toBe(400);
    expect(expired.body.error).toBe('invalid_grant');
    const unknown = await call(database, refreshGrant('no-such-token'));
    expect(unknown.body.error).toBe('invalid_grant');
    const missing = await call(database, formRequest({ grant_type: 'refresh_token' }));
    expect(missing.status).toBe(400);
    expect(missing.body.error).toBe('invalid_request');
  });
});
