import { oauthCode, oauthPending, oauthRefresh } from '@schema';
import { inArray, lt } from 'void/db';
import type { DatabaseClient } from '../auth/session';
import { logEvent } from '../mcp/log';

// Purges expired OAuth rows (spec/mcp.md 4.8). Runs from the 5-minute ICS cron on the first
// tick of each UTC hour. oauthClient rows are kept: once pending/code/refresh rows are gone,
// an unused client cannot be told apart from one used long ago, and deleting a live client
// would break its reconnection.

const DAY_MS = 24 * 60 * 60 * 1000;
export const PENDING_RETENTION_MS = DAY_MS;
export const CODE_RETENTION_MS = DAY_MS;
// Keyed on expiry only: every row expires within 30 days of issue, and a revoked row must
// outlive its expiry so a replayed old token still revokes its family.
export const REFRESH_RETENTION_MS = 30 * DAY_MS;
export const CLEANUP_BATCH = 500;
const CRON_INTERVAL_MS = 5 * 60 * 1000;

export interface CleanupCounts {
  pending: number;
  code: number;
  refresh: number;
}

/** Deletes at most `batch` rows per table past their retention; returns how many went. */
export async function cleanupExpiredOAuth(
  database: DatabaseClient,
  now: number,
  batch = CLEANUP_BATCH,
): Promise<CleanupCounts> {
  // DELETE ... LIMIT is not available on D1, so each table deletes through a limited subquery.
  const pending = await database
    .delete(oauthPending)
    .where(
      inArray(
        oauthPending.id,
        database
          .select({ id: oauthPending.id })
          .from(oauthPending)
          .where(lt(oauthPending.expiresAt, now - PENDING_RETENTION_MS))
          .limit(batch),
      ),
    )
    .returning({ id: oauthPending.id });
  const code = await database
    .delete(oauthCode)
    .where(
      inArray(
        oauthCode.codeHash,
        database
          .select({ id: oauthCode.codeHash })
          .from(oauthCode)
          .where(lt(oauthCode.expiresAt, now - CODE_RETENTION_MS))
          .limit(batch),
      ),
    )
    .returning({ id: oauthCode.codeHash });
  const refresh = await database
    .delete(oauthRefresh)
    .where(
      inArray(
        oauthRefresh.refreshHash,
        database
          .select({ id: oauthRefresh.refreshHash })
          .from(oauthRefresh)
          .where(lt(oauthRefresh.expiresAt, now - REFRESH_RETENTION_MS))
          .limit(batch),
      ),
    )
    .returning({ id: oauthRefresh.refreshHash });
  return { pending: pending.length, code: code.length, refresh: refresh.length };
}

/** True on the first 5-minute tick of a UTC hour. */
export function isCleanupTick(scheduledTime: number): boolean {
  return scheduledTime % (60 * 60 * 1000) < CRON_INTERVAL_MS;
}

/** Hourly cleanup for the cron. Never throws, so a failure cannot stop the ICS run. */
export async function runOAuthCleanup(database: DatabaseClient, scheduledTime: number): Promise<void> {
  if (!isCleanupTick(scheduledTime)) return;
  try {
    const counts = await cleanupExpiredOAuth(database, scheduledTime);
    logEvent('log', 'oauth.cleanup', { ...counts });
  } catch (error) {
    logEvent('warn', 'oauth.cleanup.failed', { error: error instanceof Error ? error.message : String(error) });
  }
}
