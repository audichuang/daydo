import { eq } from 'drizzle-orm';
import { drizzle } from 'drizzle-orm/d1';
import type { CloudContext } from 'void';
import { describe, expect, it, vi } from 'vitest';
import * as schema from '../db/schema';
import { signAccessToken } from '../src/auth/crypto';
import { createSessionForIdentity, type DatabaseClient } from '../src/auth/session';
import { createTestD1 } from './sqliteD1';

const TEST_JWT_SECRET = 'avatar-test-jwt-secret-must-be-at-least-32-bytes';

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
  },
}));

const { PUT } = await import('../routes/me/avatar');
const putAvatar = PUT as unknown as (c: CloudContext) => Promise<Response>;

function makePutContext(params: {
  d1: D1Database;
  authorization?: string;
  rawBody?: string;
  jsonBody?: unknown;
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

describe('PUT /me/avatar', () => {
  it('returns 401 when unauthenticated or token is invalid', async () => {
    const { d1 } = createTestD1();
    activeD1 = d1;

    const noAuth = await putAvatar(
      makePutContext({
        d1,
        jsonBody: { avatarUrl: 'https://lh3.googleusercontent.com/a/photo=s256-c' },
      }),
    );
    expect(noAuth.status).toBe(401);

    const badScheme = await putAvatar(
      makePutContext({
        d1,
        authorization: 'Basic abc',
        jsonBody: { avatarUrl: 'https://lh3.googleusercontent.com/a/photo=s256-c' },
      }),
    );
    expect(badScheme.status).toBe(401);

    const badJwt = await putAvatar(
      makePutContext({
        d1,
        authorization: 'Bearer not-a-jwt',
        jsonBody: { avatarUrl: 'https://lh3.googleusercontent.com/a/photo=s256-c' },
      }),
    );
    expect(badJwt.status).toBe(401);
  });

  it('accepts https googleusercontent.com URLs, stores in D1 user.avatarUrl, and returns {avatarUrl}', async () => {
    const { d1, db } = createTestD1();
    activeD1 = d1;
    const database = db as unknown as DatabaseClient;

    const caller = await createSessionForIdentity(database, {
      provider: 'google',
      sub: 'g-caller-1',
      email: 'caller@example.com',
      deviceId: 'dev-1',
      jwtSecret: TEST_JWT_SECRET,
      now: 1000,
    });
    const other = await createSessionForIdentity(database, {
      provider: 'google',
      sub: 'g-other-1',
      email: 'other@example.com',
      avatarUrl: 'https://lh3.googleusercontent.com/a/other-keep',
      deviceId: 'dev-2',
      jwtSecret: TEST_JWT_SECRET,
      now: 1001,
    });

    const url = 'https://lh3.googleusercontent.com/a/ACg8ocK-sample=s256-c';
    const res = await putAvatar(
      makePutContext({
        d1,
        authorization: `Bearer ${caller.accessToken}`,
        jsonBody: { avatarUrl: url },
      }),
    );
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ avatarUrl: url });

    const [callerRow] = await db
      .select()
      .from(schema.user)
      .where(eq(schema.user.id, caller.user.id));
    expect(callerRow.avatarUrl).toBe(url);

    const [otherRow] = await db
      .select()
      .from(schema.user)
      .where(eq(schema.user.id, other.user.id));
    expect(otherRow.avatarUrl).toBe('https://lh3.googleusercontent.com/a/other-keep');

    // Also accepts root googleusercontent.com host and normalizes uppercase host.
    const rootRes = await putAvatar(
      makePutContext({
        d1,
        authorization: `Bearer ${caller.accessToken}`,
        jsonBody: { avatarUrl: 'https://GOOGLEUSERCONTENT.COM/a/root=s256-c' },
      }),
    );
    expect(rootRes.status).toBe(200);
    expect(await rootRes.json()).toEqual({ avatarUrl: 'https://googleusercontent.com/a/root=s256-c' });

    // Boundary: exact 2048-char googleusercontent.com URL is accepted.
    const prefix = 'https://lh3.googleusercontent.com/a/';
    const maxLenUrl = prefix + 'x'.repeat(2048 - prefix.length);
    expect(maxLenUrl.length).toBe(2048);
    const maxRes = await putAvatar(
      makePutContext({
        d1,
        authorization: `Bearer ${caller.accessToken}`,
        jsonBody: { avatarUrl: maxLenUrl },
      }),
    );
    expect(maxRes.status).toBe(200);
    expect(await maxRes.json()).toEqual({ avatarUrl: maxLenUrl });
  });

  it('rejects http, non-google hosts, userinfo/port, malformed body, and URLs over 2048 chars with 400', async () => {
    const { d1, db } = createTestD1();
    activeD1 = d1;
    const database = db as unknown as DatabaseClient;

    const caller = await createSessionForIdentity(database, {
      provider: 'google',
      sub: 'g-caller-reject',
      email: 'reject@example.com',
      avatarUrl: 'https://lh3.googleusercontent.com/a/initial',
      deviceId: 'dev-1',
      jwtSecret: TEST_JWT_SECRET,
      now: 1000,
    });
    const accessToken = await signAccessToken(caller.user.id, TEST_JWT_SECRET);

    const prefix = 'https://lh3.googleusercontent.com/a/';
    const tooLongUrl = prefix + 'x'.repeat(2049 - prefix.length);
    expect(tooLongUrl.length).toBe(2049);

    const invalidBodies: Array<Record<string, unknown>> = [
      {},
      { avatarUrl: null },
      { avatarUrl: '' },
      { avatarUrl: '   ' },
      { avatarUrl: 123 },
      { avatarUrl: 'not-a-url' },
      { avatarUrl: 'http://lh3.googleusercontent.com/a/photo=s256-c' },
      { avatarUrl: 'https://example.com/a/photo.png' },
      { avatarUrl: 'https://evilgoogleusercontent.com/a/photo.png' },
      { avatarUrl: 'https://lh3.googleusercontent.com.evil.com/a/photo.png' },
      { avatarUrl: 'https://user@lh3.googleusercontent.com/a/photo.png' },
      { avatarUrl: 'https://lh3.googleusercontent.com:8443/a/photo.png' },
      { avatarUrl: tooLongUrl },
    ];

    for (const jsonBody of invalidBodies) {
      const res = await putAvatar(
        makePutContext({
          d1,
          authorization: `Bearer ${accessToken}`,
          jsonBody,
        }),
      );
      expect(res.status).toBe(400);
    }

    const malformedJsonRes = await putAvatar(
      makePutContext({
        d1,
        authorization: `Bearer ${accessToken}`,
        rawBody: '{not-json',
      }),
    );
    expect(malformedJsonRes.status).toBe(400);

    // Existing avatarUrl remains unchanged in D1.
    const [callerRow] = await db
      .select()
      .from(schema.user)
      .where(eq(schema.user.id, caller.user.id));
    expect(callerRow.avatarUrl).toBe('https://lh3.googleusercontent.com/a/initial');
  });
});
