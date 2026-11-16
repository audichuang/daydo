import { DurableObject } from 'cloudflare:workers';
import type { CloudBindings } from 'void';
import { defineDurableObject } from 'void/durable';
import {
  dbRecordToState,
  entityIdFromDbRow,
  isEntityName,
  type EntityName,
} from '../src/sync/entities';
import { advanceServerHlc, clampHlc, type Hlc } from '../src/sync/hlc';
import { rowView, type ScopeViewer } from '../src/scope/rowView';
import type {
  ExpectedProjectMember,
  PullScopeRow,
  ScopeProjectInfo,
  ScopeProjectMemberInput,
  ScopePullInput,
  ScopePullResponse,
  ScopePurgeProjectInput,
  ScopePurgeProjectResponse,
  ScopePushInput,
  ScopePushResponse,
} from '../src/scope/api';
import { LIST_SCOPED_ENTITIES, SqliteScopeStore, type ScopeStore } from '../src/scope/store';
import { applyProjectMemberChanges, projectMemberChanges } from '../src/scope/members';
import { processPushBatch } from '../src/scope/push';
import { ensureScopeSchema } from '../src/scope/schema';
import { SplitTxnSnapshotStore } from './dev/splitTxnSnapshotStore';

const CREATOR_ONLY_ENTITIES: readonly EntityName[] = ['member', 'folder', 'tag'];
/** purgeProject answers the list owner deleting it, so the purged project row keeps folderId. */
const PURGE_VIEWER: ScopeViewer = { isScopeOwner: true, meMemberId: null };

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
    if (!Array.isArray(input.readableProjectIds) || input.readableProjectIds.length === 0) {
      return null;
    }
    const rows = this.ctx.storage.sql
      .exec(
        `SELECT id FROM project
         WHERE isInbox = 1
           AND purgedAt IS NULL
           AND deletedAt IS NULL
           AND id IN (SELECT value FROM json_each(?))
         ORDER BY serverSeq ASC
         LIMIT 1`,
        JSON.stringify(input.readableProjectIds),
      )
      .toArray();
    return rows.length > 0 ? String(rows[0].id) : null;
  }

  getProjectInfo(input: { projectId: string }): ScopeProjectInfo | null {
    const rows = this.ctx.storage.sql
      .exec('SELECT name, purgedAt FROM project WHERE id = ?', input.projectId)
      .toArray();
    if (rows.length === 0) return null;
    return {
      name: String(rows[0].name),
      purgedAt: typeof rows[0].purgedAt === 'number' ? rows[0].purgedAt : null,
    };
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

      if (input.opId && input.pusherUserId) {
        const seen = store.getOpApplied(input.opId);
        if (seen && seen.userId === input.pusherUserId && seen.status === 'applied') {
          const projState = store.getRow('project', input.projectId);
          return {
            projectId: input.projectId,
            purgedRow: projState
              ? rowView('project', projState.row, projState.purgedAt, PURGE_VIEWER)
              : null,
            clocks: projState ? { ...projState.clocks } : {},
            serverTime: nextServerHlc.formatted,
          };
        }
      }

      this.ctx.storage.sql.exec(
        'INSERT INTO purgedProject (projectId, purgedAt) VALUES (?, ?) ON CONFLICT (projectId) DO NOTHING',
        input.projectId,
        input.purgedAt,
      );

      const initialSeq = store.getCounter();
      let currentSeq = initialSeq;

      for (const { entity, listCol } of LIST_SCOPED_ENTITIES) {
        const rows = this.ctx.storage.sql
          .exec(
            `SELECT * FROM "${entity}" WHERE "${listCol}" = ? AND purgedAt IS NULL`,
            input.projectId,
          )
          .toArray();
        for (const r of rows) {
          const state = dbRecordToState(entity, r as Record<string, unknown>);
          const eid = entityIdFromDbRow(entity, r as Record<string, unknown>);
          currentSeq += 1;
          store.upsertRow(entity, eid, {
            ...state,
            purgedAt: input.purgedAt,
            serverSeq: currentSeq,
          });
        }
      }

      if (currentSeq !== initialSeq) {
        store.setCounter(currentSeq);
      }

      const projState = store.getRow('project', input.projectId);
      if (input.opId && input.pusherUserId) {
        store.insertOpApplied({
          opId: input.opId,
          userId: input.pusherUserId,
          status: 'applied',
          reason: null,
          serverSeq: projState?.serverSeq ?? currentSeq,
        });
      }

      return {
        projectId: input.projectId,
        purgedRow: projState
          ? rowView('project', projState.row, projState.purgedAt, PURGE_VIEWER)
          : null,
        clocks: projState ? { ...projState.clocks } : {},
        serverTime: nextServerHlc.formatted,
      };
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
    const sql = this.ctx.storage.sql;
    const isBackfill =
      Array.isArray(input.backfillProjectIds) && input.backfillProjectIds.length > 0;
    const visibleProjectIds = isBackfill
      ? input.backfillProjectIds!.filter((pid) => Boolean(input.memberships[pid]))
      : Object.keys(input.memberships);
    const fetchLimit = input.limit + 1;
    const isCreator = input.requesterUserId === input.scopeUserId;
    const combined: PullScopeRow[] = [];

    if (!isBackfill && isCreator) {
      for (const entity of CREATOR_ONLY_ENTITIES) {
        const rows = sql
          .exec(
            `SELECT * FROM "${entity}" WHERE serverSeq > ? ORDER BY serverSeq ASC LIMIT ?`,
            input.since,
            fetchLimit,
          )
          .toArray();
        for (const r of rows) {
          const state = dbRecordToState(entity, r as Record<string, unknown>);
          combined.push({
            entity,
            row: rowView(entity, state.row, state.purgedAt, {
              isScopeOwner: isCreator,
              meMemberId: input.meMemberId,
            }),
            clocks: state.clocks,
            serverSeq: state.serverSeq,
          });
        }
      }
    }

    if (visibleProjectIds.length > 0) {
      const visibleJson = JSON.stringify(visibleProjectIds);
      for (const { entity, listCol } of LIST_SCOPED_ENTITIES) {
        const rows = sql
          .exec(
            `SELECT * FROM "${entity}" WHERE serverSeq > ? AND "${listCol}" IN (SELECT value FROM json_each(?)) ORDER BY serverSeq ASC LIMIT ?`,
            input.since,
            visibleJson,
            fetchLimit,
          )
          .toArray();
        for (const r of rows) {
          const state = dbRecordToState(entity, r as Record<string, unknown>);
          combined.push({
            entity,
            row: rowView(entity, state.row, state.purgedAt, {
              isScopeOwner: isCreator,
              meMemberId: input.meMemberId,
            }),
            clocks: state.clocks,
            serverSeq: state.serverSeq,
          });
        }
      }

      if (!isBackfill) {
        const departures = sql
          .exec(
            `SELECT d.entity, d.entityId, MAX(d.serverSeq) AS serverSeq
             FROM departure d
             WHERE d.serverSeq > ?
               AND d.projectId IN (SELECT value FROM json_each(?))
               AND NOT EXISTS (
                 SELECT 1 FROM task t
                 WHERE d.entity = 'task' AND t.id = d.entityId
                   AND t.projectId IN (SELECT value FROM json_each(?))
               )
               AND NOT EXISTS (
                 SELECT 1 FROM checklistItem c
                 WHERE d.entity = 'checklistItem' AND c.id = d.entityId
                   AND c.projectId IN (SELECT value FROM json_each(?))
               )
               AND NOT EXISTS (
                 SELECT 1 FROM attachment a
                 WHERE d.entity = 'attachment' AND a.id = d.entityId
                   AND a.projectId IN (SELECT value FROM json_each(?))
               )
               AND NOT EXISTS (
                 SELECT 1 FROM comment m
                 WHERE d.entity = 'comment' AND m.id = d.entityId
                   AND m.projectId IN (SELECT value FROM json_each(?))
               )
             GROUP BY d.entity, d.entityId
             ORDER BY serverSeq ASC
             LIMIT ?`,
            input.since,
            visibleJson,
            visibleJson,
            visibleJson,
            visibleJson,
            visibleJson,
            fetchLimit,
          )
          .toArray();
        for (const d of departures) {
          if (isEntityName(d.entity)) {
            combined.push({
              entity: d.entity,
              entityId: String(d.entityId),
              gone: true,
              serverSeq: Number(d.serverSeq),
            });
          }
        }
      }
    }

    combined.sort((a, b) => a.serverSeq - b.serverSeq);
    const hasMore = combined.length > input.limit;
    const rows = hasMore ? combined.slice(0, input.limit) : combined;
    const cursor = rows.length > 0 ? rows[rows.length - 1].serverSeq : input.since;

    return {
      scope: input.scope,
      rows,
      cursor,
      hasMore,
    };
  }
}

export const Scope = defineDurableObject({
  name: 'scope',
  class: ScopeObject,
});

export default Scope;
