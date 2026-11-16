import { isEntityName, parseEntityId, validateSyncOp, type EntityName } from './entities';

/** Largest op batch one push accepts (the /sync/push route) or sends (the server-side writer). */
export const MAX_OPS_PER_PUSH = 200;

export type SyncOpValidation = ReturnType<typeof validateSyncOp>;

/**
 * One push op as received, validated exactly once and carried as plain data from the D1 planner
 * to the Scope DO (it crosses the RPC boundary, so no class instances or functions).
 */
export interface OpEnvelope {
  /** The op object as sent, or null when it was not a JSON object (replay reads `rec.row.isMe`). */
  rec: Record<string, unknown> | null;
  /** `rec.opId` when it is a string, else ''. */
  rawOpId: string;
  /** `rec.entity` when it names a known entity. */
  entity: EntityName | null;
  /** `rec.entityId` when it parses for `entity`; non-null implies `entity` is non-null. */
  entityId: string | null;
  validated: SyncOpValidation;
}

/** Wraps a raw op; the only place validateSyncOp runs for push traffic. */
export function toEnvelope(raw: unknown): OpEnvelope {
  const rec =
    raw && typeof raw === 'object' && !Array.isArray(raw) ? (raw as Record<string, unknown>) : null;
  const rawOpId = rec && typeof rec.opId === 'string' ? rec.opId : '';
  const entity = rec && isEntityName(rec.entity) ? rec.entity : null;
  const entityId =
    entity && rec && typeof rec.entityId === 'string' && parseEntityId(entity, rec.entityId)
      ? rec.entityId
      : null;
  return { rec, rawOpId, entity, entityId, validated: validateSyncOp(raw) };
}
