import { defineMiddleware, type CloudContext } from 'void';
import { env } from 'void/env';
import { verifyAccessToken } from './crypto';

declare module 'void' {
  interface CloudContextVariables {
    userId: string;
  }
}

export async function requireUser(c: CloudContext): Promise<string | Response> {
  const header = c.req.header('Authorization');
  if (!header) {
    return c.json({ error: 'Unauthorized' }, 401);
  }
  const match = /^Bearer\s+(\S+)$/i.exec(header.trim());
  if (!match) {
    return c.json({ error: 'Unauthorized' }, 401);
  }
  try {
    const { userId } = await verifyAccessToken(match[1], env.JWT_SECRET);
    c.set('userId', userId);
    return userId;
  } catch {
    return c.json({ error: 'Unauthorized' }, 401);
  }
}

export const requireUserMiddleware = defineMiddleware(async (c, next) => {
  const result = await requireUser(c);
  if (result instanceof Response) return result;
  await next();
});
