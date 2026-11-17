import { createLocalJWKSet, exportJWK, generateKeyPair, SignJWT } from 'jose';
import type { CloudContext } from 'void';
import { describe, expect, it, vi } from 'vitest';
import { createAccessMiddleware, verifyAccessJwt } from '../src/auth/access';

vi.mock('void/env', () => ({
  env: { MCP_HOST: 'mcp.daydoapp.com' },
}));

const TEAM_DOMAIN = 'daydo-test.cloudflareaccess.com';
const AUD = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

async function makeRsaKeyFixture(kid: string) {
  const { publicKey, privateKey } = await generateKeyPair('RS256');
  const jwk = await exportJWK(publicKey);
  jwk.kid = kid;
  jwk.alg = 'RS256';
  jwk.use = 'sig';
  return {
    privateKey,
    jwks: createLocalJWKSet({ keys: [jwk] }),
  };
}

const MCP_HOST = 'mcp.daydoapp.com';
const API_URL = 'https://api.daydoapp.com/sync/pull';

function makeMockContext(
  headers: Record<string, string | undefined> = {},
  url: string = API_URL,
): CloudContext {
  const normalized = new Map<string, string>();
  for (const [k, v] of Object.entries(headers)) {
    if (v !== undefined) normalized.set(k.toLowerCase(), v);
  }
  return {
    req: {
      url,
      header: (name?: string) => (name ? normalized.get(name.toLowerCase()) : undefined),
    },
    json: (body: unknown, status = 200) =>
      new Response(JSON.stringify(body), {
        status,
        headers: { 'Content-Type': 'application/json' },
      }),
  } as unknown as CloudContext;
}

