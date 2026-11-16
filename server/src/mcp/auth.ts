// Bearer authentication for the MCP endpoint (spec/mcp.md 4.6). Check order:
// signature + exp, iss, aud origin, scope mcp (verifyMcpAccessToken), then the user exists.
import { logEvent } from '../log';
import type { DatabaseClient } from '../auth/session';
import { userExists } from '../oauth/refresh';
import { verifyMcpAccessToken } from '../oauth/tokens';

export interface McpPrincipal {
  userId: string;
  clientId: string | null;
}

export function unauthorized(origin: string): Response {
  return new Response('Unauthorized', {
    status: 401,
    headers: {
      'WWW-Authenticate': `Bearer realm="daydo", resource_metadata="${origin}/.well-known/oauth-protected-resource", error="invalid_token"`,
    },
  });
}

/** Returns the principal, or a 401 response (CORS is added by the route). */
export async function authenticateMcp(
  request: Request,
  deps: { database: DatabaseClient; secret: string },
): Promise<McpPrincipal | Response> {
  const origin = new URL(request.url).origin;
  const match = /^Bearer\s+(.+)$/i.exec(request.headers.get('authorization') ?? '');
  if (!match) {
    logEvent('warn', 'mcp.auth_reject', { reason: 'missing_bearer', ray: request.headers.get('CF-Ray') });
    return unauthorized(origin);
  }
  try {
    const access = await verifyMcpAccessToken(match[1], deps.secret, origin);
    if (!(await userExists(deps.database, access.userId))) throw new Error('user missing');
    return { userId: access.userId, clientId: access.clientId };
  } catch (e) {
    logEvent('warn', 'mcp.auth_reject', {
      reason: e instanceof Error ? e.message.slice(0, 80) : 'invalid',
      ray: request.headers.get('CF-Ray'),
    });
    return unauthorized(origin);
  }
}
