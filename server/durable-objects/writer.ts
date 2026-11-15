import { opApplied, seq, user } from '@schema';
import { DurableObject } from 'cloudflare:workers';
import type { CloudBindings } from 'void';
import { and, createDb, eq, inArray, isNull, type BatchItem } from 'void/db';
import { defineDurableObject } from 'void/durable';
import {
  buildUpsertStatement,
  chunkArray,
  findActiveTaskChildren,
  preloadEntities,
  stateKey,
  type AppDb,
} from '../src/sync/db';
import {
  isEntityName,
  parseEntityId,
  serializePublicRow,
  validateSyncOp,
  type EntityName,
  type StoredEntityState,
} from '../src/sync/entities';
import { clampHlc, type Hlc } from '../src/sync/hlc';
import { mergeOp } from '../src/sync/merge';

export interface PushOpResult {
  opId: string;
  status: 'applied' | 'rejected';
  reason?: string;
  row: Record<string, unknown> | null;
  clocks: Record<string, string>;
}

export interface PushBatchResponse {
  results: PushOpResult[];
  serverSeq: number;
}

const TASK_CHILD_ENTITIES = new Set<EntityName>(['checklistItem', 'attachment', 'comment']);

function isTaskChildEntity(entity: EntityName): boolean {
  return TASK_CHILD_ENTITIES.has(entity);
}

export function shouldBypassWriterQueue(
  writerQueue: string | undefined,
  isDev: boolean = import.meta.env.DEV,
): boolean {
  return isDev && writerQueue === 'off';
}

class WriterObject extends DurableObject<CloudBindings> {
  private queue: Promise<void> = Promise.resolve();
  private lastClamped: Hlc | null = null;
  private readonly allowQueueBypass: boolean;

  constructor(
    ctx: DurableObjectState,
    env: CloudBindings,
    allowQueueBypass: boolean = import.meta.env.DEV,
  ) {
    super(ctx, env);
    this.allowQueueBypass = allowQueueBypass;
  }

  private enqueue<T>(fn: () => Promise<T>): Promise<T> {
    if (
      import.meta.env.DEV &&
      shouldBypassWriterQueue(this.env.WRITER_QUEUE, this.allowQueueBypass)
    ) {
      return fn();
    }
    const next = this.queue.then(fn, fn);
    this.queue = next.then(
      () => undefined,
      () => undefined,
    );
    return next;
  }

  async push(input: {
    userId: string;
    deviceId: string;
    ops: unknown[];
  }): Promise<PushBatchResponse> {
    return this.enqueue(() => this.processBatch(input));
  }

