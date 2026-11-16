import { DurableObject } from 'cloudflare:workers';
import type { CloudBindings } from 'void';
import { defineDurableObject } from 'void/durable';
import { advanceServerHlc, clampHlc, type Hlc } from '../src/sync/hlc';
import type {
  ExpectedProjectMember,
  ScopeProjectInfo,
  ScopeProjectMemberInput,
  ScopePullInput,
  ScopePullResponse,
  ScopePurgeProjectInput,
  ScopePurgeProjectResponse,
  ScopePushInput,
  ScopePushResponse,
} from '../src/scope/api';
import { SqliteScopeStore, type ScopeStore } from '../src/scope/store';
import { applyProjectMemberChanges, projectMemberChanges } from '../src/scope/members';
import { purgeProject } from '../src/scope/purge';
import { getInboxProjectId, getProjectInfo, pullScope } from '../src/scope/pull';
import { processPushBatch } from '../src/scope/push';
import { ensureScopeSchema } from '../src/scope/schema';
import { SplitTxnSnapshotStore } from './dev/splitTxnSnapshotStore';

export function shouldSplitTransaction(
  syncFault: string | undefined,
  isDev: boolean = import.meta.env.DEV,
): boolean {
  return isDev && syncFault === 'split-txn';
}

export class ScopeObject extends DurableObject<CloudBindings> {
  private lastClamped: Hlc | null = null;
  private lastServerHlc: Hlc | null = null;
  private readonly allowFaultInjection: boolean;

  constructor(
    ctx: DurableObjectState,
    env: CloudBindings,
    allowFaultInjection: boolean = import.meta.env.DEV,
  ) {
    super(ctx, env);
    this.allowFaultInjection = allowFaultInjection;
    ensureScopeSchema(this.ctx.storage.sql);
  }

  async push(input: ScopePushInput): Promise<ScopePushResponse> {
    if (
      import.meta.env.DEV &&
      shouldSplitTransaction(this.env.SYNC_FAULT, this.allowFaultInjection)
    ) {
      const backing = new SqliteScopeStore(this.ctx.storage.sql);
      const snapshotStore = new SplitTxnSnapshotStore(backing, input.ops);
      await new Promise((r) => setTimeout(r, 15));
      return this.processPushBatch(snapshotStore, input);
    }

    return this.ctx.storage.transactionSync(() => {
      const store = new SqliteScopeStore(this.ctx.storage.sql);
      return this.processPushBatch(store, input);
    });
  }

  private processPushBatch(store: ScopeStore, input: ScopePushInput): ScopePushResponse {
    return processPushBatch(store, input, {
      clamp: (hlc, nowMs) => {
        const clamped = clampHlc(hlc, nowMs, this.lastClamped);
        if (clamped.clamped) {
          this.lastClamped = clamped.hlc;
        }
        return clamped;
      },
      tick: (nowMs, observed) => {
        const next = advanceServerHlc(nowMs, observed, this.lastServerHlc);
        this.lastServerHlc = next.hlc;
        return next.formatted;
      },
    });
  }

  getInboxProjectId(input: { readableProjectIds: string[] }): string | null {
    return getInboxProjectId(this.ctx.storage.sql, input);
  }

  getProjectInfo(input: { projectId: string }): ScopeProjectInfo | null {
    return getProjectInfo(this.ctx.storage.sql, input);
  }

  private applyProjectMemberChanges(
    store: ScopeStore,
    nowMs: number,
    changes: ScopeProjectMemberInput[],
  ): void {
    const serverHlc = advanceServerHlc(nowMs, [], this.lastServerHlc);
    if (applyProjectMemberChanges(store, nowMs, changes, serverHlc.formatted)) {
      this.lastServerHlc = serverHlc.hlc;
    }
  }

  projectMember(input: ScopeProjectMemberInput): void {
    const nowMs = input.nowMs ?? Date.now();
    this.ctx.storage.transactionSync(() => {
      const store = new SqliteScopeStore(this.ctx.storage.sql);
      this.applyProjectMemberChanges(store, nowMs, [input]);
    });
  }

  purgeProject(input: ScopePurgeProjectInput): ScopePurgeProjectResponse {
    return this.ctx.storage.transactionSync(() => {
      const store = new SqliteScopeStore(this.ctx.storage.sql);
      const nowMs = Date.now();
      const nextServerHlc = advanceServerHlc(nowMs, [], this.lastServerHlc);
      this.lastServerHlc = nextServerHlc.hlc;
      return purgeProject(this.ctx.storage.sql, store, input, nextServerHlc.formatted);
    });
  }

  private reconcileProjectMembers(
    expectedByProject: Record<string, ExpectedProjectMember[]>,
  ): void {
    const changes = projectMemberChanges(this.ctx.storage.sql, expectedByProject);
    if (changes.length === 0) return;
    const nowMs = Date.now();
    this.ctx.storage.transactionSync(() => {
      const store = new SqliteScopeStore(this.ctx.storage.sql);
      this.applyProjectMemberChanges(store, nowMs, changes);
    });
  }

  pull(input: ScopePullInput): ScopePullResponse {
    if (input.expectedProjectMembers) {
      this.reconcileProjectMembers(input.expectedProjectMembers);
    }
    return pullScope(this.ctx.storage.sql, input);
  }
}

export const Scope = defineDurableObject({
  name: 'scope',
  class: ScopeObject,
});

export default Scope;
