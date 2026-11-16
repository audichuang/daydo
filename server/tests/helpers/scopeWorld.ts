import Scope, { ScopeObject, shouldSplitTransaction } from '../../durable-objects/scope';
import { createServerHlcClock } from '../../src/sync/hlc';
import { executeSyncPull } from '../../src/sync/pull';
import { executeSyncPush } from '../../src/sync/push';
import type { ScopeStub } from '../../src/scope/api';
import { createTestD1, createTestDoState } from '../sqliteD1';

export { ScopeObject, shouldSplitTransaction };

export const ScopeClass = Scope.class as unknown as new (
  ctx: DurableObjectState,
  env: { SYNC_FAULT: 'none' | 'split-txn' },
  allowFaultInjection?: boolean,
) => InstanceType<typeof ScopeObject>;

export interface PushCall {
  scope: string;
  deviceId: string;
  ops: Array<Record<string, unknown>>;
}

export type ScopePushInput = Parameters<ScopeStub['push']>[0];
export type ScopePushResult = Awaited<ReturnType<ScopeStub['push']>>;

export interface CreateScopeWorldOptions {
  syncFault?: 'none' | 'split-txn';
  /** Scope DO class to instantiate per scope (defaults to the current ScopeObject). */
  scopeClass?: new (
    ctx: DurableObjectState,
    env: { SYNC_FAULT: 'none' | 'split-txn' },
  ) => unknown;
  onPush?: (
    input: ScopePushInput,
    proceed: (input: ScopePushInput) => Promise<ScopePushResult>,
  ) => Promise<ScopePushResult>;
}

/** In-memory D1 + per-scope ScopeObject test world shared by sync, MCP, and ICS tests. */
export function createScopeWorld(options: CreateScopeWorldOptions = {}) {
  const syncFault = options.syncFault ?? 'none';
  const { d1, db, sqlite, trace } = createTestD1();
  const DoClass = options.scopeClass ?? ScopeClass;
  const scopes = new Map<string, InstanceType<typeof ScopeObject>>();
  const scopeSqlites = new Map<string, ReturnType<typeof createTestDoState>['sqlite']>();
  const calls: PushCall[] = [];
  const clock = createServerHlcClock();

  const getScopeStub = (scope: string): ScopeStub => {
    let instance = scopes.get(scope);
    if (!instance) {
      const doState = createTestDoState();
      instance = new DoClass(doState.ctx, { SYNC_FAULT: syncFault }) as InstanceType<
        typeof ScopeObject
      >;
      scopes.set(scope, instance);
      scopeSqlites.set(scope, doState.sqlite);
    }
    const stub = instance as unknown as ScopeStub;
    const proceed = (nextInput: ScopePushInput) => {
      calls.push({
        scope: nextInput.scope,
        deviceId: nextInput.deviceId,
        // Only object ops are ever routed to a scope.
        ops: nextInput.ops as Array<Record<string, unknown>>,
      });
      return stub.push(nextInput);
    };
    return new Proxy(stub, {
      get(target, prop, receiver) {
        if (prop === 'push') {
          return (input: ScopePushInput) =>
            options.onPush ? options.onPush(input, proceed) : proceed(input);
        }
        const v = Reflect.get(target, prop, receiver) as unknown;
        return typeof v === 'function' ? (v as (...a: unknown[]) => unknown).bind(target) : v;
      },
    });
  };

  const push = (userId: string, deviceId: string, ops: unknown[]) =>
    executeSyncPush(db, { userId, deviceId, ops, getScopeStub, clock });

  const pull = (
    userId: string,
    opts?: { cursors?: Record<string, number>; backfill?: string[]; limit?: number },
  ) =>
    executeSyncPull(db, {
      userId,
      cursors: opts?.cursors ?? {},
      backfill: opts?.backfill,
      limit: opts?.limit ?? 500,
      getScopeStub,
    });

  return {
    d1,
    db,
    sqlite,
    trace,
    clock,
    scopes,
    scopeSqlites,
    calls,
    getScopeStub,
    push,
    pull,
  };
}

export type ScopeWorld = ReturnType<typeof createScopeWorld>;
