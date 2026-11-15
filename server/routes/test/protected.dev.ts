import { defineHandler } from 'void';
import { requireUser } from '../../src/auth/middleware';

export const GET = defineHandler(async (c) => {
  const userId = await requireUser(c);
  if (userId instanceof Response) return userId;
  return c.json({ userId }, 200);
});
