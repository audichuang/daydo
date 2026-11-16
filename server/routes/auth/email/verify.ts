import { defineHandler } from 'void';
import { createDb } from 'void/db';
import { env } from 'void/env';
import { Scope } from '../../../durable-objects/scope';
import { handleEmailVerify } from '../../../src/auth/email';
import { readJsonObject } from '../../../src/http';

export const POST = defineHandler(async (c) => {
  const result = await handleEmailVerify(createDb(c.env.DB, { session: 'first-primary' }), {
    body: await readJsonObject(c),
    jwtSecret: env.JWT_SECRET,
    getScopeStub: (scope) => Scope.get(scope),
  });
  return c.json(result.body, result.status);
});
