import { createHmac, hkdfSync } from 'node:crypto';
import { SignJWT } from 'jose';
import { describe, expect, it } from 'vitest';
import { sha256Hex, signAccessToken } from '../src/auth/crypto';
import type { DatabaseClient } from '../src/auth/session';
import { withCors } from '../src/oauth/cors';
import { authorizationServerMetadata, protectedResourceMetadata } from '../src/oauth/metadata';
import { ipRateKey } from '../src/ipRateKey';
import { DCR_LIMIT_PER_HOUR, registerClient } from '../src/oauth/register';
import {
  mcpAccessKey,
  mcpRefreshKey,
  sha256b64url,
  signMcpAccessToken,
  successorToken,
  verifyMcpAccessToken,
} from '../src/oauth/tokens';
import { createTestD1 } from './sqliteD1';

const SECRET = 'unit-test-jwt-secret-32-bytes-minimum';
const ORIGIN = 'https://daydo-mcp.audichuang.app';

const b64url = (bytes: Uint8Array | Buffer): string => Buffer.from(bytes).toString('base64url');
const b64urlJson = (obj: unknown): string => b64url(Buffer.from(JSON.stringify(obj), 'utf8'));

function nodeHkdf(info: string): Buffer {
  return Buffer.from(hkdfSync('sha256', SECRET, 'daydo-mcp', info, 32));
}

/** Signs an arbitrary header+payload with HMAC-SHA256 over the given key (forgery helper). */
function hmacJwt(header: object, payload: object, key: Uint8Array | string): string {
  const input = `${b64urlJson(header)}.${b64urlJson(payload)}`;
  const sig = createHmac('sha256', key).update(input).digest();
  return `${input}.${b64url(sig)}`;
}

function claims(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  const now = Math.floor(Date.now() / 1000);
  return {
    iss: ORIGIN,
    aud: ORIGIN,
    sub: 'user-1',
    scope: 'mcp offline_access',
    client_id: 'mcp-abc',
    iat: now,
    exp: now + 3600,
    ...overrides,
  };
}

describe('MCP token keys (spec/mcp.md 4.5, 4.6)', () => {
  it('derives access and refresh keys with HKDF-SHA256(JWT_SECRET, salt=daydo-mcp)', async () => {
    expect(b64url(await mcpAccessKey(SECRET))).toBe(b64url(nodeHkdf('mcp-access-v1')));
    expect(b64url(await mcpRefreshKey(SECRET))).toBe(b64url(nodeHkdf('mcp-refresh-v1')));
  });

  it('successorToken is base64url(HMAC-SHA256(K_refresh, token)) and deterministic', async () => {
    const expected = b64url(createHmac('sha256', nodeHkdf('mcp-refresh-v1')).update('rt-1').digest());
    expect(await successorToken(SECRET, 'rt-1')).toBe(expected);
    expect(await successorToken(SECRET, 'rt-1')).toBe(expected);
    expect(await successorToken(SECRET, 'rt-2')).not.toBe(expected);
  });
});

describe('sha256b64url (PKCE S256, ported from REF jwt.test)', () => {
  it('matches the RFC 7636 Appendix B known S256 vector', async () => {
    const verifier = 'dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk';
    expect(await sha256b64url(verifier)).toBe('E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM');
  });

  it('produces base64url output with no padding or url-unsafe chars', async () => {
    expect(await sha256b64url('anything')).not.toMatch(/[+/=]/);
  });
});

