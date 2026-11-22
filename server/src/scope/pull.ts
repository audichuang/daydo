import { canRead, childListId, OWNER_ONLY_ENTITIES } from '../sync/access';
import { dbRecordToState, isEntityName } from '../sync/entities';
import type {
  PullScopeRow,
  ScopeAttachmentInfo,
  ScopeProjectInfo,
  ScopePullInput,
  ScopePullResponse,
} from './api';
import { rowView } from './rowView';
import { LIST_SCOPED_ENTITIES } from './store';

export function getInboxProjectId(sql: SqlStorage, input: { readableProjectIds: string[] }): string | null {
  if (!Array.isArray(input.readableProjectIds) || input.readableProjectIds.length === 0) {
    return null;
  }
  const rows = sql
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

export function getProjectInfo(sql: SqlStorage, input: { projectId: string }): ScopeProjectInfo | null {
  const rows = sql
    .exec('SELECT name, purgedAt FROM project WHERE id = ?', input.projectId)
    .toArray();
  if (rows.length === 0) return null;
  return {
    name: String(rows[0].name),
    purgedAt: typeof rows[0].purgedAt === 'number' ? rows[0].purgedAt : null,
  };
}

export function getAttachmentInfo(
  sql: SqlStorage,
  input: { attachmentId: string },
): ScopeAttachmentInfo | null {
  const rows = sql
    .exec(
      `SELECT a.id, a.taskId, a.size, a.mimeType, a.projectId AS attachmentProjectId,
              a.deletedAt, a.purgedAt,
              t.projectId AS taskProjectId, t.purgedAt AS taskPurgedAt
       FROM attachment a
       LEFT JOIN task t ON t.id = a.taskId
       WHERE a.id = ?`,
      input.attachmentId,
    )
    .toArray();
  if (rows.length === 0) return null;
  const r = rows[0];
  const taskProjectId =
    typeof r.taskProjectId === 'string' && r.taskProjectId.length > 0 ? r.taskProjectId : null;
  const attachmentProjectId =
    typeof r.attachmentProjectId === 'string' ? r.attachmentProjectId : null;
  return {
    id: String(r.id),
    taskId: String(r.taskId),
    projectId: childListId(taskProjectId, attachmentProjectId),
    size: Number(r.size),
    mimeType: typeof r.mimeType === 'string' ? r.mimeType : '',
    deletedAt: typeof r.deletedAt === 'number' ? r.deletedAt : null,
    purgedAt: typeof r.purgedAt === 'number' ? r.purgedAt : null,
    taskPurgedAt: typeof r.taskPurgedAt === 'number' ? r.taskPurgedAt : null,
  };
}

/**
 * Budget for one page, in JSON characters. The page goes back over Workers RPC (32 MiB per
 * message) and row content has no length cap, so a page also ends early when its rows get
 * large; a UTF-16 serialization of 8M characters stays near 16 MB.
 */
export const MAX_PULL_PAGE_CHARS = 8_000_000;

/** Rows to return: at most `limit`, and stop before the budget is exceeded (always at least one). */
function pageEnd(sorted: readonly PullScopeRow[], limit: number): number {
  const max = Math.min(sorted.length, limit);
  let chars = 0;
  for (let i = 0; i < max; i += 1) {
    chars += JSON.stringify(sorted[i]).length;
    if (chars > MAX_PULL_PAGE_CHARS && i > 0) return i;
  }
  return max;
}

export function pullScope(sql: SqlStorage, input: ScopePullInput): ScopePullResponse {
  const isBackfill =
    Array.isArray(input.backfillProjectIds) && input.backfillProjectIds.length > 0;
  const visibleProjectIds = isBackfill
    ? input.backfillProjectIds!.filter((pid) => canRead(input.memberships, pid))
    : Object.keys(input.memberships);
  const fetchLimit = input.limit + 1;
  const isCreator = input.requesterUserId === input.scopeUserId;
  const combined: PullScopeRow[] = [];

  if (!isBackfill && isCreator) {
    for (const entity of OWNER_ONLY_ENTITIES) {
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
  const end = pageEnd(combined, input.limit);
  const hasMore = combined.length > end;
  const rows = hasMore ? combined.slice(0, end) : combined;
  const cursor = rows.length > 0 ? rows[rows.length - 1].serverSeq : input.since;

  return {
    scope: input.scope,
    rows,
    cursor,
    hasMore,
  };
}
