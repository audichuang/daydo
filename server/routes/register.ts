import { defineHandler } from 'void';
import { productionAppDeps } from '../src/deps';
import { readJsonObject } from '../src/http';
import { withCors } from '../src/oauth/cors';
import { registerClient } from '../src/oauth/register';

export const POST = defineHandler(async (c) => {
  const result = await registerClient(productionAppDeps(c.env).db, {
    body: await readJsonObject(c),
    ip: c.req.header('CF-Connecting-IP') ?? null,
  });
  return withCors(c.json(result.body, result.status, { 'Cache-Control': 'no-store' }));
});
