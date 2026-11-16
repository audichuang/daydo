import { defineHandler } from 'void';
import { createDb } from 'void/db';
import { env } from 'void/env';
import { withCors } from '../src/oauth/cors';
import { handleToken } from '../src/oauth/token';

// handleToken answers non-POST methods with 405 (spec/mcp.md 4.5).
const handler = defineHandler(async (c) =>
  withCors(
    await handleToken(c.req.raw, {
      database: createDb(c.env.DB, { session: 'first-primary' }),
      secret: env.JWT_SECRET,
    }),
  ),
);

export const POST = handler;
export const GET = handler;
export const PUT = handler;
export const PATCH = handler;
export const DELETE = handler;
