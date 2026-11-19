import { defineHandler } from 'void';
import { requireUser } from '../../src/auth/middleware';
import { productionAppDeps } from '../../src/deps';
import { nonEmptyString, readJsonObject, withScopeRelocating503 } from '../../src/http';
import { MAX_OPS_PER_PUSH } from '../../src/sync/envelope';
import { executeSyncPush } from '../../src/sync/push';
import { serverClock } from '../../src/sync/serverClock';

export const POST = defineHandler(async (c) => {
  const userId = await requireUser(c);
  if (userId instanceof Response) return userId;

  const body = await readJsonObject(c);
  if (!body) {
    return c.json({ error: 'Invalid JSON body' }, 400);
  }

  const deviceId = nonEmptyString(body.deviceId);
  if (!deviceId) {
    return c.json({ error: 'deviceId is required' }, 400);
  }

  if (!Array.isArray(body.ops)) {
    return c.json({ error: 'ops must be an array' }, 400);
  }

  if (body.ops.length > MAX_OPS_PER_PUSH) {
    return c.json({ error: `ops exceeds maximum batch size of ${MAX_OPS_PER_PUSH}` }, 400);
  }

  return withScopeRelocating503(c, async () => {
    const deps = productionAppDeps(c.env);
    const result = await executeSyncPush(deps.db, {
      userId,
      deviceId,
      ops: body.ops as unknown[],
      getScopeStub: deps.getScopeStub,
      clock: serverClock,
      storage: deps.storage,
    });

    return c.json(result, 200);
  });
});
