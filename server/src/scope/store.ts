import type { OwnerOnlyEntity } from '../sync/access';
import {
  dbRecordToState,
  ENTITY_FIELDS,
  ENTITY_NAMES,
  isTaskChildEntity,
  parseEntityId,
  stateToDbValues,
  type EntityName,
  type StoredEntityState,
} from '../sync/entities';

export interface OpAppliedRow {
  opId: string;
  userId: string;
  status: 'applied' | 'rejected';
  reason: string | null;
  serverSeq: number;
}

export type TaskChildEntity = 'checklistItem' | 'attachment' | 'comment';
const CHILD_ENTITIES: readonly TaskChildEntity[] = ['checklistItem', 'attachment', 'comment'];
export const LIST_SCOPED_ENTITIES: ReadonlyArray<{
  entity: Exclude<EntityName, OwnerOnlyEntity>;
  listCol: 'id' | 'projectId';
}> = [
  { entity: 'project', listCol: 'id' },
  { entity: 'projectMember', listCol: 'projectId' },
  { entity: 'projectInvite', listCol: 'projectId' },
  { entity: 'task', listCol: 'projectId' },
  { entity: 'checklistItem', listCol: 'projectId' },
  { entity: 'attachment', listCol: 'projectId' },
  { entity: 'comment', listCol: 'projectId' },
];

function tableColumnsFor(entity: EntityName): string[] {
  const cols = Object.keys(ENTITY_FIELDS[entity]);
  if (isTaskChildEntity(entity)) {
    cols.push('projectId');
  }
  cols.push('clocks', 'serverSeq', 'purgedAt');
  return cols;
}

const TABLE_COLUMNS: Record<EntityName, string[]> = Object.fromEntries(
  ENTITY_NAMES.map((entity) => [entity, tableColumnsFor(entity)]),
) as Record<EntityName, string[]>;

function primaryKeyColumnsFor(entity: EntityName): string[] {
  if (entity === 'projectMember') return ['projectId', 'memberId'];
  if (entity === 'tag') return ['name'];
  return ['id'];
}

export interface ScopeStore {
  getCounter(): number;
  setCounter(value: number): void;
  getPurgedProjects(): string[];
  getOpApplied(opId: string): OpAppliedRow | null;
  insertOpApplied(entry: OpAppliedRow): void;
  getRow(entity: EntityName, entityId: string): StoredEntityState | null;
  upsertRow(entity: EntityName, entityId: string, state: StoredEntityState): void;
  findActiveTaskChildren(
    taskId: string,
  ): Array<{ entity: TaskChildEntity; entityId: string; state: StoredEntityState }>;
  upsertDeparture(entry: {
    entity: EntityName;
    entityId: string;
    projectId: string;
    serverSeq: number;
  }): void;
}

export class SqliteScopeStore implements ScopeStore {
  constructor(private readonly sql: SqlStorage) {}

  getCounter(): number {
    const rows = this.sql.exec('SELECT value FROM counter WHERE id = 1').toArray();
    if (rows.length === 0) return 0;
    return Number(rows[0].value);
  }

  setCounter(value: number): void {
    this.sql.exec(
      'INSERT INTO counter (id, value) VALUES (1, ?) ON CONFLICT (id) DO UPDATE SET value = excluded.value',
      value,
    );
  }

  getPurgedProjects(): string[] {
    return this.sql
      .exec('SELECT projectId FROM purgedProject')
      .toArray()
      .map((r) => String(r.projectId));
  }

  getOpApplied(opId: string): OpAppliedRow | null {
    const rows = this.sql
      .exec('SELECT opId, userId, status, reason, serverSeq FROM opApplied WHERE opId = ?', opId)
      .toArray();
    if (rows.length === 0) return null;
    const r = rows[0];
    return {
      opId: String(r.opId),
      userId: String(r.userId),
      status: r.status === 'rejected' ? 'rejected' : 'applied',
      reason: typeof r.reason === 'string' ? r.reason : null,
      serverSeq: Number(r.serverSeq),
    };
  }

  insertOpApplied(entry: OpAppliedRow): void {
    this.sql.exec(
      'INSERT INTO opApplied (opId, userId, status, reason, serverSeq) VALUES (?, ?, ?, ?, ?) ON CONFLICT (opId) DO NOTHING',
      entry.opId,
      entry.userId,
      entry.status,
      entry.reason,
      entry.serverSeq,
    );
  }

  getRow(entity: EntityName, entityId: string): StoredEntityState | null {
    const parsed = parseEntityId(entity, entityId);
    if (!parsed) return null;
    let rows: Array<Record<string, SqlStorageValue>>;
    if (entity === 'projectMember') {
      rows = this.sql
        .exec(
          'SELECT * FROM projectMember WHERE projectId = ? AND memberId = ?',
          parsed.projectId,
          parsed.memberId,
        )
        .toArray();
    } else if (entity === 'tag') {
      rows = this.sql.exec('SELECT * FROM tag WHERE name = ?', parsed.name).toArray();
    } else {
      rows = this.sql.exec(`SELECT * FROM "${entity}" WHERE id = ?`, parsed.id).toArray();
    }
    if (rows.length === 0) return null;
    return dbRecordToState(entity, rows[0] as Record<string, unknown>);
  }

  upsertRow(entity: EntityName, _entityId: string, state: StoredEntityState): void {
    const cols = TABLE_COLUMNS[entity];
    const pkCols = primaryKeyColumnsFor(entity);
    const pkSet = new Set(pkCols);
    const vals = stateToDbValues(entity, state);
    const params = cols.map((col) => (vals[col] === undefined ? null : vals[col]) as SqlStorageValue);
    const placeholders = cols.map(() => '?').join(', ');
    const updateCols = cols
      .filter((col) => !pkSet.has(col))
      .map((col) => `"${col}" = excluded."${col}"`)
      .join(', ');
    const sqlText = `INSERT INTO "${entity}" (${cols.map((c) => `"${c}"`).join(', ')}) VALUES (${placeholders}) ON CONFLICT (${pkCols.join(', ')}) DO UPDATE SET ${updateCols}`;
    this.sql.exec(sqlText, ...params);
  }

  findActiveTaskChildren(
    taskId: string,
  ): Array<{ entity: TaskChildEntity; entityId: string; state: StoredEntityState }> {
    const out: Array<{ entity: TaskChildEntity; entityId: string; state: StoredEntityState }> = [];
    for (const childEntity of CHILD_ENTITIES) {
      const rows = this.sql
        .exec(`SELECT * FROM "${childEntity}" WHERE taskId = ? AND purgedAt IS NULL`, taskId)
        .toArray();
      for (const r of rows) {
        out.push({
          entity: childEntity,
          entityId: String(r.id),
          state: dbRecordToState(childEntity, r as Record<string, unknown>),
        });
      }
    }
    return out;
  }

  upsertDeparture(entry: {
    entity: EntityName;
    entityId: string;
    projectId: string;
    serverSeq: number;
  }): void {
    this.sql.exec(
      'INSERT INTO departure (entity, entityId, projectId, serverSeq) VALUES (?, ?, ?, ?) ON CONFLICT (entity, entityId, projectId) DO UPDATE SET serverSeq = excluded.serverSeq',
      entry.entity,
      entry.entityId,
      entry.projectId,
      entry.serverSeq,
    );
  }
}