describe('MCP access token sign/verify', () => {
  it('signs typ=at+jwt with iss/aud/sub/scope/client_id and 1h expiry, and verifies', async () => {
    const token = await signMcpAccessToken(SECRET, {
      origin: ORIGIN,
      userId: 'user-1',
      scope: 'mcp offline_access',
      clientId: 'mcp-abc',
    });
    const [h, p] = token.split('.');
    const header = JSON.parse(Buffer.from(h, 'base64url').toString('utf8')) as Record<string, unknown>;
    const payload = JSON.parse(Buffer.from(p, 'base64url').toString('utf8')) as Record<string, number | string>;
    expect(header).toEqual({ alg: 'HS256', typ: 'at+jwt' });
    expect(payload).toMatchObject({
      iss: ORIGIN,
      aud: ORIGIN,
      sub: 'user-1',
      scope: 'mcp offline_access',
      client_id: 'mcp-abc',
    });
    expect((payload.exp as number) - (payload.iat as number)).toBe(3600);

    await expect(verifyMcpAccessToken(token, SECRET, ORIGIN)).resolves.toEqual({
      userId: 'user-1',
      clientId: 'mcp-abc',
      scope: 'mcp offline_access',
    });
  });

  it('accepts aud whose origin matches (resource with trailing slash or path)', async () => {
    const key = await mcpAccessKey(SECRET);
    const token = hmacJwt({ alg: 'HS256', typ: 'at+jwt' }, claims({ aud: `${ORIGIN}/` }), key);
    await expect(verifyMcpAccessToken(token, SECRET, ORIGIN)).resolves.toMatchObject({ userId: 'user-1' });
  });

  it('rejects tokens failing any of the REF serveMcp checks', async () => {
    const key = await mcpAccessKey(SECRET);
    const header = { alg: 'HS256', typ: 'at+jwt' };
    const now = Math.floor(Date.now() / 1000);
    const cases: Array<[string, string]> = [
      ['missing typ', hmacJwt({ alg: 'HS256' }, claims(), key)],
      ['typ JWT', hmacJwt({ alg: 'HS256', typ: 'JWT' }, claims(), key)],
      ['expired', hmacJwt(header, claims({ exp: now - 10 }), key)],
      ['no exp', hmacJwt(header, claims({ exp: undefined }), key)],
      ['wrong iss', hmacJwt(header, claims({ iss: 'https://evil.example' }), key)],
      ['missing aud', hmacJwt(header, claims({ aud: undefined }), key)],
      ['wrong aud origin', hmacJwt(header, claims({ aud: 'https://daydo-api.audichuang.app' }), key)],
      ['aud not a URL', hmacJwt(header, claims({ aud: 'not a url' }), key)],
      ['aud array', hmacJwt(header, claims({ aud: [ORIGIN] }), key)],
      ['scope without mcp', hmacJwt(header, claims({ scope: 'offline_access' }), key)],
      ['scope missing', hmacJwt(header, claims({ scope: undefined }), key)],
      ['missing sub', hmacJwt(header, claims({ sub: undefined }), key)],
      ['signed with refresh key', hmacJwt(header, claims(), await mcpRefreshKey(SECRET))],
    ];
    for (const [name, token] of cases) {
      await expect(verifyMcpAccessToken(token, SECRET, ORIGIN), name).rejects.toThrow();
    }
  });

  it('rejects alg=none forgeries', async () => {
    const forged = `${b64urlJson({ alg: 'none', typ: 'at+jwt' })}.${b64urlJson(claims())}.`;
    await expect(verifyMcpAccessToken(forged, SECRET, ORIGIN)).rejects.toThrow();
  });

  it('rejects a lying non-HS256 alg header even when the HMAC over it is valid', async () => {
    const key = await mcpAccessKey(SECRET);
    const forged = hmacJwt({ alg: 'RS256', typ: 'at+jwt' }, claims(), key);
    await expect(verifyMcpAccessToken(forged, SECRET, ORIGIN)).rejects.toThrow();
  });

  it('isolation: an App access token does not pass MCP verification', async () => {
    const appToken = await signAccessToken('user-1', SECRET);
    await expect(verifyMcpAccessToken(appToken, SECRET, ORIGIN)).rejects.toThrow();
  });

  it('isolation: an App-key-signed token with full MCP claims is still rejected', async () => {
    const forged = await new SignJWT(claims())
      .setProtectedHeader({ alg: 'HS256', typ: 'at+jwt' })
      .sign(new TextEncoder().encode(SECRET));
    await expect(verifyMcpAccessToken(forged, SECRET, ORIGIN)).rejects.toThrow();
  });
});

