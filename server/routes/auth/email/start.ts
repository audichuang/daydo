import { defineHandler } from 'void';
import { handleEmailStart } from '../../../src/auth/email';
import { productionAppDeps } from '../../../src/deps';
import { readJsonObject } from '../../../src/http';

export const POST = defineHandler(async (c) => {
  const deps = productionAppDeps(c.env);
  const result = await handleEmailStart(deps.db, {
    body: await readJsonObject(c),
    ip: c.req.header('CF-Connecting-IP') ?? null,
    mailer: deps.mailer,
  });
  return c.json(result.body, result.status);
});
