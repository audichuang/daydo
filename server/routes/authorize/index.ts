import { defineHandler } from 'void';
import { createDb } from 'void/db';
import { env } from 'void/env';
import { handleAuthorizeGet, handleAuthorizePost } from '../../src/oauth/authorize';
import { webIdentityConfigFromEnv } from '../../src/oauth/webIdentity';

// No CORS on /authorize* (spec/mcp.md 4.1): browser navigation only.
function deps(db: D1Database) {
  return { database: createDb(db, { session: 'first-primary' }), web: webIdentityConfigFromEnv(env) };
}

export const GET = defineHandler(async (c) => handleAuthorizeGet(c.req.raw, deps(c.env.DB)));

export const POST = defineHandler(async (c) =>
  handleAuthorizePost(c.req.raw, await c.req.parseBody(), deps(c.env.DB)),
);