describe('OAuth metadata (spec/mcp.md 4.1)', () => {
  it('authorization server metadata follows REF with issuer = origin', () => {
    expect(authorizationServerMetadata(ORIGIN)).toEqual({
      issuer: ORIGIN,
      authorization_endpoint: `${ORIGIN}/authorize`,
      token_endpoint: `${ORIGIN}/token`,
      registration_endpoint: `${ORIGIN}/register`,
      response_types_supported: ['code'],
      grant_types_supported: ['authorization_code', 'refresh_token'],
      code_challenge_methods_supported: ['S256'],
      token_endpoint_auth_methods_supported: ['none'],
      scopes_supported: ['mcp', 'offline_access'],
    });
  });

  it('protected resource metadata has resource/authorization_servers = origin', () => {
    expect(protectedResourceMetadata(ORIGIN)).toEqual({
      resource: ORIGIN,
      authorization_servers: [ORIGIN],
      scopes_supported: ['mcp', 'offline_access'],
      bearer_methods_supported: ['header'],
    });
  });

  it('withCors adds Access-Control-Allow-Origin * and keeps status/body/headers', async () => {
    const res = withCors(
      new Response('{"a":1}', { status: 429, headers: { 'Content-Type': 'application/json' } }),
    );
    expect(res.status).toBe(429);
    expect(res.headers.get('Access-Control-Allow-Origin')).toBe('*');
    expect(res.headers.get('Content-Type')).toBe('application/json');
    expect(await res.text()).toBe('{"a":1}');
  });
});

describe('DCR /register (spec/mcp.md 4.3)', () => {
  function setup() {
    const { db, sqlite } = createTestD1();
    return { database: db as unknown as DatabaseClient, sqlite };
  }

  const NOW = 1_800_000_000_000;

  it('persists the client and returns the REF-shaped 201 body', async () => {
    const { database, sqlite } = setup();
    const result = await registerClient(database, {
      body: { redirect_uris: ['https://claude.ai/api/mcp/auth_callback'], client_name: 'Claude' },
      ip: '203.0.113.7',
      now: NOW,
    });
    expect(result.status).toBe(201);
    const body = result.body as Record<string, unknown>;
    expect(body.client_id).toMatch(/^mcp-[A-Za-z0-9_-]+$/);
    expect(body).toMatchObject({
      client_name: 'Claude',
      redirect_uris: ['https://claude.ai/api/mcp/auth_callback'],
      token_endpoint_auth_method: 'none',
      grant_types: ['authorization_code', 'refresh_token'],
      response_types: ['code'],
      client_secret_expires_at: 0,
      client_id_issued_at: NOW / 1000,
      scope: 'mcp',
    });

    const rows = sqlite.prepare('SELECT * FROM oauthClient').all() as Array<Record<string, unknown>>;
    expect(rows).toHaveLength(1);
    expect(rows[0]).toMatchObject({
      clientId: body.client_id,
      clientName: 'Claude',
      redirectUris: JSON.stringify(['https://claude.ai/api/mcp/auth_callback']),
      ipHash: await sha256Hex('dcr|203.0.113.7'),
      createdAt: NOW,
    });
  });

  it('accepts http loopback redirects, defaults client_name, and uses "local" without an IP', async () => {
    const { database, sqlite } = setup();
    const result = await registerClient(database, {
      body: { redirect_uris: ['http://localhost:3118/callback', 'http://127.0.0.1/cb'] },
      ip: null,
      now: NOW,
    });
    expect(result.status).toBe(201);
    const row = sqlite.prepare('SELECT clientName, ipHash FROM oauthClient').get() as Record<string, unknown>;
    expect(row.clientName).toBe('mcp-client');
    expect(row.ipHash).toBe(await sha256Hex('dcr|local'));
  });

  it('rejects invalid redirect_uris and client_name without persisting', async () => {
    const { database, sqlite } = setup();
    const bad: Array<Record<string, unknown>> = [
      {},
      { redirect_uris: [] },
      { redirect_uris: 'https://a.example/cb' },
      { redirect_uris: Array.from({ length: 6 }, (_, i) => `https://a.example/cb${i}`) },
      { redirect_uris: ['http://a.example/cb'] },
      { redirect_uris: ['http://192.168.1.2/cb'] },
      { redirect_uris: ['https://a.example/cb#frag'] },
      { redirect_uris: ['https://a.example/cb#'] },
      { redirect_uris: ['not a url'] },
      { redirect_uris: ['javascript:alert(1)'] },
      { redirect_uris: [42] },
      { redirect_uris: ['https://a.example/cb'], client_name: 'x'.repeat(101) },
      { redirect_uris: ['https://a.example/cb'], client_name: 7 },
    ];
    for (const body of bad) {
      const result = await registerClient(database, { body, ip: '203.0.113.7', now: NOW });
      expect(result.status, JSON.stringify(body)).toBe(400);
      expect((result.body as { error: string }).error).toMatch(/^invalid_(redirect_uri|client_metadata)$/);
    }
    expect(sqlite.prepare('SELECT COUNT(*) AS n FROM oauthClient').get()).toEqual({ n: 0 });

    const ok = await registerClient(database, {
      body: { redirect_uris: ['https://a.example/cb'], client_name: 'x'.repeat(100) },
      ip: '203.0.113.7',
      now: NOW,
    });
    expect(ok.status).toBe(201);
  });

  it('limits 10 registrations per IP per hour, counting each IP separately', async () => {
    const { database, sqlite } = setup();
    const body = { redirect_uris: ['https://a.example/cb'] };
    expect(DCR_LIMIT_PER_HOUR).toBe(10);
    for (let i = 0; i < 10; i++) {
      const r = await registerClient(database, { body, ip: '198.51.100.1', now: NOW + i });
      expect(r.status).toBe(201);
    }
    const limited = await registerClient(database, { body, ip: '198.51.100.1', now: NOW + 10 });
    expect(limited.status).toBe(429);
    expect((limited.body as { error: string }).error).toBe('too_many_requests');

    const otherIp = await registerClient(database, { body, ip: '198.51.100.2', now: NOW + 11 });
    expect(otherIp.status).toBe(201);

    // Still limited just before the oldest row leaves the 1h window; allowed after.
    const stillLimited = await registerClient(database, { body, ip: '198.51.100.1', now: NOW + 3_600_000 - 1 });
    expect(stillLimited.status).toBe(429);
    const later = await registerClient(database, { body, ip: '198.51.100.1', now: NOW + 3_600_000 });
    expect(later.status).toBe(201);

    expect(sqlite.prepare('SELECT COUNT(*) AS n FROM oauthClient').get()).toEqual({ n: 12 });
  });

  it('keys IPv6 addresses by /64 so one host cannot rotate through its prefix', async () => {
    const { database } = setup();
    const body = { redirect_uris: ['https://a.example/cb'] };
    for (let i = 0; i < 10; i++) {
      const r = await registerClient(database, { body, ip: `2001:db8:1:2::${(i + 1).toString(16)}`, now: NOW + i });
      expect(r.status).toBe(201);
    }
    const samePrefix = await registerClient(database, { body, ip: '2001:db8:1:2:ffff:ffff:ffff:ffff', now: NOW + 10 });
    expect(samePrefix.status).toBe(429);
    const otherPrefix = await registerClient(database, { body, ip: '2001:db8:1:3::1', now: NOW + 11 });
    expect(otherPrefix.status).toBe(201);
  });
});

