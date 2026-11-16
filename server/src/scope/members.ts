import { dbRecordToState, type MembershipRole, type StoredEntityState } from '../sync/entities';
import type { ExpectedProjectMember, ScopeProjectMemberInput } from './api';
import type { ScopeStore } from './store';

export function applyProjectMemberChanges(
  store: ScopeStore,
  nowMs: number,
  changes: ScopeProjectMemberInput[],
  serverTime: string,
): boolean {
  const initialSeq = store.getCounter();
  let currentSeq = initialSeq;

  for (const change of changes) {
    const entityId = `${change.projectId}:${change.memberId}`;
    const existing = store.getRow('projectMember', entityId);
    if (existing && existing.purgedAt !== null) {
      continue;
    }

    if (change.deleted) {
      if (!existing || existing.row.deletedAt !== null) {
        continue;
      }
      currentSeq += 1;
      store.upsertRow('projectMember', entityId, {
        ...existing,
        row: {
          ...existing.row,
          updatedAt: nowMs,
          deletedAt: nowMs,
        },
        clocks: {
          ...existing.clocks,
          updatedAt: serverTime,
          deletedAt: serverTime,
        },
        serverSeq: currentSeq,
      });
    } else {
      if (existing && existing.row.deletedAt === null && existing.row.role === change.role) {
        continue;
      }
      currentSeq += 1;
      if (existing) {
        store.upsertRow('projectMember', entityId, {
          ...existing,
          row: {
            ...existing.row,
            role: change.role,
            updatedAt: nowMs,
            deletedAt: null,
          },
          clocks: {
            ...existing.clocks,
            role: serverTime,
            updatedAt: serverTime,
            deletedAt: serverTime,
          },
          serverSeq: currentSeq,
        });
      } else {
        store.upsertRow('projectMember', entityId, {
          row: {
            projectId: change.projectId,
            memberId: change.memberId,
            role: change.role,
            createdAt: nowMs,
            updatedAt: nowMs,
            deletedAt: null,
          },
          clocks: {
            projectId: serverTime,
            memberId: serverTime,
            role: serverTime,
            createdAt: serverTime,
            updatedAt: serverTime,
            deletedAt: serverTime,
          },
          purgedAt: null,
          serverSeq: currentSeq,
        });
      }
    }
  }

  if (currentSeq !== initialSeq) {
    store.setCounter(currentSeq);
  }
  return currentSeq !== initialSeq;
}

export function projectMemberChanges(
  sql: SqlStorage,
  expectedByProject: Record<string, ExpectedProjectMember[]>,
): ScopeProjectMemberInput[] {
  const projectIds = Object.keys(expectedByProject);
  if (projectIds.length === 0) return [];
  const purgedRows = sql
    .exec(
      'SELECT projectId FROM purgedProject WHERE projectId IN (SELECT value FROM json_each(?))',
      JSON.stringify(projectIds),
    )
    .toArray();
  const purgedSet = new Set(purgedRows.map((r) => String(r.projectId)));

  const existingRows = sql
    .exec(
      'SELECT * FROM projectMember WHERE projectId IN (SELECT value FROM json_each(?))',
      JSON.stringify(projectIds),
    )
    .toArray();
  const existingByProject = new Map<string, Map<string, StoredEntityState>>();
  for (const r of existingRows) {
    const state = dbRecordToState('projectMember', r as Record<string, unknown>);
    const pid = String(state.row.projectId);
    const mid = String(state.row.memberId);
    let map = existingByProject.get(pid);
    if (!map) {
      map = new Map();
      existingByProject.set(pid, map);
    }
    map.set(mid, state);
  }

  const changes: ScopeProjectMemberInput[] = [];
  for (const pid of projectIds) {
    if (purgedSet.has(pid)) continue;
    const expectedList = expectedByProject[pid] ?? [];
    const expectedMap = new Map(expectedList.map((m) => [m.memberId, m.role]));
    const doMap = existingByProject.get(pid) ?? new Map<string, StoredEntityState>();

    for (const [mid, role] of expectedMap) {
      const existing = doMap.get(mid);
      if (existing && existing.purgedAt !== null) continue;
      if (!existing || existing.row.deletedAt !== null || existing.row.role !== role) {
        changes.push({ projectId: pid, memberId: mid, role, deleted: false });
      }
    }
    for (const [mid, existing] of doMap) {
      if (existing.purgedAt === null && existing.row.deletedAt === null && !expectedMap.has(mid)) {
        const existingRole: MembershipRole =
          existing.row.role === 'owner' ||
          existing.row.role === 'editor' ||
          existing.row.role === 'viewer'
            ? existing.row.role
            : 'viewer';
        changes.push({ projectId: pid, memberId: mid, role: existingRole, deleted: true });
      }
    }
  }

  return changes;
}
