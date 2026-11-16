import {
  isEntityName,
  isTaskChildEntity,
  type EntityName,
  type StoredEntityState,
} from '../../src/sync/entities';
import type { OpAppliedRow, ScopeStore, TaskChildEntity } from '../../src/scope/store';

/**
 * Dev-only fault-injection store that snapshots counter, opApplied, and existing rows
 * before yielding at an `await`, simulating the race condition of a split read/write transaction.
 */
export class SplitTxnSnapshotStore implements ScopeStore {
  private counterValue: number;
  private readonly purgedProjectsSnapshot: string[];
  private readonly opAppliedMap = new Map<string, OpAppliedRow>();
  private readonly rowMap = new Map<string, StoredEntityState | null>();
  private readonly childrenMap = new Map<
    string,
    Array<{ entity: TaskChildEntity; entityId: string; state: StoredEntityState }>
  >();

  constructor(
    private readonly backing: ScopeStore,
    ops: readonly unknown[],
  ) {
    this.counterValue = backing.getCounter();
    this.purgedProjectsSnapshot = backing.getPurgedProjects();
    for (const raw of ops) {
      if (!raw || typeof raw !== 'object' || Array.isArray(raw)) continue;
      const rec = raw as Record<string, unknown>;
      if (typeof rec.opId === 'string' && rec.opId.length > 0 && !this.opAppliedMap.has(rec.opId)) {
        const existingOp = backing.getOpApplied(rec.opId);
        if (existingOp) this.opAppliedMap.set(rec.opId, existingOp);
      }
      if (isEntityName(rec.entity) && typeof rec.entityId === 'string') {
        const key = `${rec.entity}:${rec.entityId}`;
        if (!this.rowMap.has(key)) {
          this.rowMap.set(key, backing.getRow(rec.entity, rec.entityId));
        }
        if (rec.entity === 'task' && !this.childrenMap.has(rec.entityId)) {
          this.childrenMap.set(rec.entityId, backing.findActiveTaskChildren(rec.entityId));
        }
        if (
          isTaskChildEntity(rec.entity) &&
          rec.row &&
          typeof rec.row === 'object' &&
          !Array.isArray(rec.row) &&
          Object.hasOwn(rec.row, 'taskId')
        ) {
          const tid = (rec.row as Record<string, unknown>).taskId;
          if (typeof tid === 'string' && !this.rowMap.has(`task:${tid}`)) {
            this.rowMap.set(`task:${tid}`, backing.getRow('task', tid));
          }
        }
      }
    }
  }

  getCounter(): number {
    return this.counterValue;
  }

  setCounter(value: number): void {
    this.counterValue = value;
    this.backing.setCounter(value);
  }

  getPurgedProjects(): string[] {
    return this.purgedProjectsSnapshot;
  }

  getOpApplied(opId: string): OpAppliedRow | null {
    return this.opAppliedMap.get(opId) ?? null;
  }

  insertOpApplied(entry: OpAppliedRow): void {
    this.opAppliedMap.set(entry.opId, entry);
    this.backing.insertOpApplied(entry);
  }

  getRow(entity: EntityName, entityId: string): StoredEntityState | null {
    const key = `${entity}:${entityId}`;
    if (this.rowMap.has(key)) return this.rowMap.get(key) ?? null;
    const loaded = this.backing.getRow(entity, entityId);
    this.rowMap.set(key, loaded);
    return loaded;
  }

  upsertRow(entity: EntityName, entityId: string, state: StoredEntityState): void {
    this.rowMap.set(`${entity}:${entityId}`, state);
    this.backing.upsertRow(entity, entityId, state);
  }

  findActiveTaskChildren(
    taskId: string,
  ): Array<{ entity: TaskChildEntity; entityId: string; state: StoredEntityState }> {
    return this.childrenMap.get(taskId) ?? this.backing.findActiveTaskChildren(taskId);
  }

  upsertDeparture(entry: {
    entity: EntityName;
    entityId: string;
    projectId: string;
    serverSeq: number;
  }): void {
    this.backing.upsertDeparture(entry);
  }
}
