import { defineHandler } from 'void';
import { env } from 'void/env';
import { productionAppDeps } from '../src/deps';
import { withCors } from '../src/oauth/cors';
import { handleToken } from '../src/oauth/token';

// handleToken answers non-POST methods with 405 (spec/mcp.md 4.5).
const handler = defineHandler(async (c) =>
  withCors(
    await handleToken(c.req.raw, {
      database: productionAppDeps(c.env).db,
      secret: env.JWT_SECRET,
    }),
  ),
);

export const POST = handler;
export const GET = handler;
export const PUT = handler;
export const PATCH = handler;
export const DELETE = handler;
