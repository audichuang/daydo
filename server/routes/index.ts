import { defineHandler } from 'void';
import { env } from 'void/env';
import { productionAppDeps } from '../src/deps';
import { authenticateMcp } from '../src/mcp/auth';
import { handleMcpPost, PROTOCOL_VERSION, SERVER_INFO } from '../src/mcp/protocol';
import { toolServices } from '../src/mcp/services';
import { withCors } from '../src/oauth/cors';
import { protectedResourceMetadata, requestOrigin } from '../src/oauth/metadata';

// Codex (rmcp) reads a 200 JSON at the server URL as protected-resource metadata,
// so the health body also carries `resource` and `authorization_servers` (spec/mcp.md 2).
export const GET = defineHandler((c) =>
  withCors(
    c.json({
      ...protectedResourceMetadata(requestOrigin(c.req.url)),
      ok: true,
      server: SERVER_INFO,
      protocol: PROTOCOL_VERSION,
    }),
  ),
);

export const POST = defineHandler(async (c) => {
  const deps = productionAppDeps(c.env);
  const principal = await authenticateMcp(c.req.raw, { database: deps.db, secret: env.JWT_SECRET });
  if (principal instanceof Response) return withCors(principal);
  const ctx = { ...principal, services: toolServices(deps, env) };
  return withCors(await handleMcpPost(c.req.raw, ctx, c.req.header('CF-Ray') ?? null));
});
