import { defineHandler } from 'void';
import { Writer } from '../../durable-objects/writer';
import { requireUser } from '../../src/auth/middleware';
import { nonEmptyString, readJsonObject } from '../../src/http';

const MAX_OPS_PER_PUSH = 200;

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

  const writer = Writer.get('global');
  const result = await writer.push({
    userId,
    deviceId,
    ops: body.ops,
  });

  return c.json(result, 200);
});