describe('ipRateKey', () => {
  it('keeps IPv4 as is and uses local without an address', () => {
    expect(ipRateKey('203.0.113.7')).toBe('203.0.113.7');
    expect(ipRateKey(null)).toBe('local');
    expect(ipRateKey('')).toBe('local');
  });

  it('reduces IPv6 to its /64 prefix, expanding :: and ignoring case and leading zeros', () => {
    expect(ipRateKey('2001:0DB8:0001:0002:0000:0000:0000:0001')).toBe('2001:db8:1:2::/64');
    expect(ipRateKey('2001:db8:1:2::abcd')).toBe('2001:db8:1:2::/64');
    expect(ipRateKey('2001:db8::1')).toBe('2001:db8:0:0::/64');
    expect(ipRateKey('::1')).toBe('0:0:0:0::/64');
    expect(ipRateKey('2001:db8:1:2:3:4:1.2.3.4')).toBe('2001:db8:1:2::/64');
    expect(ipRateKey('2001:db8:1:2::')).toBe('2001:db8:1:2::/64');
  });

  it('falls back to the lowercased raw value for an unparsable IPv6-looking string', () => {
    expect(ipRateKey('2001:db8::1::2')).toBe('2001:db8::1::2');
    expect(ipRateKey('ZZZZ::1')).toBe('zzzz::1');
  });
});
