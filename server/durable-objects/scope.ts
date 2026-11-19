import { DurableObject } from 'cloudflare:workers';
import type { CloudBindings } from 'void';
import { defineDurableObject } from 'void/durable';
import { advanceServerHlc, clampHlc, type Hlc } from '../src/sync/hlc';
import type * as Api from '../src/scope/api';
import { SqliteScopeStore, type ScopeStore } from '../src/scope/store';
import { applyProjectMemberChanges, projectMemberChanges } from '../src/scope/members';
import { purgeProject } from '../src/scope/purge';
import { getAttachmentInfo, getInboxProjectId, getProjectInfo, pullScope } from '../src/scope/pull';
import { processPushBatch } from '../src/scope/push';
import * as Relocation from '../src/scope/relocation';
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

  async push(input: Api.ScopePushInput): Promise<Api.ScopePushResponse> {
    const sql = this.ctx.storage.sql;
    if (import.meta.env.DEV && shouldSplitTransaction(this.env.SYNC_FAULT, this.allowFaultInjection)) {
      Relocation.assertScopeWritable(sql);
      const snapshotStore = new SplitTxnSnapshotStore(new SqliteScopeStore(sql), input.ops);
      await new Promise((r) => setTimeout(r, 15));
      Relocation.assertScopeWritable(sql);
      return this.processPushBatch(snapshotStore, input);
    }
    return this.ctx.storage.transactionSync(() => {
      Relocation.assertScopeWritable(sql);
      return this.processPushBatch(new SqliteScopeStore(sql), input);
    });
  }

  private processPushBatch(store: ScopeStore, input: Api.ScopePushInput): Api.ScopePushResponse {
    return processPushBatch(store, input, {
      clamp: (hlc, nowMs) => {
        const clamped = clampHlc(hlc, nowMs, this.lastClamped);
        if (clamped.clamped) this.lastClamped = clamped.hlc;
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
    Relocation.assertScopeReadable(this.ctx.storage.sql);
    return getInboxProjectId(this.ctx.storage.sql, input);
  }

  getProjectInfo(input: { projectId: string }): Api.ScopeProjectInfo | null {
    Relocation.assertScopeReadable(this.ctx.storage.sql);
    return getProjectInfo(this.ctx.storage.sql, input);
  }

  getAttachmentInfo(input: { attachmentId: string }): Api.ScopeAttachmentInfo | null {
    Relocation.assertScopeReadable(this.ctx.storage.sql);
    return getAttachmentInfo(this.ctx.storage.sql, input);
  }

  private applyProjectMemberChanges(
    store: ScopeStore,
    nowMs: number,
    changes: Api.ScopeProjectMemberInput[],
  ): void {
    Relocation.assertScopeWritable(this.ctx.storage.sql);
    const serverHlc = advanceServerHlc(nowMs, [], this.lastServerHlc);
    if (applyProjectMemberChanges(store, nowMs, changes, serverHlc.formatted)) {
      this.lastServerHlc = serverHlc.hlc;
    }
  }

  projectMember(input: Api.ScopeProjectMemberInput): void {
    const nowMs = input.nowMs ?? Date.now();
    this.ctx.storage.transactionSync(() => {
      Relocation.assertScopeWritable(this.ctx.storage.sql);
      this.applyProjectMemberChanges(new SqliteScopeStore(this.ctx.storage.sql), nowMs, [input]);
    });
  }

  purgeProject(input: Api.ScopePurgeProjectInput): Api.ScopePurgeProjectResponse {
    return this.ctx.storage.transactionSync(() => {
      const sql = this.ctx.storage.sql;
      Relocation.assertScopeWritable(sql);
      const nextServerHlc = advanceServerHlc(Date.now(), [], this.lastServerHlc);
      this.lastServerHlc = nextServerHlc.hlc;
      return purgeProject(sql, new SqliteScopeStore(sql), input, nextServerHlc.formatted);
    });
  }

  private reconcileProjectMembers(expectedByProject: Record<string, Api.ExpectedProjectMember[]>): void {
    const changes = projectMemberChanges(this.ctx.storage.sql, expectedByProject);
    if (changes.length === 0) return;
    const nowMs = Date.now();
    this.ctx.storage.transactionSync(() => {
      this.applyProjectMemberChanges(new SqliteScopeStore(this.ctx.storage.sql), nowMs, changes);
    });
  }

  pull(input: Api.ScopePullInput): Api.ScopePullResponse {
    const state = Relocation.getRelocationState(this.ctx.storage.sql);
    if (state === 'importing') throw new Relocation.ScopeRelocatingError(state);
    if (state === 'live' && input.expectedProjectMembers) {
      this.reconcileProjectMembers(input.expectedProjectMembers);
    }
    return pullScope(this.ctx.storage.sql, input);
  }

  relocationStatus(): Api.ScopeRelocationStatus {
    return Relocation.getRelocationStatus(this.ctx.storage.sql);
  }

  setRelocationState(input: Api.ScopeSetRelocationStateInput): Api.ScopeSetRelocationStateResponse {
    return this.ctx.storage.transactionSync(() => Relocation.setRelocationState(this.ctx.storage.sql, input));
  }

  exportPage(input: Api.ScopeExportPageInput): Api.ScopeExportPageResponse {
    return Relocation.exportTablePage(this.ctx.storage.sql, input);
  }

  importPage(input: Api.ScopeImportPageInput): Api.ScopeImportPageResponse {
    return this.ctx.storage.transactionSync(() => Relocation.importTablePage(this.ctx.storage.sql, input));
  }

  digest(): Api.ScopeDigest {
    return Relocation.computeScopeDigest(this.ctx.storage.sql);
  }
}

export const Scope = defineDurableObject({
  name: 'scope',
  class: ScopeObject,
});

export default Scope;
