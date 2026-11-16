import { oauthRefresh, user } from '@schema';
import { and, eq, gt, isNull, sql } from 'void/db';
import { sha256Hex } from '../auth/crypto';
import type { DatabaseClient } from '../auth/session';
import { randomB64url, successorToken } from './tokens';

// MCP refresh tokens (spec/mcp.md 4.5). Deliberately differs from the App's session.ts
// (spec 15.6): the successor is HMAC(K_refresh, presented token), so concurrent requests and
// lost-response retries within the grace window all converge on the same successor.

export const REFRESH_TTL_MS = 30 * 24 * 60 * 60 * 1000;
export const REFRESH_GRACE_MS = 10 * 60 * 1000;

export type RefreshRow = typeof oauthRefresh.$inferSelect;

export interface NewRefreshFamily {
  familyId: string;
  userId: string;
  clientId: string;
  scope: string;
  resource: string | null;
  now: number;
}

export type RotateResult =
  | { ok: true; refreshToken: string; userId: string; clientId: string; scope: string }
  | { ok: false; description: string };

export async function userExists(database: DatabaseClient, userId: string): Promise<boolean> {
  const row = await database.select({ id: user.id }).from(user).where(eq(user.id, userId)).get();
  return row !== undefined;
}

/** Issues the first (random) refresh token of a family. */
export async function issueRefreshToken(database: DatabaseClient, params: NewRefreshFamily): Promise<string> {
  const token = randomB64url(32);
  await database.insert(oauthRefresh).values({
    refreshHash: await sha256Hex(token),
    familyId: params.familyId,
    userId: params.userId,
    clientId: params.clientId,
    scope: params.scope,
    resource: params.resource,
    createdAt: params.now,
    expiresAt: params.now + REFRESH_TTL_MS,
    revokedAt: null,
    replacedBy: null,
  });
  return token;
}

function findRow(database: DatabaseClient, refreshHash: string): Promise<RefreshRow | undefined> {
  return database.select().from(oauthRefresh).where(eq(oauthRefresh.refreshHash, refreshHash)).get();
}

async function revokeFamily(database: DatabaseClient, familyId: string, now: number): Promise<void> {
  await database
    .update(oauthRefresh)
    .set({ revokedAt: now })
    .where(and(eq(oauthRefresh.familyId, familyId), isNull(oauthRefresh.revokedAt)));
}

/**
 * Rotates a presented refresh token. A `clientId` of null means the client omitted it
 * (accepted, like REF); a non-null value must match the row.
 */
export async function rotateRefreshToken(
  database: DatabaseClient,
  params: { secret: string; refreshToken: string; clientId: string | null; now: number },
): Promise<RotateResult> {
  const { now } = params;
  const presentedHash = await sha256Hex(params.refreshToken);
  let row = await findRow(database, presentedHash);
  if (!row) return { ok: false, description: 'Unknown refresh token' };
  if (params.clientId !== null && params.clientId !== row.clientId) {
    return { ok: false, description: 'client_id mismatch' };
  }
  if (!(await userExists(database, row.userId))) return { ok: false, description: 'User no longer exists' };

  const successor = await successorToken(params.secret, params.refreshToken);
  const successorHash = await sha256Hex(successor);
  const granted: RotateResult = {
    ok: true,
    refreshToken: successor,
    userId: row.userId,
    clientId: row.clientId,
    scope: row.scope,
  };

  if (row.revokedAt === null) {
    if (row.expiresAt <= now) return { ok: false, description: 'Refresh token expired' };
    // Insert the successor only while the presented row is still live, and claim that row
    // in the same batch. Concurrent rotations compute the same successor, so the loser's
    // insert is a no-op and its UPDATE returns no row.
    const [, claimed] = await database.batch([
      database
        .insert(oauthRefresh)
        .select(
          sql`SELECT ${successorHash}, ${row.familyId}, ${row.userId}, ${row.clientId}, ${row.scope}, ${row.resource}, ${now}, ${now + REFRESH_TTL_MS}, NULL, NULL WHERE EXISTS (SELECT 1 FROM oauthRefresh WHERE refreshHash = ${presentedHash} AND revokedAt IS NULL AND expiresAt > ${now})`,
        )
        .onConflictDoNothing(),
      database
        .update(oauthRefresh)
        .set({ revokedAt: now, replacedBy: successorHash })
        .where(
          and(
            eq(oauthRefresh.refreshHash, presentedHash),
            isNull(oauthRefresh.revokedAt),
            gt(oauthRefresh.expiresAt, now),
          ),
        )
        .returning({ refreshHash: oauthRefresh.refreshHash }),
    ]);
    if (claimed.length > 0) return granted;
    // Lost the race: re-read once and take the grace path below.
    row = await findRow(database, presentedHash);
    if (!row || row.revokedAt === null) return { ok: false, description: 'Refresh token expired' };
  }

  // Already rotated: within the grace window, while the deterministic successor is still
  // unused and unexpired, hand back that same successor. Any other reuse revokes the family.
  // No lower bound: a concurrent loser's clock may read slightly before the winner's revokedAt.
  const withinGrace = now - row.revokedAt <= REFRESH_GRACE_MS;
  if (withinGrace && row.replacedBy === successorHash) {
    const next = await findRow(database, successorHash);
    if (next && next.revokedAt === null && next.expiresAt > now) return granted;
  }
  await revokeFamily(database, row.familyId, now);
  return { ok: false, description: 'Refresh token reuse detected; re-authenticate' };
}
