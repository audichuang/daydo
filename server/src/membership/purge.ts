import { listScopes, projectMembership, purgedProject } from '@schema';
import { and, eq, inArray, isNull, type BatchItem } from 'void/db';
import type {
  ScopePurgeProjectInput,
  ScopePurgeProjectResponse,
} from '../../durable-objects/scope';
import type { AppDb, ScopeStub } from '../sync/push';

type PurgeStubLookup = (scope: string) => Pick<ScopeStub, 'purgeProject'>;

interface PurgeTarget {
  scope: string;
  input: ScopePurgeProjectInput;
}

/**
 * Asks every target scope to purge its rows of the list and returns the outcomes plus
 * the targets that confirmed. Callers clear listScopes only for confirmed targets; a
 * failed scope keeps its row so a later pull of that scope retries the purge.
 */
async function notifyScopes(
  getScopeStub: PurgeStubLookup,
  targets: readonly PurgeTarget[],
): Promise<{
  settled: Array<PromiseSettledResult<ScopePurgeProjectResponse>>;
  confirmed: PurgeTarget[];
}> {
  const settled = await Promise.allSettled(
    targets.map(async (t) => getScopeStub(t.scope).purgeProject(t.input)),
  );
  const confirmed = targets.filter((_, idx) => settled[idx].status === 'fulfilled');
  return { settled, confirmed };
}

/** Deletes the listScopes rows of `projectId` for scopes that confirmed the purge. */
function clearListScopes(db: AppDb, projectId: string, scopes: string[]) {
  return db
    .delete(listScopes)
    .where(and(eq(listScopes.projectId, projectId), inArray(listScopes.scope, scopes)));
}

/**
 * Permanently deletes a list on its owner's request. One D1 batch atomically marks the
 * list purged, removes every membership, and reads the scopes holding its rows; then
 * the home scope (carrying the delete op) and every listed scope purge. The home
 * scope's failure is rethrown after the confirmed listScopes rows are cleared.
 */
export async function purgeProject(
  db: AppDb,
  params: {
    projectId: string;
    homeScope: string;
    opId: string;
    pusherUserId: string;
    purgedAt: number;
    getScopeStub: PurgeStubLookup;
  },
): Promise<ScopePurgeProjectResponse> {
  const { projectId, homeScope, opId, pusherUserId, purgedAt, getScopeStub } = params;
  const purgeBatchResults = (await db.batch([
    db.insert(purgedProject).values({ projectId, purgedAt }).onConflictDoNothing(),
    db
      .update(projectMembership)
      .set({ removedAt: purgedAt })
      .where(and(eq(projectMembership.projectId, projectId), isNull(projectMembership.removedAt))),
    db
      .select({ scope: listScopes.scope })
      .from(listScopes)
      .where(eq(listScopes.projectId, projectId)),
  ])) as Array<Array<Record<string, unknown>>>;

  const listedScopes = (purgeBatchResults[2] ?? []).map((r) => String(r.scope));
  const scopesToPurge = Array.from(new Set([...listedScopes, homeScope]));
  const { settled, confirmed } = await notifyScopes(
    getScopeStub,
    scopesToPurge.map((scope) => ({
      scope,
      input: {
        projectId,
        purgedAt,
        opId: scope === homeScope ? opId : undefined,
        pusherUserId: scope === homeScope ? pusherUserId : undefined,
      },
    })),
  );

  // One statement for every confirmed scope, run on its own outside a batch.
  if (confirmed.length > 0) {
    await clearListScopes(
      db,
      projectId,
      confirmed.map((t) => t.scope),
    );
  }

  const homeSettled = settled[scopesToPurge.indexOf(homeScope)];
  if (homeSettled.status === 'rejected') {
    throw homeSettled.reason;
  }
  return homeSettled.value;
}

/**
 * Retries purges a scope missed: for the given scopes (one chunk per entry), finds
 * listScopes rows of purged lists, re-sends the purge, and clears the confirmed rows
 * in one batch. Failures stay pending for the next pull.
 */
export async function retryPendingPurges(
  db: AppDb,
  params: { scopeChunks: string[][]; getScopeStub: PurgeStubLookup },
): Promise<void> {
  const { scopeChunks, getScopeStub } = params;
  if (scopeChunks.length === 0) return;
  const purgeCheckResults = (await db.batch(
    scopeChunks.map((chunk) =>
      db
        .select({
          projectId: listScopes.projectId,
          scope: listScopes.scope,
          purgedAt: purgedProject.purgedAt,
        })
        .from(listScopes)
        .innerJoin(purgedProject, eq(listScopes.projectId, purgedProject.projectId))
        .where(inArray(listScopes.scope, chunk)),
    ) as unknown as [BatchItem<'sqlite'>, ...BatchItem<'sqlite'>[]],
  )) as Array<Array<{ projectId: string; scope: string; purgedAt: number }>>;

  const pending: PurgeTarget[] = [];
  for (const rows of purgeCheckResults) {
    for (const r of rows) {
      pending.push({
        scope: String(r.scope),
        input: { projectId: String(r.projectId), purgedAt: Number(r.purgedAt) },
      });
    }
  }
  if (pending.length === 0) return;

  // One delete per confirmed (project, scope) pair, all in one batch.
  const { confirmed } = await notifyScopes(getScopeStub, pending);
  if (confirmed.length > 0) {
    await db.batch(
      confirmed.map((t) => clearListScopes(db, t.input.projectId, [t.scope])) as unknown as [
        BatchItem<'sqlite'>,
        ...BatchItem<'sqlite'>[],
      ],
    );
  }
}
