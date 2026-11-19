import { defineHandler } from 'void';
import { env } from 'void/env';
import { handleScopeRelocationAdmin } from '../../src/admin/scopeRelocation';
import { productionAppDeps } from '../../src/deps';
import { readJsonObject } from '../../src/http';

export const POST = defineHandler(async (c) => {
  const result = await handleScopeRelocationAdmin({
    adminToken: env.SCOPE_ADMIN_TOKEN,
    authorizationHeader: c.req.header('Authorization'),
    readBody: () => readJsonObject(c),
    getPhysicalScopeStub: (physical) => productionAppDeps(c.env).getPhysicalScopeStub(physical),
    resolveScopePhysical: (logical) => productionAppDeps(c.env).resolveScopePhysical(logical),
  });
  return c.json(result.body, result.status);
});