describe('Cloudflare Access verification middleware', () => {
  it('verifies a valid RS256 Access JWT and calls next()', async () => {
    const { privateKey, jwks } = await makeRsaKeyFixture('access-rsa-1');
    const token = await new SignJWT({ email: 'family@example.com' })
      .setProtectedHeader({ alg: 'RS256', kid: 'access-rsa-1' })
      .setIssuer(`https://${TEAM_DOMAIN}`)
      .setAudience(AUD)
      .setSubject('user-sub-1')
      .setIssuedAt()
      .setExpirationTime('10m')
      .sign(privateKey);

    let seenCertsUrl: string | null = null;
    const middleware = createAccessMiddleware({
      getMcpHost: () => MCP_HOST,
      getConfig: () => ({ teamDomain: TEAM_DOMAIN, aud: AUD }),
      jwksResolver: (certsUrl) => {
        seenCertsUrl = certsUrl;
        return jwks;
      },
      isDev: false,
    });

    let nextCalled = false;
    const res = await middleware(
      makeMockContext({ 'Cf-Access-Jwt-Assertion': token }),
      async () => {
        nextCalled = true;
      },
    );

    expect(res).toBeUndefined();
    expect(nextCalled).toBe(true);
    expect(seenCertsUrl).toBe(`https://${TEAM_DOMAIN}/cdn-cgi/access/certs`);

    const verified = await verifyAccessJwt({
      token,
      teamDomain: TEAM_DOMAIN,
      aud: AUD,
      jwksResolver: () => jwks,
    });
    expect(verified.payload.sub).toBe('user-sub-1');
  });

  it('returns 403 when audience does not match', async () => {
    const { privateKey, jwks } = await makeRsaKeyFixture('access-rsa-aud');
    const token = await new SignJWT({})
      .setProtectedHeader({ alg: 'RS256', kid: 'access-rsa-aud' })
      .setIssuer(`https://${TEAM_DOMAIN}`)
      .setAudience('wrong-aud')
      .setIssuedAt()
      .setExpirationTime('10m')
      .sign(privateKey);

    const middleware = createAccessMiddleware({
      getMcpHost: () => MCP_HOST,
      getConfig: () => ({ teamDomain: TEAM_DOMAIN, aud: AUD }),
      jwksResolver: () => jwks,
      isDev: false,
    });

    let nextCalled = false;
    const res = await middleware(
      makeMockContext({ 'Cf-Access-Jwt-Assertion': token }),
      async () => {
        nextCalled = true;
      },
    );

    expect(nextCalled).toBe(false);
    expect(res?.status).toBe(403);
    expect(await res?.json()).toEqual({ error: 'Forbidden' });
  });

  it('returns 403 when issuer does not match', async () => {
    const { privateKey, jwks } = await makeRsaKeyFixture('access-rsa-iss');
    const token = await new SignJWT({})
      .setProtectedHeader({ alg: 'RS256', kid: 'access-rsa-iss' })
      .setIssuer('https://wrong-team.cloudflareaccess.com')
      .setAudience(AUD)
      .setIssuedAt()
      .setExpirationTime('10m')
      .sign(privateKey);

    const middleware = createAccessMiddleware({
      getMcpHost: () => MCP_HOST,
      getConfig: () => ({ teamDomain: TEAM_DOMAIN, aud: AUD }),
      jwksResolver: () => jwks,
      isDev: false,
    });

    let nextCalled = false;
    const res = await middleware(
      makeMockContext({ 'Cf-Access-Jwt-Assertion': token }),
      async () => {
        nextCalled = true;
      },
    );

    expect(nextCalled).toBe(false);
    expect(res?.status).toBe(403);
    expect(await res?.json()).toEqual({ error: 'Forbidden' });
  });

  it('returns 403 when token is expired', async () => {
    const { privateKey, jwks } = await makeRsaKeyFixture('access-rsa-exp');
    const nowSec = Math.floor(Date.now() / 1000);
    const token = await new SignJWT({})
      .setProtectedHeader({ alg: 'RS256', kid: 'access-rsa-exp' })
      .setIssuer(`https://${TEAM_DOMAIN}`)
      .setAudience(AUD)
      .setIssuedAt(nowSec - 3600)
      .setExpirationTime(nowSec - 60)
      .sign(privateKey);

    const middleware = createAccessMiddleware({
      getMcpHost: () => MCP_HOST,
      getConfig: () => ({ teamDomain: TEAM_DOMAIN, aud: AUD }),
      jwksResolver: () => jwks,
      isDev: false,
    });

    let nextCalled = false;
    const res = await middleware(
      makeMockContext({ 'Cf-Access-Jwt-Assertion': token }),
      async () => {
        nextCalled = true;
      },
    );

    expect(nextCalled).toBe(false);
    expect(res?.status).toBe(403);
    expect(await res?.json()).toEqual({ error: 'Forbidden' });
  });

  it('returns 403 when Cf-Access-Jwt-Assertion header is missing or empty', async () => {
    const { jwks } = await makeRsaKeyFixture('access-rsa-missing');
    const middleware = createAccessMiddleware({
      getMcpHost: () => MCP_HOST,
      getConfig: () => ({ teamDomain: TEAM_DOMAIN, aud: AUD }),
      jwksResolver: () => jwks,
      isDev: false,
    });

    for (const headers of [{}, { 'Cf-Access-Jwt-Assertion': '   ' }]) {
      let nextCalled = false;
      const res = await middleware(makeMockContext(headers), async () => {
        nextCalled = true;
      });
      expect(nextCalled).toBe(false);
      expect(res?.status).toBe(403);
      expect(await res?.json()).toEqual({ error: 'Forbidden' });
    }
  });

  it('returns 403 when token has an invalid signature', async () => {
    const { jwks } = await makeRsaKeyFixture('access-rsa-sig');
    const { privateKey: attackerKey } = await makeRsaKeyFixture('access-rsa-sig');
    const token = await new SignJWT({})
      .setProtectedHeader({ alg: 'RS256', kid: 'access-rsa-sig' })
      .setIssuer(`https://${TEAM_DOMAIN}`)
      .setAudience(AUD)
      .setIssuedAt()
      .setExpirationTime('10m')
      .sign(attackerKey);

    const middleware = createAccessMiddleware({
      getMcpHost: () => MCP_HOST,
      getConfig: () => ({ teamDomain: TEAM_DOMAIN, aud: AUD }),
      jwksResolver: () => jwks,
      isDev: false,
    });

    let nextCalled = false;
    const res = await middleware(
      makeMockContext({ 'Cf-Access-Jwt-Assertion': token }),
      async () => {
        nextCalled = true;
      },
    );

    expect(nextCalled).toBe(false);
    expect(res?.status).toBe(403);
    expect(await res?.json()).toEqual({ error: 'Forbidden' });
  });

  it('returns 403 when token uses a non-RS256 algorithm', async () => {
    const { publicKey, privateKey } = await generateKeyPair('ES256');
    const jwk = await exportJWK(publicKey);
    jwk.kid = 'access-ec-1';
    jwk.alg = 'ES256';
    jwk.use = 'sig';
    const jwks = createLocalJWKSet({ keys: [jwk] });

    const token = await new SignJWT({})
      .setProtectedHeader({ alg: 'ES256', kid: 'access-ec-1' })
      .setIssuer(`https://${TEAM_DOMAIN}`)
      .setAudience(AUD)
      .setIssuedAt()
      .setExpirationTime('10m')
      .sign(privateKey);

    const middleware = createAccessMiddleware({
      getMcpHost: () => MCP_HOST,
      getConfig: () => ({ teamDomain: TEAM_DOMAIN, aud: AUD }),
      jwksResolver: () => jwks,
      isDev: false,
    });

    let nextCalled = false;
    const res = await middleware(
      makeMockContext({ 'Cf-Access-Jwt-Assertion': token }),
      async () => {
        nextCalled = true;
      },
    );

    expect(nextCalled).toBe(false);
    expect(res?.status).toBe(403);
    expect(await res?.json()).toEqual({ error: 'Forbidden' });
  });

  it('fails closed in production when ACCESS_TEAM_DOMAIN or ACCESS_AUD is unset', async () => {
    const origDev = import.meta.env.DEV;
    import.meta.env.DEV = false;
    try {
      for (const config of [
        { teamDomain: undefined, aud: AUD },
        { teamDomain: TEAM_DOMAIN, aud: undefined },
        { teamDomain: '', aud: '' },
      ]) {
        const middleware = createAccessMiddleware({
          getMcpHost: () => MCP_HOST,
          getConfig: () => config,
        });
        let nextCalled = false;
        const res = await middleware(makeMockContext({}), async () => {
          nextCalled = true;
        });
        expect(nextCalled).toBe(false);
        expect(res?.status).toBe(500);
      }
    } finally {
      import.meta.env.DEV = origDev;
    }
  });

  it('skips verification on the MCP host in production, and only there', async () => {
    let jwksCalled = false;
    const middleware = createAccessMiddleware({
      getMcpHost: () => MCP_HOST,
      getConfig: () => ({ teamDomain: TEAM_DOMAIN, aud: AUD }),
      jwksResolver: () => {
        jwksCalled = true;
        throw new Error('should not be called for the MCP host');
      },
      isDev: false,
    });

    let nextCalled = false;
    const res = await middleware(makeMockContext({}, `https://${MCP_HOST}/token`), async () => {
      nextCalled = true;
    });
    expect(res).toBeUndefined();
    expect(nextCalled).toBe(true);
    expect(jwksCalled).toBe(false);

    nextCalled = false;
    const apiRes = await middleware(
      makeMockContext({}, 'https://api.daydoapp.com/token'),
      async () => {
        nextCalled = true;
      },
    );
    expect(nextCalled).toBe(false);
    expect(apiRes?.status).toBe(403);
  });

  it('reads MCP_HOST from env when getMcpHost is not injected', async () => {
    const middleware = createAccessMiddleware({
      getConfig: () => ({ teamDomain: TEAM_DOMAIN, aud: AUD }),
      jwksResolver: () => {
        throw new Error('should not be called for the MCP host');
      },
      isDev: false,
    });

    let nextCalled = false;
    const res = await middleware(makeMockContext({}, `https://${MCP_HOST}/`), async () => {
      nextCalled = true;
    });
    expect(res).toBeUndefined();
    expect(nextCalled).toBe(true);

    nextCalled = false;
    const apiRes = await middleware(makeMockContext({}), async () => {
      nextCalled = true;
    });
    expect(nextCalled).toBe(false);
    expect(apiRes?.status).toBe(403);
  });

  it('still fails closed on the API host when MCP_HOST is set but Access is not configured', async () => {
    const origDev = import.meta.env.DEV;
    import.meta.env.DEV = false;
    try {
      const middleware = createAccessMiddleware({
        getMcpHost: () => MCP_HOST,
        getConfig: () => ({ teamDomain: undefined, aud: undefined }),
      });
      let nextCalled = false;
      const apiRes = await middleware(makeMockContext({}), async () => {
        nextCalled = true;
      });
      expect(nextCalled).toBe(false);
      expect(apiRes?.status).toBe(500);

      const mcpRes = await middleware(makeMockContext({}, `http://${MCP_HOST}:8443/`), async () => {
        nextCalled = true;
      });
      expect(mcpRes).toBeUndefined();
      expect(nextCalled).toBe(true);
    } finally {
      import.meta.env.DEV = origDev;
    }
  });

  it('skips verification in dev builds', async () => {
    let jwksCalled = false;
    const middleware = createAccessMiddleware({
      getMcpHost: () => MCP_HOST,
      getConfig: () => ({ teamDomain: undefined, aud: undefined }),
      jwksResolver: () => {
        jwksCalled = true;
        throw new Error('should not be called in dev');
      },
    });

    let nextCalled = false;
    const res = await middleware(makeMockContext({}), async () => {
      nextCalled = true;
    });

    expect(res).toBeUndefined();
    expect(nextCalled).toBe(true);
    expect(jwksCalled).toBe(false);
  });
});
