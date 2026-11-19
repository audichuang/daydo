import Scope, { ScopeObject, shouldSplitTransaction } from '../../durable-objects/scope';
import { systemNow, type GetNow } from '../../src/clock';
import type { AppDeps } from '../../src/deps';
import type { MailMessage } from '../../src/mail/mailer';
import { createServerHlcClock } from '../../src/sync/hlc';
import { executeSyncPull } from '../../src/sync/pull';
import { executeSyncPush } from '../../src/sync/push';
import type { ScopeRelocationStub, ScopeStub } from '../../src/scope/api';
import { createMemoryR2, type MemoryR2Bucket } from './memoryR2';
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
  /** Clock handed out as `deps.getNow` (defaults to systemNow). */
  getNow?: GetNow;
  /** R2 bucket override (defaults to a fresh in-memory bucket). */
  storage?: MemoryR2Bucket;
  /** Optional logical -> physical DO name mapping (simulates SCOPE_PHYSICAL_NAMES). */
  physicalNames?: Record<string, string>;
}

/** In-memory D1 + per-scope ScopeObject test world shared by sync, MCP, and ICS tests. */
export function createScopeWorld(options: CreateScopeWorldOptions = {}) {
  const syncFault = options.syncFault ?? 'none';
  const { d1, db, sqlite, trace } = createTestD1();
  const storage = options.storage ?? createMemoryR2();
  const DoClass = options.scopeClass ?? ScopeClass;
  const scopes = new Map<string, InstanceType<typeof ScopeObject>>();
  const scopeSqlites = new Map<string, ReturnType<typeof createTestDoState>['sqlite']>();
  const physicalNames = new Map<string, string>(Object.entries(options.physicalNames ?? {}));
  const calls: PushCall[] = [];
  const clock = createServerHlcClock();

  const getOrCreateScope = (physical: string): InstanceType<typeof ScopeObject> => {
    let instance = scopes.get(physical);
    if (!instance) {
      const doState = createTestDoState();
      instance = new DoClass(doState.ctx, { SYNC_FAULT: syncFault }) as InstanceType<
        typeof ScopeObject
      >;
      scopes.set(physical, instance);
      scopeSqlites.set(physical, doState.sqlite);
    }
    return instance;
  };

  const getScopeStub = (scope: string): ScopeStub => {
    const physical = physicalNames.get(scope) ?? scope;
    const instance = getOrCreateScope(physical);
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

  const getPhysicalScopeStub = (physical: string): ScopeRelocationStub => {
    const instance = getOrCreateScope(physical);
    return instance as unknown as ScopeRelocationStub;
  };

  const push = (userId: string, deviceId: string, ops: unknown[]) =>
    executeSyncPush(db, { userId, deviceId, ops, getScopeStub, clock, storage });

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

  const sentMail: MailMessage[] = [];
  // Same interface as productionAppDeps: tsc fails here when AppDeps gains or changes a field.
  const deps = {
    db,
    getScopeStub,
    getPhysicalScopeStub,
    getNow: options.getNow ?? systemNow,
    mailer: {
      send: (message: MailMessage) => {
        sentMail.push(message);
        return Promise.resolve({ ok: true as const });
      },
    },
    storage,
  } satisfies AppDeps;

  return {
    d1,
    db,
    sqlite,
    trace,
    clock,
    storage,
    scopes,
    scopeSqlites,
    physicalNames,
    calls,
    getScopeStub,
    getPhysicalScopeStub,
    push,
    pull,
    sentMail,
    deps,
  };
}

export type ScopeWorld = ReturnType<typeof createScopeWorld>;
