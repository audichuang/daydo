import { dbRecordToState, entityIdFromDbRow } from '../sync/entities';
import type { ScopePurgeProjectInput, ScopePurgeProjectResponse } from './api';
import { rowView, type ScopeViewer } from './rowView';
import { LIST_SCOPED_ENTITIES, type ScopeStore } from './store';

/** purgeProject answers the list owner deleting it, so the purged project row keeps folderId. */
const PURGE_VIEWER: ScopeViewer = { isScopeOwner: true, meMemberId: null };

export function purgeProject(
  sql: SqlStorage,
  store: ScopeStore,
  input: ScopePurgeProjectInput,
  serverTime: string,
): ScopePurgeProjectResponse {
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
        serverTime: serverTime,
      };
    }
  }

  sql.exec(
    'INSERT INTO purgedProject (projectId, purgedAt) VALUES (?, ?) ON CONFLICT (projectId) DO NOTHING',
    input.projectId,
    input.purgedAt,
  );

  const initialSeq = store.getCounter();
  let currentSeq = initialSeq;

  for (const { entity, listCol } of LIST_SCOPED_ENTITIES) {
    const rows = sql
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
    serverTime: serverTime,
  };
}
