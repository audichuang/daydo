import type * as schema from '@schema';
import type { DrizzleD1Database } from 'void/db';
import type {
  PushOpResult,
  ScopeProjectInfo,
  ScopeProjectMemberInput,
  ScopePullInput,
  ScopePullResponse,
  ScopePurgeProjectInput,
  ScopePurgeProjectResponse,
  ScopePushInput,
  ScopePushResponse,
} from '../../durable-objects/scope';
import { advanceServerHlc, type ServerHlcClock } from './hlc';
import { applyPushPlan } from './push/apply';
import { userScope } from './scopeName';
import { chunkArray, loadPushContext } from './push/context';
import { parsePushBatch } from './push/parse';
import { planPushBatch } from './push/plan';

export type AppDb = DrizzleD1Database<typeof schema>;

export interface ScopeStub {
  push(input: ScopePushInput): Promise<ScopePushResponse>;
  pull(input: ScopePullInput): Promise<ScopePullResponse>;
  getInboxProjectId(input: { readableProjectIds: string[] }): Promise<string | null>;
  getProjectInfo(input: { projectId: string }): Promise<ScopeProjectInfo | null>;
  projectMember(input: ScopeProjectMemberInput): Promise<void>;
  purgeProject(input: ScopePurgeProjectInput): Promise<ScopePurgeProjectResponse>;
}

export { chunkArray };

export async function executeSyncPush(
  db: AppDb,
  params: {
    userId: string;
    deviceId: string;
    ops: unknown[];
    getScopeStub: (scope: string) => ScopeStub;
    clock?: ServerHlcClock;
  },
): Promise<{
  results: PushOpResult[];
  /** Server HLC string (`<13-digit ms>:<4-digit counter>:server`). */
  serverTime: string;
}> {
  const { userId, deviceId, ops, getScopeStub, clock } = params;
  const nowMs = Date.now();
  const pusherScope = userScope(userId);
  const nextServerTime = (timeMs: number, observed: string[] = []): string =>
    clock ? clock.tick(timeMs, observed) : advanceServerHlc(timeMs, observed).formatted;

  if (ops.length === 0) {
    return { results: [], serverTime: nextServerTime(nowMs) };
  }

  const parsed = parsePushBatch(ops);
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
    rawOps: ops,
    parsedOps: parsed.ops,
    context,
    plan,
    getScopeStub,
  });

  return {
    results: applied.results,
    serverTime: nextServerTime(Math.max(Date.now(), nowMs), applied.scopeServerTimes),
  };
}
