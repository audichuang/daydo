import { entityHome, user } from '@schema';
import { and, eq, or, type BatchItem } from 'void/db';
import { collectProjectIds, decodeForUser, forUser, purgedAmong } from '../../membership';
import type { MembershipRole } from '../entities';
import type { AppDb } from '../push';
import type { LookupPair } from './parse';

export const QUERY_CHUNK_SIZE = 50;
export const PAIR_CHUNK_SIZE = 25;

export function chunkArray<T>(items: readonly T[], size = QUERY_CHUNK_SIZE): T[][] {
  const chunks: T[][] = [];
  for (let i = 0; i < items.length; i += size) {
    chunks.push(items.slice(i, i + size));
  }
  return chunks;
}

export interface PushContext {
  knownHome: Map<string, string>;
  purgedSet: Set<string>;
  meMemberId: string | null;
  memberships: Record<string, MembershipRole>;
  removedOwnerProjects: Set<string>;
}

/**
 * Runs D1 Batch 1 to load existing entityHome bindings, purged projects,
 * the pusher's meMemberId, and current/removed project memberships.
 */
export async function loadPushContext(
  db: AppDb,
  params: {
    userId: string;
    lookupPairs: readonly LookupPair[];
    projectIdsToCheck: readonly string[];
  },
): Promise<PushContext> {
  const { userId, lookupPairs, projectIdsToCheck } = params;
  const batch1Queries: BatchItem<'sqlite'>[] = [];

  const homeChunks = chunkArray(lookupPairs, PAIR_CHUNK_SIZE);
  for (const chunk of homeChunks) {
    batch1Queries.push(
      db
        .select({
          entity: entityHome.entity,
          entityId: entityHome.entityId,
          scope: entityHome.scope,
        })
        .from(entityHome)
        .where(
          or(
            ...chunk.map((p) =>
              and(eq(entityHome.entity, p.entity), eq(entityHome.entityId, p.entityId)),
            ),
          ),
        ),
    );
  }

  const purgedChunks = chunkArray(projectIdsToCheck, QUERY_CHUNK_SIZE);
  for (const chunk of purgedChunks) {
    batch1Queries.push(purgedAmong(db, chunk));
  }

  const userQueryIdx = batch1Queries.length;
  batch1Queries.push(
    db.select({ meMemberId: user.meMemberId }).from(user).where(eq(user.id, userId)),
  );

  const membershipQueryIdx = batch1Queries.length;
  batch1Queries.push(forUser(db, userId));

  const batch1Results = (await db.batch(
    batch1Queries as [BatchItem<'sqlite'>, ...BatchItem<'sqlite'>[]],
  )) as Array<Array<Record<string, unknown>>>;

  const knownHome = new Map<string, string>();
  let cursorIdx = 0;
  for (let i = 0; i < homeChunks.length; i += 1) {
    for (const row of batch1Results[cursorIdx++]) {
      knownHome.set(`${String(row.entity)}:${String(row.entityId)}`, String(row.scope));
    }
  }

  const purgedSet = new Set<string>();
  for (let i = 0; i < purgedChunks.length; i += 1) {
    collectProjectIds(batch1Results[cursorIdx++], purgedSet);
  }

  const userRow = batch1Results[userQueryIdx]?.[0];
  const meMemberId =
    userRow && typeof userRow.meMemberId === 'string' ? userRow.meMemberId : null;

  const { memberships, removedOwnerProjects } = decodeForUser(
    batch1Results[membershipQueryIdx] ?? [],
  );

  return {
    knownHome,
    purgedSet,
    meMemberId,
    memberships,
    removedOwnerProjects,
  };
}
