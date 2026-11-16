import { isTaskChildEntity, parseEntityId, type EntityName } from '../entities';
import { toEnvelope, type OpEnvelope } from '../envelope';

export interface LookupPair {
  entity: EntityName;
  entityId: string;
}

export type ParsedPushOp = OpEnvelope;

export interface ParsedPushBatch {
  ops: ParsedPushOp[];
  lookupPairs: LookupPair[];
  projectIdsToCheck: string[];
}

export function entityHomeKey(entity: EntityName, entityId: string): string {
  return `${entity}:${entityId}`;
}

/** Envelopes raw push ops (validating each once) and collects their D1 lookup keys. */
export function parsePushBatch(rawOps: readonly unknown[]): ParsedPushBatch {
  return collectPushLookups(rawOps.map(toEnvelope));
}

/**
 * Collects the D1 entityHome and purgedProject lookup keys required before planning
 * an already-enveloped batch.
 */
export function collectPushLookups(envelopes: readonly OpEnvelope[]): ParsedPushBatch {
  const lookupPairsMap = new Map<string, LookupPair>();
  const projectIdsToCheck = new Set<string>();

  for (const { rec, entity, entityId, validated } of envelopes) {
    if (entity && entityId && entity !== 'tag') {
      lookupPairsMap.set(entityHomeKey(entity, entityId), { entity, entityId });
      if (
        isTaskChildEntity(entity) &&
        rec?.row &&
        typeof rec.row === 'object' &&
        !Array.isArray(rec.row) &&
        Object.hasOwn(rec.row, 'taskId')
      ) {
        const taskId = (rec.row as Record<string, unknown>).taskId;
        if (typeof taskId === 'string' && taskId.length > 0) {
          lookupPairsMap.set(entityHomeKey('task', taskId), { entity: 'task', entityId: taskId });
        }
      }
      if (entity === 'projectMember') {
        const pm = parseEntityId('projectMember', entityId);
        if (pm) {
          lookupPairsMap.set(entityHomeKey('project', pm.projectId), {
            entity: 'project',
            entityId: pm.projectId,
          });
        }
      } else if (
        entity === 'projectInvite' &&
        rec?.row &&
        typeof rec.row === 'object' &&
        !Array.isArray(rec.row) &&
        Object.hasOwn(rec.row, 'projectId')
      ) {
        const pid = (rec.row as Record<string, unknown>).projectId;
        if (typeof pid === 'string' && pid.length > 0) {
          lookupPairsMap.set(entityHomeKey('project', pid), { entity: 'project', entityId: pid });
        }
      }
    }

    if (validated.ok) {
      if (validated.op.entity === 'project') {
        projectIdsToCheck.add(validated.op.entityId);
      } else if (
        validated.op.op === 'upsert' &&
        validated.op.entity === 'task' &&
        validated.op.fields.includes('projectId') &&
        Object.hasOwn(validated.op.row, 'projectId') &&
        typeof validated.op.row.projectId === 'string' &&
        validated.op.row.projectId.length > 0
      ) {
        projectIdsToCheck.add(validated.op.row.projectId);
      }
    }
  }

  return {
    ops: [...envelopes],
    lookupPairs: Array.from(lookupPairsMap.values()),
    projectIdsToCheck: Array.from(projectIdsToCheck),
  };
}
