import { defineHandler } from 'void';
import { createDb } from 'void/db';
import { requireUser } from '../../src/auth/middleware';
import { pullUserRows } from '../../src/sync/db';

const DEFAULT_PULL_LIMIT = 500;
const MAX_PULL_LIMIT = 1000;

function parseNonNegativeInt(raw: string | undefined, fallback: number): number | null {
  if (raw === undefined || raw === '') return fallback;
  if (!/^\d+$/.test(raw)) return null;
  const parsed = Number(raw);
  return Number.isSafeInteger(parsed) ? parsed : null;
}

export const GET = defineHandler(async (c) => {
  const userId = await requireUser(c);
  if (userId instanceof Response) return userId;

  const since = parseNonNegativeInt(c.req.query('since'), 0);
  if (since === null) {
    return c.json({ error: 'since must be a non-negative integer' }, 400);
  }

  const parsedLimit = parseNonNegativeInt(c.req.query('limit'), DEFAULT_PULL_LIMIT);
  if (parsedLimit === null || parsedLimit < 1) {
    return c.json({ error: 'limit must be a positive integer' }, 400);
  }
  const limit = Math.min(parsedLimit, MAX_PULL_LIMIT);

  const projectParam = c.req.query('project');
  const projectId = projectParam && projectParam.length > 0 ? projectParam : undefined;

  const db = createDb(c.env.DB, { session: 'first-primary' });
  const result = await pullUserRows(db, {
    userId,
    since,
    limit,
    projectId,
  });

  return c.json(result, 200);
});
