import type { AppDb } from '../appDb';
import type { PushOpResult, ScopeStub } from '../scope/api';
import { toEnvelope, type OpEnvelope } from './envelope';
import { advanceServerHlc, type ServerHlcClock } from './hlc';
import { applyPushPlan } from './push/apply';
import { userScope } from './scopeName';
import { chunkArray, loadPushContext } from './push/context';
import { collectPushLookups } from './push/parse';
import { planPushBatch } from './push/plan';

export { chunkArray };

interface SyncPushParams {
  userId: string;
  deviceId: string;
  getScopeStub: (scope: string) => ScopeStub;
  clock?: ServerHlcClock;
  storage?: R2Bucket | null;
}

interface SyncPushResult {
  results: PushOpResult[];
  /** Server HLC string (`<13-digit ms>:<4-digit counter>:server`). */
  serverTime: string;
}

/** App push entry: envelopes the raw ops (each validated once) and pushes them. */
export async function executeSyncPush(
  db: AppDb,
  params: SyncPushParams & { ops: unknown[] },
): Promise<SyncPushResult> {
  const { ops, ...rest } = params;
  return executeParsedSyncPush(db, { ...rest, envelopes: ops.map(toEnvelope) });
}

/**
 * Pushes already-enveloped ops (the server-side writer builds its envelopes while planning)
 * through D1 planning and the target Scope DOs without validating them again.
 */
export async function executeParsedSyncPush(
  db: AppDb,
  params: SyncPushParams & { envelopes: readonly OpEnvelope[] },
): Promise<SyncPushResult> {
  const { userId, deviceId, envelopes, getScopeStub, clock, storage } = params;
  const nowMs = Date.now();
  const pusherScope = userScope(userId);
  const nextServerTime = (timeMs: number, observed: string[] = []): string =>
    clock ? clock.tick(timeMs, observed) : advanceServerHlc(timeMs, observed).formatted;

  if (envelopes.length === 0) {
    return { results: [], serverTime: nextServerTime(nowMs) };
  }

  const parsed = collectPushLookups(envelopes);
  const context = await loadPushContext(db, {
    userId,
    lookupPairs: parsed.lookupPairs,
    projectIdsToCheck: parsed.projectIdsToCheck,
  });
  const plan = planPushBatch({
    pusherScope,
    parsedOps: parsed.ops,
    context,
  });
  const applied = await applyPushPlan(db, {
    userId,
    deviceId,
    pusherScope,
    nowMs,
    context,
    plan,
    getScopeStub,
    storage,
  });

  return {
    results: applied.results,
    serverTime: nextServerTime(Math.max(Date.now(), nowMs), applied.scopeServerTimes),
  };
}
