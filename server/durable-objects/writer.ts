import { opApplied, seq } from '@schema';
import { DurableObject } from 'cloudflare:workers';
import type { CloudBindings } from 'void';
import { createDb, eq, inArray, type BatchItem } from 'void/db';
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

class WriterObject extends DurableObject<CloudBindings> {
  private queue: Promise<void> = Promise.resolve();
  private lastClamped: Hlc | null = null;

  private enqueue<T>(fn: () => Promise<T>): Promise<T> {
    if (this.env.WRITER_QUEUE === 'off') {
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
        }
      }
    }

    const seenOpIds = await loadExistingOpIds(db, opIds);
    const workingRows = await preloadEntities(db, userId, preloadTargets);

    const dirtyRows = new Map<string, { entity: EntityName; state: StoredEntityState }>();
    const newOpApplied: Array<typeof opApplied.$inferInsert> = [];
    const results: PushOpResult[] = [];

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
            replayRow = serializePublicRow(rec.entity, state.row, state.purgedAt);
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

      const validated = validateSyncOp(raw);
      if (!validated.ok) {
        if (validated.opId.length > 0) {
          seenOpIds.set(validated.opId, {
            userId,
            status: 'rejected',
            serverSeq: currentSeq,
          });
          newOpApplied.push({
            opId: validated.opId,
            userId,
            status: 'rejected',
            serverSeq: currentSeq,
            createdAt: nowMs,
          });
        }
        results.push({
          opId: validated.opId,
          status: 'rejected',
          reason: validated.reason,
          row: null,
          clocks: {},
        });
        continue;
      }

      const op = validated.op;
      const clamped = clampHlc(op.hlc, nowMs, this.lastClamped);
      if (clamped.clamped) {
        this.lastClamped = clamped.hlc;
      }

      const key = stateKey(op.entity, op.entityId, userId);
      const existing = workingRows.get(key) ?? null;

      if (existing && existing.ownerUserId !== userId) {
        seenOpIds.set(op.opId, {
          userId,
          status: 'rejected',
          serverSeq: currentSeq,
        });
        newOpApplied.push({
          opId: op.opId,
          userId,
          status: 'rejected',
          serverSeq: currentSeq,
          createdAt: nowMs,
        });
        results.push({
          opId: op.opId,
          status: 'rejected',
          reason: 'Forbidden: row owned by another user',
          row: null,
          clocks: {},
        });
        continue;
      }

      const merged = mergeOp(
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
      );

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
        row: serializePublicRow(op.entity, merged.row, merged.purgedAt),
        clocks: merged.clocks,
      });
    }

    const statements: BatchItem<'sqlite'>[] = [];

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
      if (
        dirty.entity !== 'checklistItem' &&
        dirty.entity !== 'attachment' &&
        dirty.entity !== 'comment'
      ) {
        continue;
      }
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
