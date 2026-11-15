import {
  attachment,
  checklistItem,
  comment,
  folder,
  member,
  project,
  projectMember,
  task,
  tag,
  user,
} from '@schema';
import { and, asc, eq, gt, inArray, isNull, or, type BatchItem, type DrizzleD1Database } from 'void/db';
import type * as schema from '@schema';
import {
  dbRecordToState,
  ENTITY_NAMES,
  parseEntityId,
  serializePublicRow,
  stateToDbValues,
  type EntityName,
  type StoredEntityState,
} from './entities';

export type AppDb = DrizzleD1Database<typeof schema>;

const QUERY_CHUNK_SIZE = 50;

export function chunkArray<T>(items: readonly T[], size = QUERY_CHUNK_SIZE): T[][] {
  const chunks: T[][] = [];
  for (let i = 0; i < items.length; i += size) {
    chunks.push(items.slice(i, i + size));
  }
  return chunks;
}

export function stateKey(entity: EntityName, entityId: string, userId: string): string {
  return entity === 'tag' ? `tag:${userId}:${entityId}` : `${entity}:${entityId}`;
}

export async function preloadEntities(
  db: AppDb,
  userId: string,
  targets: Array<{ entity: EntityName; entityId: string }>,
): Promise<Map<string, StoredEntityState>> {
  const result = new Map<string, StoredEntityState>();
  const byEntity = new Map<EntityName, Set<string>>();
  for (const { entity, entityId } of targets) {
    let set = byEntity.get(entity);
    if (!set) {
      set = new Set();
      byEntity.set(entity, set);
    }
    set.add(entityId);
  }

  for (const [entity, idSet] of byEntity) {
    const ids = Array.from(idSet);
    if (entity === 'projectMember') {
      const pairs = ids
        .map((id) => parseEntityId('projectMember', id))
        .filter((p): p is { projectId: string; memberId: string } => p !== null);
      for (const chunk of chunkArray(pairs, 25)) {
        const rows = await db
          .select()
          .from(projectMember)
          .where(
            or(
              ...chunk.map((p) =>
                and(
                  eq(projectMember.projectId, p.projectId),
                  eq(projectMember.memberId, p.memberId),
                ),
              ),
            ),
          );
        for (const r of rows) {
          const eid = `${r.projectId}:${r.memberId}`;
          result.set(stateKey('projectMember', eid, userId), dbRecordToState('projectMember', r));
        }
      }
      continue;
    }

    if (entity === 'tag') {
      for (const chunk of chunkArray(ids, QUERY_CHUNK_SIZE)) {
        const rows = await db
          .select()
          .from(tag)
          .where(and(eq(tag.ownerUserId, userId), inArray(tag.name, chunk)));
        for (const r of rows) {
          result.set(stateKey('tag', r.name, userId), dbRecordToState('tag', r));
        }
      }
      continue;
    }

    const table = singleIdTable(entity);
    for (const chunk of chunkArray(ids, QUERY_CHUNK_SIZE)) {
      const rows = await db.select().from(table).where(inArray(table.id, chunk));
      for (const r of rows) {
        result.set(
          stateKey(entity, String(r.id), userId),
          dbRecordToState(entity, r as unknown as Record<string, unknown>),
        );
      }
    }
  }

  return result;
}

function singleIdTable(entity: Exclude<EntityName, 'projectMember' | 'tag'>) {
  switch (entity) {
    case 'member':
      return member;
    case 'folder':
      return folder;
    case 'project':
      return project;
    case 'task':
      return task;
    case 'checklistItem':
      return checklistItem;
    case 'attachment':
      return attachment;
    case 'comment':
      return comment;
  }
}

export function buildUpsertStatement(
  db: AppDb,
  entity: EntityName,
  state: StoredEntityState,
): BatchItem<'sqlite'> {
  const vals = stateToDbValues(entity, state);

  if (entity === 'projectMember') {
    const { projectId: _p, memberId: _m, ...updateSet } = vals;
    return db
      .insert(projectMember)
      .values(vals as typeof projectMember.$inferInsert)
      .onConflictDoUpdate({
        target: [projectMember.projectId, projectMember.memberId],
        set: updateSet as Partial<typeof projectMember.$inferInsert>,
      });
  }

  if (entity === 'tag') {
    const { ownerUserId: _u, name: _n, ...updateSet } = vals;
    return db
      .insert(tag)
      .values(vals as typeof tag.$inferInsert)
      .onConflictDoUpdate({
        target: [tag.ownerUserId, tag.name],
        set: updateSet as Partial<typeof tag.$inferInsert>,
      });
  }

  const table = singleIdTable(entity);
  const { id: _id, ...updateSet } = vals;
  // All single-ID entity tables share the same `id` primary key shape.
  return db
    .insert(table as typeof task)
    .values(vals as typeof task.$inferInsert)
    .onConflictDoUpdate({
      target: table.id,
      set: updateSet as Partial<typeof task.$inferInsert>,
    });
}

