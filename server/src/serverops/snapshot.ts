import { user } from '@schema';
import { eq } from 'void/db';
import type { PullScopeRow, ScopeStub } from '../scope/api';
import { listWriteDenial } from '../sync/access';
import type { MembershipRole } from '../sync/entities';
import { executeSyncPull } from '../sync/pull';
import type { AppDb } from '../sync/push';
import { userScope } from '../sync/scopeName';
import type { WriteOutcome } from './writer';

const PULL_LIMIT = 1000;
const NO_PURGED: ReadonlySet<string> = new Set();
/** Safety valve: a scope that keeps reporting hasMore without advancing its cursor is a bug. */
const MAX_PAGES = 1000;

type EntityName = Extract<PullScopeRow, { row: unknown }>['entity'];

export interface SnapshotRow {
  entity: EntityName;
  scope: string;
  row: Record<string, unknown>;
  clocks: Record<string, string>;
  serverSeq: number;
}

export interface Snapshot {
  userId: string;
  meMemberId: string | null;
  inboxProjectId: string | null;
  memberships: Map<string, MembershipRole>;
  /** Raw rows, including trashed (deletedAt) and tombstones (purgedAt); `gone` rows are dropped. */
  rows(entity: EntityName): SnapshotRow[];
  findRow(entity: EntityName, id: string): SnapshotRow | undefined;
  liveProjects(): SnapshotRow[];
  liveTasks(): SnapshotRow[];
  canWrite(projectId: string): boolean;
}

function isAbsent(row: Record<string, unknown>, ...fields: string[]): boolean {
  return fields.every((f) => row[f] === undefined || row[f] === null);
}

export async function loadSnapshot(
  db: AppDb,
  userId: string,
  getScopeStub: (scope: string) => Pick<ScopeStub, 'pull' | 'purgeProject'>,
): Promise<Snapshot> {
  const byEntity = new Map<EntityName, Map<string, SnapshotRow>>();
  const cursors: Record<string, number> = {};
  const memberships = new Map<string, MembershipRole>();
  const inProgress = new Set<string>();

  for (let page = 0; page < MAX_PAGES; page += 1) {
    const res = await executeSyncPull(db, {
      userId,
      cursors,
      limit: PULL_LIMIT,
      getScopeStub,
    });
    if (page === 0) {
      for (const m of res.memberships) memberships.set(m.projectId, m.role);
    }
    inProgress.clear();
    for (const s of res.scopes) {
      for (const r of s.rows) {
        let bucket = byEntity.get(r.entity);
        if (!bucket) {
          bucket = new Map();
          byEntity.set(r.entity, bucket);
        }
        if ('gone' in r) {
          bucket.delete(r.entityId);
          continue;
        }
        // Tags are keyed by name; every other entity by id.
        const id = String(r.entity === 'tag' ? r.row.name : r.row.id);
        bucket.set(id, {
          entity: r.entity,
          scope: s.scope,
          row: r.row,
          clocks: r.clocks,
          serverSeq: r.serverSeq,
        });
      }
      cursors[s.scope] = s.cursor;
      if (s.hasMore) inProgress.add(s.scope);
    }
    if (inProgress.size === 0) break;
    if (page === MAX_PAGES - 1) throw new Error('snapshot pagination did not converge');
  }

  const userRows = (await db
    .select({ meMemberId: user.meMemberId })
    .from(user)
    .where(eq(user.id, userId))) as Array<{ meMemberId: string | null }>;
  const meMemberId =
    userRows[0] && typeof userRows[0].meMemberId === 'string' ? userRows[0].meMemberId : null;

  const ownScope = userScope(userId);
  // Same definition as the Scope DO's getInboxProjectId (login/refresh): own scope, isInbox, not
  // trashed or purged, lowest serverSeq when there are several.
  let inboxSeq = Infinity;
  let inboxProjectId: string | null = null;
  for (const p of byEntity.get('project')?.values() ?? []) {
    if (
      p.scope === ownScope &&
      p.row.isInbox === true &&
      isAbsent(p.row, 'deletedAt', 'purgedAt') &&
      p.serverSeq < inboxSeq
    ) {
      inboxSeq = p.serverSeq;
      inboxProjectId = String(p.row.id);
    }
  }

  const rows = (entity: EntityName) => [...(byEntity.get(entity)?.values() ?? [])];
  const findRow = (entity: EntityName, id: string) => byEntity.get(entity)?.get(id);
  const liveProjects = () =>
    rows('project').filter((p) => isAbsent(p.row, 'deletedAt', 'archivedAt', 'purgedAt'));

  return {
    userId,
    meMemberId,
    inboxProjectId,
    memberships,
    rows,
    findRow,
    liveProjects,
    liveTasks() {
      const live = new Set(liveProjects().map((p) => String(p.row.id)));
      return rows('task').filter(
        (t) => isAbsent(t.row, 'deletedAt', 'purgedAt') && live.has(String(t.row.projectId)),
      );
    },
    canWrite(projectId: string) {
      // Pulls never return purged lists' memberships, so the role decides; the Scope DO re-checks.
      return listWriteDenial(projectId, { memberships, purgedSet: NO_PURGED }) === null;
    },
  };
}

/** The snapshot plus rows created by a write, so a result can show new tasks and checklist items. */
export function withCreated(snapshot: Snapshot, outcomes: readonly WriteOutcome[]): Snapshot {
  const created: SnapshotRow[] = outcomes
    .filter((o) => o.row && !snapshot.findRow(o.entity, o.entityId))
    .map((o) => ({ entity: o.entity, scope: '', row: o.row!, clocks: o.clocks, serverSeq: 0 }));
  const keyOf = (r: SnapshotRow) => String(r.entity === 'tag' ? r.row.name : r.row.id);
  return {
    ...snapshot,
    rows: (entity) => [...snapshot.rows(entity), ...created.filter((r) => r.entity === entity)],
    findRow: (entity, id) => snapshot.findRow(entity, id) ?? created.find((r) => r.entity === entity && keyOf(r) === id),
  };
}