  private async processBatch(input: {
    userId: string;
    deviceId: string;
    ops: unknown[];
  }): Promise<PushBatchResponse> {
    const { userId, ops } = input;
    const nowMs = Date.now();
    const db = createDb(this.env.DB, { session: 'first-primary' });

    const seqRow = await db.select().from(seq).where(eq(seq.id, 1)).get();
    const initialSeq = seqRow?.value ?? 0;
    let currentSeq = initialSeq;

    if (ops.length === 0) {
      return { results: [], serverSeq: currentSeq };
    }

    const opIds: string[] = [];
    const preloadTargets: Array<{ entity: EntityName; entityId: string }> = [];

    for (const raw of ops) {
      if (raw && typeof raw === 'object' && !Array.isArray(raw)) {
        const rec = raw as Record<string, unknown>;
        if (typeof rec.opId === 'string' && rec.opId.length > 0) {
          opIds.push(rec.opId);
        }
        if (
          isEntityName(rec.entity) &&
          typeof rec.entityId === 'string' &&
          parseEntityId(rec.entity, rec.entityId)
        ) {
          preloadTargets.push({ entity: rec.entity, entityId: rec.entityId });
          if (
            isTaskChildEntity(rec.entity) &&
            rec.row &&
            typeof rec.row === 'object' &&
            !Array.isArray(rec.row) &&
            Object.hasOwn(rec.row, 'taskId')
          ) {
            const taskId = (rec.row as Record<string, unknown>).taskId;
            if (typeof taskId === 'string' && taskId.length > 0) {
              preloadTargets.push({ entity: 'task', entityId: taskId });
            }
          }
        }
      }
    }

    const seenOpIds = await loadExistingOpIds(db, opIds);
    const workingRows = await preloadEntities(db, userId, preloadTargets);

    const hasMemberOp = preloadTargets.some((t) => t.entity === 'member');
    let meMemberId: string | null = null;
    let bindMeMemberId: string | null = null;
    if (hasMemberOp) {
      const userRow = await db
        .select({ meMemberId: user.meMemberId })
        .from(user)
        .where(eq(user.id, userId))
        .get();
      meMemberId = userRow?.meMemberId ?? null;
    }

    const missingParentTasks: Array<{ entity: 'task'; entityId: string }> = [];
    for (const [key, state] of workingRows) {
      const colonIdx = key.indexOf(':');
      const entity = colonIdx > 0 ? key.slice(0, colonIdx) : '';
      if (!isEntityName(entity) || !isTaskChildEntity(entity)) continue;
      const tid = state.row.taskId;
      if (
        typeof tid === 'string' &&
        tid.length > 0 &&
        !workingRows.has(stateKey('task', tid, userId))
      ) {
        missingParentTasks.push({ entity: 'task', entityId: tid });
      }
    }
    if (missingParentTasks.length > 0) {
      const extraParents = await preloadEntities(db, userId, missingParentTasks);
      for (const [k, v] of extraParents) {
        if (!workingRows.has(k)) {
          workingRows.set(k, v);
        }
      }
    }

    const dirtyRows = new Map<string, { entity: EntityName; state: StoredEntityState }>();
    const newOpApplied: Array<typeof opApplied.$inferInsert> = [];
    const results: PushOpResult[] = [];
    const rejectOp = (opId: string, reason: string) => {
      if (opId.length > 0) {
        seenOpIds.set(opId, {
          userId,
          status: 'rejected',
          serverSeq: currentSeq,
        });
        newOpApplied.push({
          opId,
          userId,
          status: 'rejected',
          serverSeq: currentSeq,
          createdAt: nowMs,
        });
      }
      results.push({
        opId,
        status: 'rejected',
        reason,
        row: null,
        clocks: {},
      });
    };

    for (const raw of ops) {
      const rec =
        raw && typeof raw === 'object' && !Array.isArray(raw)
          ? (raw as Record<string, unknown>)
          : null;
      const rawOpId = rec && typeof rec.opId === 'string' ? rec.opId : '';

      if (rawOpId.length > 0 && seenOpIds.has(rawOpId)) {
        const existingOp = seenOpIds.get(rawOpId)!;
        if (existingOp.userId !== userId) {
          results.push({
            opId: rawOpId,
            status: 'rejected',
            reason: 'opId already used by another user',
            row: null,
            clocks: {},
          });
          continue;
        }
        if (existingOp.status === 'rejected') {
          results.push({
            opId: rawOpId,
            status: 'rejected',
            reason: 'Previously rejected',
            row: null,
            clocks: {},
          });
          continue;
        }
        let replayRow: Record<string, unknown> | null = null;
        let replayClocks: Record<string, string> = {};
        if (
          rec &&
          isEntityName(rec.entity) &&
          typeof rec.entityId === 'string' &&
          parseEntityId(rec.entity, rec.entityId)
        ) {
          const state = workingRows.get(stateKey(rec.entity, rec.entityId, userId));
          if (state && state.ownerUserId === userId) {
            if (
              rec.entity === 'member' &&
              meMemberId === null &&
              rec.row &&
              typeof rec.row === 'object' &&
              !Array.isArray(rec.row) &&
              Object.hasOwn(rec.row, 'isMe') &&
              (rec.row as Record<string, unknown>).isMe === true
            ) {
              meMemberId = rec.entityId;
              bindMeMemberId = rec.entityId;
            }
            replayRow = serializePublicRow(rec.entity, state.row, state.purgedAt, { meMemberId });
            replayClocks = { ...state.clocks };
          }
        }
        results.push({
          opId: rawOpId,
          status: 'applied',
          row: replayRow,
          clocks: replayClocks,
        });
        continue;
      }

      let op: ReturnType<typeof validateSyncOp> extends infer R
        ? R extends { ok: true; op: infer O }
          ? O
          : never
        : never;
      let clamped: ReturnType<typeof clampHlc>;
      let existing: StoredEntityState | null;
      let key: string;
      let merged: ReturnType<typeof mergeOp>;
      try {
        const validated = validateSyncOp(raw);
        if (!validated.ok) {
          rejectOp(validated.opId, validated.reason);
          continue;
        }
        op = validated.op;
        clamped = clampHlc(op.hlc, nowMs, this.lastClamped);
        if (clamped.clamped) {
          this.lastClamped = clamped.hlc;
        }

        key = stateKey(op.entity, op.entityId, userId);
        existing = workingRows.get(key) ?? null;

        if (existing && existing.ownerUserId !== userId) {
          rejectOp(op.opId, 'Forbidden: row owned by another user');
          continue;
        }

        let parentPurged = false;
        if (op.op === 'upsert' && isTaskChildEntity(op.entity)) {
          const candidateTaskIds = new Set<string>();
          if (existing && typeof existing.row.taskId === 'string' && existing.row.taskId.length > 0) {
            candidateTaskIds.add(existing.row.taskId);
          }
          if (
            (!existing || op.fields.includes('taskId')) &&
            Object.hasOwn(op.row, 'taskId') &&
            typeof op.row.taskId === 'string' &&
            op.row.taskId.length > 0
          ) {
            candidateTaskIds.add(op.row.taskId);
          }
          for (const tid of candidateTaskIds) {
            const parentTask = workingRows.get(stateKey('task', tid, userId));
            if (parentTask && parentTask.ownerUserId === userId && parentTask.purgedAt !== null) {
              parentPurged = true;
              break;
            }
          }
        }

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
          { parentPurged },
        );
      } catch (err) {
        rejectOp(
          rawOpId,
          err instanceof Error ? `Invalid op: ${err.message}` : 'Invalid sync op',
        );
        continue;
      }

      let opServerSeq = existing?.serverSeq ?? currentSeq;
      if (merged.changed) {
        currentSeq += 1;
        opServerSeq = currentSeq;
        const nextState: StoredEntityState = {
          row: merged.row,
          clocks: merged.clocks,
          purgedAt: merged.purgedAt,
          ownerUserId: userId,
          serverSeq: opServerSeq,
        };
        workingRows.set(key, nextState);
        dirtyRows.set(key, { entity: op.entity, state: nextState });

        if (op.entity === 'task' && op.op === 'delete') {
          currentSeq = await this.cascadeTaskPurge(
            db,
            userId,
            op.entityId,
            nowMs,
            currentSeq,
            workingRows,
            dirtyRows,
          );
        }
      }

      if (
        op.entity === 'member' &&
        op.op === 'upsert' &&
        meMemberId === null &&
        Object.hasOwn(op.row, 'isMe') &&
        op.row.isMe === true
      ) {
        meMemberId = op.entityId;
        bindMeMemberId = op.entityId;
      }

      seenOpIds.set(op.opId, {
        userId,
        status: 'applied',
        serverSeq: opServerSeq,
      });
      newOpApplied.push({
        opId: op.opId,
        userId,
        status: 'applied',
        serverSeq: opServerSeq,
        createdAt: nowMs,
      });

      results.push({
        opId: op.opId,
        status: 'applied',
        row: serializePublicRow(op.entity, merged.row, merged.purgedAt, { meMemberId }),
        clocks: merged.clocks,
      });
    }

