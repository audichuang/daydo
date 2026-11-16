import { DurableObject } from 'cloudflare:workers';
import type { CloudBindings } from 'void';
import { defineDurableObject } from 'void/durable';
import {
  dbRecordToState,
  ENTITY_FIELDS,
  ENTITY_NAMES,
  entityIdFromDbRow,
  hasAllRequiredFields,
  isEntityName,
  isTaskChildEntity,
  parseEntityId,
  stateToDbValues,
  type EntityName,
  type MembershipRole,
  type StoredEntityState,
} from '../src/sync/entities';
import { advanceServerHlc, clampHlc, type Hlc } from '../src/sync/hlc';
import type { ListAccess } from '../src/sync/access';
import type { OpEnvelope } from '../src/sync/envelope';
import { mergeOp } from '../src/sync/merge';
import { authorizeOp } from '../src/scope/authorize';
import { rowView, type ScopeViewer } from '../src/scope/rowView';
import { SplitTxnSnapshotStore } from './dev/splitTxnSnapshotStore';

export interface PushOpResult {
  opId: string;
  status: 'applied' | 'rejected';
  reason?: string;
  row: Record<string, unknown> | null;
  clocks: Record<string, string>;
  gone?: boolean;
}

export interface ScopePushInput {
  scope: string;
  scopeUserId: string;
  pusherUserId: string;
  deviceId: string;
  memberships: Record<string, MembershipRole>;
  purgedProjects: string[];
  meMemberId: string | null;
  /** Ops in push order, each validated once by the caller (invalid ones too: they reject here). */
  ops: OpEnvelope[];
}

export interface ScopePushResponse {
  results: PushOpResult[];
  serverSeq: number;
  boundMeMemberId: string | null;
  /** Server HLC string (`<13-digit ms>:<4-digit counter>:server`). */
  serverTime: string;
}

export interface ExpectedProjectMember {
  memberId: string;
  role: MembershipRole;
}

export interface ScopeProjectMemberInput {
  projectId: string;
  memberId: string;
  role: MembershipRole;
  deleted: boolean;
  nowMs?: number;
}

export interface ScopePurgeProjectInput {
  projectId: string;
  purgedAt: number;
  opId?: string;
  pusherUserId?: string;
}

export interface ScopePurgeProjectResponse {
  projectId: string;
  purgedRow: Record<string, unknown> | null;
  clocks: Record<string, string>;
  serverTime: string;
}

export interface ScopeProjectInfo {
  name: string;
  purgedAt: number | null;
}

export interface ScopePullInput {
  scope: string;
  scopeUserId: string;
  requesterUserId: string;
  since: number;
  limit: number;
  memberships: Record<string, MembershipRole>;
  backfillProjectIds?: string[];
  meMemberId: string | null;
  expectedProjectMembers?: Record<string, ExpectedProjectMember[]>;
}

export type PullScopeRow =
  | {
      entity: EntityName;
      row: Record<string, unknown>;
      clocks: Record<string, string>;
      serverSeq: number;
    }
  | {
      entity: EntityName;
      entityId: string;
      gone: true;
      serverSeq: number;
    };

export interface ScopePullResponse {
  scope: string;
  rows: PullScopeRow[];
  cursor: number;
  hasMore: boolean;
}

export interface OpAppliedRow {
  opId: string;
  userId: string;
  status: 'applied' | 'rejected';
  reason: string | null;
  serverSeq: number;
}

