import { defineHandler } from 'void';
import { env } from 'void/env';
import { handleEmailVerify } from '../../../src/auth/email';
import { productionAppDeps } from '../../../src/deps';
import { readJsonObject, withScopeRelocating503 } from '../../../src/http';

export const POST = defineHandler(async (c) =>
  withScopeRelocating503(c, async () => {
    const deps = productionAppDeps(c.env);
    const result = await handleEmailVerify(deps.db, {
      body: await readJsonObject(c),
      jwtSecret: env.JWT_SECRET,
      getScopeStub: deps.getScopeStub,
    });
    return c.json(result.body, result.status);
  }),
);
