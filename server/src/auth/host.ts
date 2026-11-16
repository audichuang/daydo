import type { CloudContext } from 'void';

// Paths served on the MCP hostname (spec/mcp.md §3). Everything else there is 404,
// and these paths are 404 on every other hostname.
const MCP_EXACT_PATHS = new Set([
  '/',
  '/register',
  '/token',
  '/authorize',
  '/.well-known/oauth-authorization-server',
  '/.well-known/oauth-protected-resource',
]);

export function isMcpPath(pathname: string): boolean {
  return MCP_EXACT_PATHS.has(pathname) || pathname.startsWith('/authorize/');
}

/** Compares the request hostname (port ignored) with MCP_HOST. */
export function isMcpHost(requestUrl: string, mcpHost: string | undefined): boolean {
  if (!mcpHost) return false;
  return new URL(requestUrl).hostname === mcpHost.toLowerCase();
}

export function corsPreflight(): Response {
  return new Response(null, {
    status: 204,
    headers: {
      'Access-Control-Allow-Origin': '*',
      'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
      'Access-Control-Allow-Headers': 'Content-Type, Authorization, Mcp-Session-Id',
      'Access-Control-Max-Age': '86400',
    },
  });
}

export interface HostGateOptions {
  getMcpHost: () => string | undefined;
}

export function createHostGateMiddleware(options: HostGateOptions) {
  return async (c: CloudContext, next: () => Promise<void>): Promise<Response | void> => {
    const url = c.req.url;
    const onMcpHost = isMcpHost(url, options.getMcpHost());
    const mcpPath = isMcpPath(new URL(url).pathname);

    if (onMcpHost !== mcpPath) {
      return c.json({ error: 'Not found' }, 404);
    }
    if (onMcpHost && c.req.method === 'OPTIONS') {
      return corsPreflight();
    }
    await next();
  };
}
