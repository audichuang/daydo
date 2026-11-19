import { defineHandler } from 'void';
import { requireUser } from '../../src/auth/middleware';
import { productionAppDeps } from '../../src/deps';
import { readJsonObject, withScopeRelocating503 } from '../../src/http';
import { executeSyncPull } from '../../src/sync/pull';

const DEFAULT_PULL_LIMIT = 500;
const MAX_PULL_LIMIT = 1000;

function parseCursors(raw: unknown): Record<string, number> | null {
  if (raw === undefined) return {};
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return null;
  const out: Record<string, number> = {};
  for (const [scope, val] of Object.entries(raw)) {
    if (scope === '__proto__' || scope.length === 0) return null;
    if (typeof val !== 'number' || !Number.isInteger(val) || !Number.isSafeInteger(val) || val < 0) {
      return null;
    }
    out[scope] = val;
  }
  return out;
}

function parseBackfill(raw: unknown): string[] | undefined | null {
  if (raw === undefined) return undefined;
  if (!Array.isArray(raw)) return null;
  const out: string[] = [];
  for (const item of raw) {
    if (typeof item !== 'string' || item.length === 0) return null;
    out.push(item);
  }
  return out;
}

export const POST = defineHandler(async (c) => {
  const userId = await requireUser(c);
  if (userId instanceof Response) return userId;

  const body = await readJsonObject(c);
  if (!body) {
    return c.json({ error: 'Invalid JSON body' }, 400);
  }

  const cursors = parseCursors(body.cursors);
  if (!cursors) {
    return c.json({ error: 'cursors must map scope names to non-negative integers' }, 400);
  }

  const backfill = parseBackfill(body.backfill);
  if (backfill === null) {
    return c.json({ error: 'backfill must be an array of non-empty projectIds' }, 400);
  }

  let limit = DEFAULT_PULL_LIMIT;
  if (body.limit !== undefined) {
    if (
      typeof body.limit !== 'number' ||
      !Number.isInteger(body.limit) ||
      !Number.isSafeInteger(body.limit) ||
      body.limit < 1
    ) {
      return c.json({ error: 'limit must be a positive integer' }, 400);
    }
    limit = Math.min(body.limit, MAX_PULL_LIMIT);
  }

  return withScopeRelocating503(c, async () => {
    const deps = productionAppDeps(c.env);
    const result = await executeSyncPull(deps.db, {
      userId,
      cursors,
      backfill,
      limit,
      getScopeStub: deps.getScopeStub,
    });

    return c.json(result, 200);
  });
});
