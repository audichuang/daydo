import {
  buildDefaultRow,
  ENTITY_FIELDS,
  NON_SYNCED_FIELDS,
  SCHEDULE_CLOCK_KEY,
  SCHEDULE_FIELDS,
  SCHEDULE_FIELD_SET,
  type EntityName,
} from './entities';
import { compareHlc } from './hlc';

export interface MergeExistingState {
  row: Record<string, unknown>;
  clocks: Record<string, string>;
  purgedAt: number | null;
}

export interface MergeOpInput {
  entity: EntityName;
  entityId: string;
  op: 'upsert' | 'delete';
  hlc: string;
  fields: string[];
  row: Record<string, unknown>;
}

export interface MergeResult {
  row: Record<string, unknown>;
  clocks: Record<string, string>;
  purgedAt: number | null;
  changed: boolean;
}

function cloneFieldValue(val: unknown): unknown {
  if (Array.isArray(val)) return [...val];
  return val;
}

function cloneRow(entity: EntityName, source: Record<string, unknown>): Record<string, unknown> {
  const schema = ENTITY_FIELDS[entity];
  const out: Record<string, unknown> = {};
  for (const field of Object.keys(schema)) {
    const val = source[field];
    out[field] = val === undefined ? null : cloneFieldValue(val);
  }
  return out;
}

/**
 * Pure field-level LWW merge per spec/sync.md.
 * Expects `op.hlc` to already be validated (and server-clamped if applicable).
 */
export function mergeOp(
  existing: MergeExistingState | null,
  op: MergeOpInput,
  nowMs: number,
): MergeResult {
  if (existing && existing.purgedAt !== null) {
    return {
      row: cloneRow(op.entity, existing.row),
      clocks: { ...existing.clocks },
      purgedAt: existing.purgedAt,
      changed: false,
    };
  }

  if (op.op === 'delete') {
    const purgedAt = nowMs;
    if (existing) {
      return {
        row: cloneRow(op.entity, existing.row),
        clocks: { ...existing.clocks },
        purgedAt,
        changed: true,
      };
    }
    return {
      row: buildDefaultRow(op.entity, op.entityId, op.row, nowMs),
      clocks: {},
      purgedAt,
      changed: true,
    };
  }

  const schema = ENTITY_FIELDS[op.entity];
  const nonSynced = NON_SYNCED_FIELDS[op.entity];

  const row = existing
    ? cloneRow(op.entity, existing.row)
    : buildDefaultRow(op.entity, op.entityId, op.row, nowMs);
  const clocks: Record<string, string> = existing ? { ...existing.clocks } : {};
  let changed = existing === null;

  let touchedSchedule = false;
  const regularFields: string[] = [];
  const seenFields = new Set<string>();

  for (const field of op.fields) {
    if (seenFields.has(field)) continue;
    seenFields.add(field);
    if (nonSynced?.has(field)) continue;
    if (!(field in schema)) continue;

    if (op.entity === 'task' && SCHEDULE_FIELD_SET.has(field)) {
      touchedSchedule = true;
    } else {
      regularFields.push(field);
    }
  }

  if (touchedSchedule) {
    const prevClock = clocks[SCHEDULE_CLOCK_KEY];
    if (!prevClock || compareHlc(op.hlc, prevClock) > 0) {
      clocks[SCHEDULE_CLOCK_KEY] = op.hlc;
      for (const sf of SCHEDULE_FIELDS) {
        const val = op.row[sf];
        row[sf] = val === undefined || val === null ? null : val;
      }
      changed = true;
    }
  }

  for (const field of regularFields) {
    const prevClock = clocks[field];
    if (!prevClock || compareHlc(op.hlc, prevClock) > 0) {
      clocks[field] = op.hlc;
      const val = op.row[field];
      row[field] = val === undefined || val === null ? null : cloneFieldValue(val);
      changed = true;
    }
  }

  return {
    row,
    clocks,
    purgedAt: null,
    changed,
  };
}
