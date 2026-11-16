import { defineHandler } from 'void';
import { env } from 'void/env';
import { productionAppDeps, type AppBindings } from '../../src/deps';
import { handleAuthorizeGet, handleAuthorizePost } from '../../src/oauth/authorize';
import { webIdentityConfigFromEnv } from '../../src/oauth/webIdentity';

// No CORS on /authorize* (spec/mcp.md 4.1): browser navigation only.
function deps(bindings: AppBindings) {
  return { database: productionAppDeps(bindings).db, web: webIdentityConfigFromEnv(env) };
}

export const GET = defineHandler(async (c) => handleAuthorizeGet(c.req.raw, deps(c.env)));

export const POST = defineHandler(async (c) =>
  handleAuthorizePost(c.req.raw, await c.req.parseBody(), deps(c.env)),
);