export async function findActiveTaskChildren(
  db: AppDb,
  userId: string,
  taskId: string,
): Promise<Array<{ entity: 'checklistItem' | 'attachment' | 'comment'; entityId: string; state: StoredEntityState }>> {
  const [items, attachments, comments] = await db.batch([
    db
      .select()
      .from(checklistItem)
      .where(
        and(
          eq(checklistItem.ownerUserId, userId),
          eq(checklistItem.taskId, taskId),
          isNull(checklistItem.purgedAt),
        ),
      ),
    db
      .select()
      .from(attachment)
      .where(
        and(
          eq(attachment.ownerUserId, userId),
          eq(attachment.taskId, taskId),
          isNull(attachment.purgedAt),
        ),
      ),
    db
      .select()
      .from(comment)
      .where(
        and(
          eq(comment.ownerUserId, userId),
          eq(comment.taskId, taskId),
          isNull(comment.purgedAt),
        ),
      ),
  ]);

  const out: Array<{
    entity: 'checklistItem' | 'attachment' | 'comment';
    entityId: string;
    state: StoredEntityState;
  }> = [];

  for (const r of items) {
    out.push({ entity: 'checklistItem', entityId: r.id, state: dbRecordToState('checklistItem', r) });
  }
  for (const r of attachments) {
    out.push({ entity: 'attachment', entityId: r.id, state: dbRecordToState('attachment', r) });
  }
  for (const r of comments) {
    out.push({ entity: 'comment', entityId: r.id, state: dbRecordToState('comment', r) });
  }
  return out;
}

export interface PullRowItem {
  entity: EntityName;
  row: Record<string, unknown>;
  clocks: Record<string, string>;
  serverSeq: number;
}

export async function pullUserRows(
  db: AppDb,
  params: {
    userId: string;
    since: number;
    limit: number;
    projectId?: string;
  },
): Promise<{ rows: PullRowItem[]; cursor: number; hasMore: boolean }> {
  const { userId, since, limit, projectId } = params;
  const fetchLimit = limit + 1;

  const queries: Array<{ entity: EntityName; query: BatchItem<'sqlite'> }> = [];

  if (projectId) {
    const projectTaskIds = db
      .select({ id: task.id })
      .from(task)
      .where(and(eq(task.ownerUserId, userId), eq(task.projectId, projectId)));

    queries.push(
      {
        entity: 'project',
        query: db
          .select()
          .from(project)
          .where(
            and(
              eq(project.ownerUserId, userId),
              eq(project.id, projectId),
              gt(project.serverSeq, since),
            ),
          )
          .orderBy(asc(project.serverSeq))
          .limit(fetchLimit),
      },
      {
        entity: 'projectMember',
        query: db
          .select()
          .from(projectMember)
          .where(
            and(
              eq(projectMember.ownerUserId, userId),
              eq(projectMember.projectId, projectId),
              gt(projectMember.serverSeq, since),
            ),
          )
          .orderBy(asc(projectMember.serverSeq))
          .limit(fetchLimit),
      },
      {
        entity: 'task',
        query: db
          .select()
          .from(task)
          .where(
            and(
              eq(task.ownerUserId, userId),
              eq(task.projectId, projectId),
              gt(task.serverSeq, since),
            ),
          )
          .orderBy(asc(task.serverSeq))
          .limit(fetchLimit),
      },
      {
        entity: 'checklistItem',
        query: db
          .select()
          .from(checklistItem)
          .where(
            and(
              eq(checklistItem.ownerUserId, userId),
              gt(checklistItem.serverSeq, since),
              inArray(checklistItem.taskId, projectTaskIds),
            ),
          )
          .orderBy(asc(checklistItem.serverSeq))
          .limit(fetchLimit),
      },
      {
        entity: 'attachment',
        query: db
          .select()
          .from(attachment)
          .where(
            and(
              eq(attachment.ownerUserId, userId),
              gt(attachment.serverSeq, since),
              inArray(attachment.taskId, projectTaskIds),
            ),
          )
          .orderBy(asc(attachment.serverSeq))
          .limit(fetchLimit),
      },
      {
        entity: 'comment',
        query: db
          .select()
          .from(comment)
          .where(
            and(
              eq(comment.ownerUserId, userId),
              gt(comment.serverSeq, since),
              inArray(comment.taskId, projectTaskIds),
            ),
          )
          .orderBy(asc(comment.serverSeq))
          .limit(fetchLimit),
      },
    );
  } else {
    const allTables = {
      member,
      folder,
      project,
      projectMember,
      task,
      checklistItem,
      tag,
      attachment,
      comment,
    };
    for (const entity of ENTITY_NAMES) {
      const table = allTables[entity];
      queries.push({
        entity,
        query: db
          .select()
          .from(table)
          .where(and(eq(table.ownerUserId, userId), gt(table.serverSeq, since)))
          .orderBy(asc(table.serverSeq))
          .limit(fetchLimit),
      });
    }
  }

  const batchItems: BatchItem<'sqlite'>[] = queries.map((q) => q.query);
  let meUserQueryIdx: number | null = null;
  if (!projectId) {
    meUserQueryIdx = batchItems.length;
    batchItems.push(
      db.select({ meMemberId: user.meMemberId }).from(user).where(eq(user.id, userId)),
    );
  }

  const batchResults = (await db.batch(
    batchItems as [BatchItem<'sqlite'>, ...BatchItem<'sqlite'>[]],
  )) as Array<Array<Record<string, unknown>>>;

  let meMemberId: string | null = null;
  if (meUserQueryIdx !== null) {
    const meRow = batchResults[meUserQueryIdx]?.[0];
    if (meRow && typeof meRow.meMemberId === 'string') {
      meMemberId = meRow.meMemberId;
    }
  }

  const combined: PullRowItem[] = [];
  for (let i = 0; i < queries.length; i++) {
    const entity = queries[i].entity;
    for (const record of batchResults[i]) {
      const state = dbRecordToState(entity, record);
      combined.push({
        entity,
        row: serializePublicRow(entity, state.row, state.purgedAt, { meMemberId }),
        clocks: state.clocks,
        serverSeq: state.serverSeq,
      });
    }
  }

  combined.sort((a, b) => a.serverSeq - b.serverSeq);
  const hasMore = combined.length > limit;
  const rows = hasMore ? combined.slice(0, limit) : combined;
  const cursor = rows.length > 0 ? rows[rows.length - 1].serverSeq : since;

  return { rows, cursor, hasMore };
}