export type TaskChildEntity = 'checklistItem' | 'attachment' | 'comment';
const CHILD_ENTITIES: readonly TaskChildEntity[] = ['checklistItem', 'attachment', 'comment'];
const CREATOR_ONLY_ENTITIES: readonly EntityName[] = ['member', 'folder', 'tag'];
const PROJECT_NON_CREATOR_IGNORED_FIELDS = new Set<string>(['folderId']);
const LIST_SCOPED_ENTITIES: ReadonlyArray<{
  entity: Exclude<EntityName, 'member' | 'folder' | 'tag'>;
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

/** purgeProject answers the list owner deleting it, so the purged project row keeps folderId. */
const PURGE_VIEWER: ScopeViewer = { isScopeOwner: true, meMemberId: null };

export function shouldSplitTransaction(
  syncFault: string | undefined,
  isDev: boolean = import.meta.env.DEV,
): boolean {
  return isDev && syncFault === 'split-txn';
}

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

class SqliteScopeStore implements ScopeStore {
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
    this.ensureSchema();
  }

  private ensureSchema(): void {
    const sql = this.ctx.storage.sql;
    sql.exec(`
      CREATE TABLE IF NOT EXISTS member (
        id TEXT PRIMARY KEY NOT NULL,
        name TEXT NOT NULL,
        initial TEXT NOT NULL,
        color TEXT NOT NULL,
        createdAt INTEGER NOT NULL,
        updatedAt INTEGER NOT NULL,
        deletedAt INTEGER,
        clocks TEXT NOT NULL DEFAULT '{}',
        serverSeq INTEGER NOT NULL,
        purgedAt INTEGER
      );
      CREATE INDEX IF NOT EXISTS member_serverSeq_idx ON member (serverSeq);

      CREATE TABLE IF NOT EXISTS folder (
        id TEXT PRIMARY KEY NOT NULL,
        name TEXT NOT NULL,
        sortKey TEXT NOT NULL,
        createdAt INTEGER NOT NULL,
        updatedAt INTEGER NOT NULL,
        deletedAt INTEGER,
        clocks TEXT NOT NULL DEFAULT '{}',
        serverSeq INTEGER NOT NULL,
        purgedAt INTEGER
      );
      CREATE INDEX IF NOT EXISTS folder_serverSeq_idx ON folder (serverSeq);

      CREATE TABLE IF NOT EXISTS project (
        id TEXT PRIMARY KEY NOT NULL,
        name TEXT NOT NULL,
        color TEXT,
        icon TEXT,
        folderId TEXT,
        viewMode TEXT NOT NULL DEFAULT 'list',
        kind TEXT NOT NULL DEFAULT 'TASK',
        isInbox INTEGER NOT NULL DEFAULT 0,
        ownerId TEXT NOT NULL,
        sortKey TEXT NOT NULL,
        showInSmart TEXT NOT NULL DEFAULT 'all',
        notifyMode TEXT NOT NULL DEFAULT 'all',
        archivedAt INTEGER,
        createdAt INTEGER NOT NULL,
        updatedAt INTEGER NOT NULL,
        deletedAt INTEGER,
        clocks TEXT NOT NULL DEFAULT '{}',
        serverSeq INTEGER NOT NULL,
        purgedAt INTEGER
      );
      CREATE INDEX IF NOT EXISTS project_serverSeq_idx ON project (serverSeq);

      CREATE TABLE IF NOT EXISTS projectMember (
        projectId TEXT NOT NULL,
        memberId TEXT NOT NULL,
        role TEXT NOT NULL,
        createdAt INTEGER NOT NULL,
        updatedAt INTEGER NOT NULL,
        deletedAt INTEGER,
        clocks TEXT NOT NULL DEFAULT '{}',
        serverSeq INTEGER NOT NULL,
        purgedAt INTEGER,
        PRIMARY KEY (projectId, memberId)
      );
      CREATE INDEX IF NOT EXISTS projectMember_serverSeq_idx ON projectMember (serverSeq);

      CREATE TABLE IF NOT EXISTS projectInvite (
        id TEXT PRIMARY KEY NOT NULL,
        projectId TEXT NOT NULL,
        email TEXT NOT NULL,
        role TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'pending',
        createdAt INTEGER NOT NULL,
        updatedAt INTEGER NOT NULL,
        deletedAt INTEGER,
        clocks TEXT NOT NULL DEFAULT '{}',
        serverSeq INTEGER NOT NULL,
        purgedAt INTEGER
      );
      CREATE INDEX IF NOT EXISTS projectInvite_serverSeq_idx ON projectInvite (serverSeq);

      CREATE TABLE IF NOT EXISTS task (
        id TEXT PRIMARY KEY NOT NULL,
        projectId TEXT NOT NULL,
        title TEXT NOT NULL,
        content TEXT NOT NULL DEFAULT '',
        priority INTEGER NOT NULL DEFAULT 0,
        status INTEGER NOT NULL DEFAULT 0,
        startDay TEXT,
        startMinute INTEGER,
        endDay TEXT,
        endMinute INTEGER,
        timeZone TEXT,
        reminders TEXT NOT NULL DEFAULT '[]',
        repeatRule TEXT,
        tags TEXT NOT NULL DEFAULT '[]',
        assigneeId TEXT,
        sortKey TEXT NOT NULL,
        completedAt INTEGER,
        sourceRaw TEXT,
        importNote TEXT,
        createdAt INTEGER NOT NULL,
        updatedAt INTEGER NOT NULL,
        deletedAt INTEGER,
        clocks TEXT NOT NULL DEFAULT '{}',
        serverSeq INTEGER NOT NULL,
        purgedAt INTEGER
      );
      CREATE INDEX IF NOT EXISTS task_serverSeq_idx ON task (serverSeq);
      CREATE INDEX IF NOT EXISTS task_projectId_idx ON task (projectId);

      CREATE TABLE IF NOT EXISTS checklistItem (
        id TEXT PRIMARY KEY NOT NULL,
        taskId TEXT NOT NULL,
        projectId TEXT NOT NULL,
        title TEXT NOT NULL,
        status INTEGER NOT NULL DEFAULT 0,
        sortKey TEXT NOT NULL,
        createdAt INTEGER NOT NULL,
        updatedAt INTEGER NOT NULL,
        deletedAt INTEGER,
        clocks TEXT NOT NULL DEFAULT '{}',
        serverSeq INTEGER NOT NULL,
        purgedAt INTEGER
      );
      CREATE INDEX IF NOT EXISTS checklistItem_serverSeq_idx ON checklistItem (serverSeq);
      CREATE INDEX IF NOT EXISTS checklistItem_taskId_idx ON checklistItem (taskId);
      CREATE INDEX IF NOT EXISTS checklistItem_projectId_idx ON checklistItem (projectId);

      CREATE TABLE IF NOT EXISTS tag (
        name TEXT PRIMARY KEY NOT NULL,
        label TEXT NOT NULL,
        color TEXT,
        sortKey TEXT NOT NULL,
        createdAt INTEGER NOT NULL,
        updatedAt INTEGER NOT NULL,
        deletedAt INTEGER,
        clocks TEXT NOT NULL DEFAULT '{}',
        serverSeq INTEGER NOT NULL,
        purgedAt INTEGER
      );
      CREATE INDEX IF NOT EXISTS tag_serverSeq_idx ON tag (serverSeq);

      CREATE TABLE IF NOT EXISTS attachment (
        id TEXT PRIMARY KEY NOT NULL,
        taskId TEXT NOT NULL,
        projectId TEXT NOT NULL,
        fileName TEXT NOT NULL,
        size INTEGER NOT NULL,
        mimeType TEXT NOT NULL,
        createdAt INTEGER NOT NULL,
        updatedAt INTEGER NOT NULL,
        deletedAt INTEGER,
        clocks TEXT NOT NULL DEFAULT '{}',
        serverSeq INTEGER NOT NULL,
        purgedAt INTEGER
      );
      CREATE INDEX IF NOT EXISTS attachment_serverSeq_idx ON attachment (serverSeq);
      CREATE INDEX IF NOT EXISTS attachment_taskId_idx ON attachment (taskId);
      CREATE INDEX IF NOT EXISTS attachment_projectId_idx ON attachment (projectId);

      CREATE TABLE IF NOT EXISTS comment (
        id TEXT PRIMARY KEY NOT NULL,
        taskId TEXT NOT NULL,
        projectId TEXT NOT NULL,
        authorId TEXT NOT NULL,
        body TEXT NOT NULL,
        createdAt INTEGER NOT NULL,
        updatedAt INTEGER NOT NULL,
        deletedAt INTEGER,
        clocks TEXT NOT NULL DEFAULT '{}',
        serverSeq INTEGER NOT NULL,
        purgedAt INTEGER
      );
      CREATE INDEX IF NOT EXISTS comment_serverSeq_idx ON comment (serverSeq);
      CREATE INDEX IF NOT EXISTS comment_taskId_idx ON comment (taskId);
      CREATE INDEX IF NOT EXISTS comment_projectId_idx ON comment (projectId);

      CREATE TABLE IF NOT EXISTS departure (
        entity TEXT NOT NULL,
        entityId TEXT NOT NULL,
        projectId TEXT NOT NULL,
        serverSeq INTEGER NOT NULL,
        PRIMARY KEY (entity, entityId, projectId)
      );
      CREATE INDEX IF NOT EXISTS departure_serverSeq_idx ON departure (serverSeq);

      CREATE TABLE IF NOT EXISTS opApplied (
        opId TEXT PRIMARY KEY NOT NULL,
        userId TEXT NOT NULL,
        status TEXT NOT NULL,
        reason TEXT,
        serverSeq INTEGER NOT NULL
      );

      CREATE TABLE IF NOT EXISTS counter (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        value INTEGER NOT NULL DEFAULT 0
      );

      CREATE TABLE IF NOT EXISTS purgedProject (
        projectId TEXT PRIMARY KEY NOT NULL,
        purgedAt INTEGER NOT NULL
      );
    `);
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
    const nowMs = Date.now();
    const initialSeq = store.getCounter();
    let currentSeq = initialSeq;
    let meMemberId = input.meMemberId;
    let boundMeMemberId: string | null = null;
    const isScopeOwner = input.pusherUserId === input.scopeUserId;
    const purgedSet = new Set<string>([...input.purgedProjects, ...store.getPurgedProjects()]);
    const access: ListAccess = { memberships: input.memberships, purgedSet };

    const results: PushOpResult[] = [];
    const batchHlcs: Hlc[] = [];

    if (input.ops.length === 0) {
      const nextServerHlc = advanceServerHlc(nowMs, batchHlcs, this.lastServerHlc);
      this.lastServerHlc = nextServerHlc.hlc;
      return {
        results: [],
        serverSeq: currentSeq,
        boundMeMemberId: null,
        serverTime: nextServerHlc.formatted,
      };
    }

    const canReadState = (
      entity: EntityName,
      entityId: string,
      state: StoredEntityState,
    ): boolean => {
      if (entity === 'member' || entity === 'folder' || entity === 'tag') {
        return isScopeOwner;
      }
      if (entity === 'project') {
        return Boolean(input.memberships[entityId]);
      }
      if (entity === 'projectMember' || entity === 'projectInvite' || entity === 'task') {
        return Boolean(input.memberships[String(state.row.projectId)]);
      }
      // Child row: check parent task's current list (or stored projectId tag).
      const parentTask = store.getRow('task', String(state.row.taskId));
      const projectId = parentTask ? String(parentTask.row.projectId) : (state.projectId ?? '');
      return Boolean(input.memberships[projectId]);
    };

    const resolveCurrentRow = (
      entity: EntityName | null,
      entityId: string | null,
    ): { row: Record<string, unknown> | null; clocks: Record<string, string>; gone?: boolean } => {
      if (!entity || !entityId) {
        return { row: null, clocks: {} };
      }
      const state = store.getRow(entity, entityId);
      if (!state) {
        return { row: null, clocks: {} };
      }
      if (!canReadState(entity, entityId, state)) {
        return { row: null, clocks: {}, gone: true };
      }
      return {
        row: rowView(entity, state.row, state.purgedAt, { isScopeOwner, meMemberId }),
        clocks: { ...state.clocks },
      };
    };

    const rejectOp = (
      opId: string,
      reason: string,
      entity: EntityName | null,
      entityId: string | null,
    ) => {
      if (opId.length > 0) {
        store.insertOpApplied({
          opId,
          userId: input.pusherUserId,
          status: 'rejected',
          reason,
          serverSeq: currentSeq,
        });
      }
      const current = resolveCurrentRow(entity, entityId);
      results.push({
        opId,
        status: 'rejected',
        reason,
        row: current.row,
        clocks: current.clocks,
        ...(current.gone ? { gone: true } : {}),
      });
    };

    for (const envelope of input.ops) {
      const { rec, rawOpId } = envelope;
      const rawEntityId = envelope.entityId;
      const rawEntity = rawEntityId !== null ? envelope.entity : null;

      // 1. opId dedupe
      if (rawOpId.length > 0) {
        const seen = store.getOpApplied(rawOpId);
        if (seen) {
          if (seen.userId !== input.pusherUserId) {
            results.push({
              opId: rawOpId,
              status: 'rejected',
              reason: 'opId already used by another user',
              row: null,
              clocks: {},
            });
            continue;
          }
          if (seen.status === 'rejected') {
            const current = resolveCurrentRow(rawEntity, rawEntityId);
            results.push({
              opId: rawOpId,
              status: 'rejected',
              reason: seen.reason ?? 'Previously rejected',
              row: current.row,
              clocks: current.clocks,
              ...(current.gone ? { gone: true } : {}),
            });
            continue;
          }
          // Previously applied replay
          if (rawEntity && rawEntityId) {
            const state = store.getRow(rawEntity, rawEntityId);
            if (state && canReadState(rawEntity, rawEntityId, state)) {
              if (
                rawEntity === 'member' &&
                isScopeOwner &&
                meMemberId === null &&
                rec?.row &&
                typeof rec.row === 'object' &&
                !Array.isArray(rec.row) &&
                Object.hasOwn(rec.row, 'isMe') &&
                (rec.row as Record<string, unknown>).isMe === true
              ) {
                meMemberId = rawEntityId;
                boundMeMemberId = rawEntityId;
                currentSeq += 1;
                store.upsertRow('member', rawEntityId, { ...state, serverSeq: currentSeq });
                store.setCounter(currentSeq);
              }
              results.push({
                opId: rawOpId,
                status: 'applied',
                row: rowView(rawEntity, state.row, state.purgedAt, { isScopeOwner, meMemberId }),
                clocks: { ...state.clocks },
              });
              continue;
            }
            if (state) {
              results.push({
                opId: rawOpId,
                status: 'applied',
                row: null,
                clocks: {},
                gone: true,
              });
              continue;
            }
          }
          results.push({
            opId: rawOpId,
            status: 'applied',
            row: null,
            clocks: {},
          });
          continue;
        }
      }

      // 2. Validation
      const validated = envelope.validated;
      if (!validated.ok) {
        rejectOp(validated.opId, validated.reason, rawEntity, rawEntityId);
        continue;
      }
      const op = validated.op;

      // 3. Disallowed sync entities
      if (op.entity === 'projectMember' || op.entity === 'projectInvite') {
        rejectOp(op.opId, `${op.entity} cannot be modified via sync`, op.entity, op.entityId);
        continue;
      }

      const existing = store.getRow(op.entity, op.entityId);

      // 4. Missing row + partial upsert check
      if (!existing) {
        if (op.op === 'upsert' && !hasAllRequiredFields(op.entity, op.fields)) {
          rejectOp(op.opId, 'unknown-row', op.entity, op.entityId);
          continue;
        }
        if (op.op === 'delete' && isTaskChildEntity(op.entity)) {
          rejectOp(op.opId, 'unknown-row', op.entity, op.entityId);
          continue;
        }
      }

      // 5. Authorization & domain rules by row's CURRENT list
      const auth = authorizeOp({
        op,
        existing,
        isScopeOwner,
        access,
        getTask: (taskId) => store.getRow('task', taskId),
      });
      if (!auth.ok) {
        rejectOp(op.opId, auth.reason, op.entity, op.entityId);
        continue;
      }
      const { parentTask, childProjectId } = auth;

      // 6. HLC 5-minute clamp & merge
      let clamped: ReturnType<typeof clampHlc>;
      let merged: ReturnType<typeof mergeOp>;
      try {
        clamped = clampHlc(op.hlc, nowMs, this.lastClamped);
        if (clamped.clamped) {
          this.lastClamped = clamped.hlc;
        }
        const parentPurged =
          isTaskChildEntity(op.entity) &&
          (!existing || existing.purgedAt === null) &&
          parentTask !== null &&
          parentTask.purgedAt !== null;

        merged = mergeOp(
          existing
            ? { row: existing.row, clocks: existing.clocks, purgedAt: existing.purgedAt }
            : null,
          {
            entity: op.entity,
            entityId: op.entityId,
            op: op.op,
            hlc: clamped.formatted,
            fields: op.fields,
            row: op.row,
          },
          nowMs,
          {
            parentPurged,
            ignoreFields:
              op.entity === 'project' && !isScopeOwner
                ? PROJECT_NON_CREATOR_IGNORED_FIELDS
                : undefined,
          },
        );
        batchHlcs.push(clamped.hlc);
      } catch (err) {
        rejectOp(
          op.opId,
          err instanceof Error ? `Invalid op: ${err.message}` : 'Invalid sync op',
          op.entity,
          op.entityId,
        );
        continue;
      }

      // 7. Persist state & handle task move / cascade purge
      let opServerSeq = existing?.serverSeq ?? currentSeq;
      if (merged.changed) {
        currentSeq += 1;
        opServerSeq = currentSeq;
        const nextState: StoredEntityState = {
          row: merged.row,
          clocks: merged.clocks,
          purgedAt: merged.purgedAt,
          serverSeq: opServerSeq,
          ...(isTaskChildEntity(op.entity) ? { projectId: childProjectId ?? '' } : {}),
        };
        store.upsertRow(op.entity, op.entityId, nextState);

        if (
          op.entity === 'task' &&
          existing &&
          existing.purgedAt === null &&
          op.op === 'upsert'
        ) {
          const oldProjectId = String(existing.row.projectId);
          const newProjectId = String(merged.row.projectId);
          if (newProjectId !== oldProjectId) {
            store.upsertDeparture({
              entity: 'task',
              entityId: op.entityId,
              projectId: oldProjectId,
              serverSeq: opServerSeq,
            });
            const children = store.findActiveTaskChildren(op.entityId);
            for (const child of children) {
              currentSeq += 1;
              const childSeq = currentSeq;
              store.upsertRow(child.entity, child.entityId, {
                ...child.state,
                projectId: newProjectId,
                serverSeq: childSeq,
              });
              store.upsertDeparture({
                entity: child.entity,
                entityId: child.entityId,
                projectId: oldProjectId,
                serverSeq: childSeq,
              });
            }
          }
        }

        if (op.entity === 'task' && op.op === 'delete') {
          const children = store.findActiveTaskChildren(op.entityId);
          for (const child of children) {
            currentSeq += 1;
            store.upsertRow(child.entity, child.entityId, {
              ...child.state,
              purgedAt: nowMs,
              serverSeq: currentSeq,
            });
          }
        }
      }

      if (
        op.entity === 'member' &&
        op.op === 'upsert' &&
        isScopeOwner &&
        meMemberId === null &&
        Object.hasOwn(op.row, 'isMe') &&
        op.row.isMe === true
      ) {
        meMemberId = op.entityId;
        boundMeMemberId = op.entityId;
        if (!merged.changed && existing) {
          currentSeq += 1;
          opServerSeq = currentSeq;
          store.upsertRow('member', op.entityId, {
            ...existing,
            serverSeq: opServerSeq,
          });
        }
      }

      store.insertOpApplied({
        opId: op.opId,
        userId: input.pusherUserId,
        status: 'applied',
        reason: null,
        serverSeq: opServerSeq,
      });

      results.push({
        opId: op.opId,
        status: 'applied',
        row: rowView(op.entity, merged.row, merged.purgedAt, { isScopeOwner, meMemberId }),
        clocks: merged.clocks,
      });
    }

    if (currentSeq !== initialSeq) {
      store.setCounter(currentSeq);
    }

    const nextServerHlc = advanceServerHlc(
      Math.max(Date.now(), nowMs),
      batchHlcs,
      this.lastServerHlc,
    );
    this.lastServerHlc = nextServerHlc.hlc;

    return {
      results,
      serverSeq: currentSeq,
      boundMeMemberId,
      serverTime: nextServerHlc.formatted,
    };
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
    const initialSeq = store.getCounter();
    let currentSeq = initialSeq;
    const serverHlc = advanceServerHlc(nowMs, [], this.lastServerHlc);

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
            updatedAt: serverHlc.formatted,
            deletedAt: serverHlc.formatted,
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
              role: serverHlc.formatted,
              updatedAt: serverHlc.formatted,
              deletedAt: serverHlc.formatted,
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
              projectId: serverHlc.formatted,
              memberId: serverHlc.formatted,
              role: serverHlc.formatted,
              createdAt: serverHlc.formatted,
              updatedAt: serverHlc.formatted,
              deletedAt: serverHlc.formatted,
            },
            purgedAt: null,
            serverSeq: currentSeq,
          });
        }
      }
    }

    if (currentSeq !== initialSeq) {
      store.setCounter(currentSeq);
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
    const projectIds = Object.keys(expectedByProject);
    if (projectIds.length === 0) return;
    const sql = this.ctx.storage.sql;
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
