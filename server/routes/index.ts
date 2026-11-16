import { defineHandler } from 'void';
import { createDb } from 'void/db';
import { env } from 'void/env';
import { authenticateMcp } from '../src/mcp/auth';
import { handleMcpPost, PROTOCOL_VERSION, SERVER_INFO } from '../src/mcp/protocol';
import { productionToolServices } from '../src/mcp/services';
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
  const db = createDb(c.env.DB, { session: 'first-primary' });
  const principal = await authenticateMcp(c.req.raw, { database: db, secret: env.JWT_SECRET });
  if (principal instanceof Response) return withCors(principal);
  const ctx = { ...principal, services: productionToolServices(db, env) };
  return withCors(await handleMcpPost(c.req.raw, ctx, c.req.header('CF-Ray') ?? null));
});