    const statements: BatchItem<'sqlite'>[] = [];

    if (bindMeMemberId !== null) {
      statements.push(
        db
          .update(user)
          .set({ meMemberId: bindMeMemberId })
          .where(and(eq(user.id, userId), isNull(user.meMemberId))),
      );
    }

    if (currentSeq !== initialSeq) {
      statements.push(
        db
          .insert(seq)
          .values({ id: 1, value: currentSeq })
          .onConflictDoUpdate({ target: seq.id, set: { value: currentSeq } }),
      );
    }

    for (const { entity, state } of dirtyRows.values()) {
      statements.push(buildUpsertStatement(db, entity, state));
    }

    for (const entry of newOpApplied) {
      statements.push(db.insert(opApplied).values(entry).onConflictDoNothing());
    }

    if (statements.length > 0) {
      await db.batch(statements as [BatchItem<'sqlite'>, ...BatchItem<'sqlite'>[]]);
    }

    return {
      results,
      serverSeq: currentSeq,
    };
  }

  private async cascadeTaskPurge(
    db: AppDb,
    userId: string,
    taskId: string,
    nowMs: number,
    currentSeq: number,
    workingRows: Map<string, StoredEntityState>,
    dirtyRows: Map<string, { entity: EntityName; state: StoredEntityState }>,
  ): Promise<number> {
    let nextSeq = currentSeq;
    const dbChildren = await findActiveTaskChildren(db, userId, taskId);
    const childKeys = new Set<string>();

    for (const child of dbChildren) {
      const childKey = stateKey(child.entity, child.entityId, userId);
      childKeys.add(childKey);
      const current = workingRows.get(childKey) ?? child.state;
      if (current.purgedAt !== null || current.ownerUserId !== userId) continue;
      nextSeq += 1;
      const purged: StoredEntityState = {
        ...current,
        purgedAt: nowMs,
        serverSeq: nextSeq,
      };
      workingRows.set(childKey, purged);
      dirtyRows.set(childKey, { entity: child.entity, state: purged });
    }

    // Also purge any child rows created earlier in the same batch before D1 flush.
    for (const [k, dirty] of dirtyRows) {
      if (childKeys.has(k)) continue;
      if (!isTaskChildEntity(dirty.entity)) continue;
      if (dirty.state.purgedAt !== null || dirty.state.ownerUserId !== userId) continue;
      if (dirty.state.row.taskId !== taskId) continue;
      nextSeq += 1;
      const purged: StoredEntityState = {
        ...dirty.state,
        purgedAt: nowMs,
        serverSeq: nextSeq,
      };
      workingRows.set(k, purged);
      dirtyRows.set(k, { entity: dirty.entity, state: purged });
    }

    return nextSeq;
  }
}

async function loadExistingOpIds(
  db: AppDb,
  opIds: string[],
): Promise<Map<string, { userId: string; status: 'applied' | 'rejected'; serverSeq: number }>> {
  const map = new Map<string, { userId: string; status: 'applied' | 'rejected'; serverSeq: number }>();
  const unique = Array.from(new Set(opIds));
  for (const chunk of chunkArray(unique, 50)) {
    const rows = await db.select().from(opApplied).where(inArray(opApplied.opId, chunk));
    for (const r of rows) {
      map.set(r.opId, {
        userId: r.userId,
        status: r.status === 'rejected' ? 'rejected' : 'applied',
        serverSeq: r.serverSeq,
      });
    }
  }
  return map;
}

export const Writer = defineDurableObject({
  name: 'writer',
  class: WriterObject,
});

export default Writer;
