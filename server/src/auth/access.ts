import { createRemoteJWKSet, jwtVerify, type JWTVerifyGetKey } from 'jose';
import type { CloudContext } from 'void';
import { env } from 'void/env';
import { isMcpHost } from './host';

export type AccessJwksResolver = (certsUrl: string) => JWTVerifyGetKey;

export interface AccessConfig {
  teamDomain?: string;
  aud?: string;
}

export interface AccessMiddlewareOptions {
  getConfig?: () => AccessConfig;
  jwksResolver?: AccessJwksResolver;
  isDev?: boolean;
  /** Defaults to env.MCP_HOST. Requests on this hostname skip Access (spec/mcp.md §3). */
  getMcpHost?: () => string | undefined;
}

const accessJwksCache = new Map<string, JWTVerifyGetKey>();

export function getAccessJwks(certsUrl: string): JWTVerifyGetKey {
  let cached = accessJwksCache.get(certsUrl);
  if (!cached) {
    cached = createRemoteJWKSet(new URL(certsUrl));
    accessJwksCache.set(certsUrl, cached);
  }
  return cached;
}

export function shouldSkipAccessVerification(
  isDev: boolean = import.meta.env.DEV,
): boolean {
  return import.meta.env.DEV && isDev;
}

export async function verifyAccessJwt(params: {
  token: string;
  teamDomain: string;
  aud: string;
  jwksResolver?: AccessJwksResolver;
  currentDate?: Date;
}) {
  const certsUrl = `https://${params.teamDomain}/cdn-cgi/access/certs`;
  const issuer = `https://${params.teamDomain}`;
  const jwks = (params.jwksResolver ?? getAccessJwks)(certsUrl);

  return jwtVerify(params.token, jwks, {
    issuer,
    audience: params.aud,
    algorithms: ['RS256'],
    currentDate: params.currentDate,
  });
}

export function createAccessMiddleware(options: AccessMiddlewareOptions = {}) {
  return async (c: CloudContext, next: () => Promise<void>): Promise<Response | void> => {
    if (shouldSkipAccessVerification(options.isDev)) {
      await next();
      return;
    }

    const mcpHost = options.getMcpHost ? options.getMcpHost() : env.MCP_HOST;
    if (isMcpHost(c.req.url, mcpHost)) {
      await next();
      return;
    }

    const { teamDomain, aud } = options.getConfig ? options.getConfig() : {};
    if (!teamDomain || !aud) {
      return c.json({ error: 'Cloudflare Access is not configured' }, 500);
    }

    const token = c.req.header('Cf-Access-Jwt-Assertion')?.trim();
    if (!token) {
      return c.json({ error: 'Forbidden' }, 403);
    }

    try {
      await verifyAccessJwt({
        token,
        teamDomain,
        aud,
        jwksResolver: options.jwksResolver,
      });
    } catch {
      return c.json({ error: 'Forbidden' }, 403);
    }

    await next();
  };
}
