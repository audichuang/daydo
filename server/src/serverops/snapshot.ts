import { user } from '@schema';
import { eq } from 'void/db';
import type { PullScopeRow } from '../../durable-objects/scope';
import type { MembershipRole } from '../sync/entities';
import { executeSyncPull } from '../sync/pull';
import type { AppDb, ScopeStub } from '../sync/push';

const PULL_LIMIT = 1000;
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

  const ownScope = `u:${userId}`;
  let inboxProjectId: string | null = null;
  for (const p of byEntity.get('project')?.values() ?? []) {
    if (p.scope === ownScope && p.row.isInbox === true && isAbsent(p.row, 'purgedAt')) {
      inboxProjectId = String(p.row.id);
      break;
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
      const role = memberships.get(projectId);
      return role === 'owner' || role === 'editor';
    },
  };
}
