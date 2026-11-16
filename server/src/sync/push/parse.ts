import {
  isEntityName,
  isTaskChildEntity,
  parseEntityId,
  validateSyncOp,
  type EntityName,
} from '../entities';

export interface LookupPair {
  entity: EntityName;
  entityId: string;
}

export interface ParsedPushOp {
  raw: unknown;
  rec: Record<string, unknown> | null;
  rawOpId: string;
  entity: EntityName | null;
  entityId: string | null;
  validated: ReturnType<typeof validateSyncOp>;
}

export interface ParsedPushBatch {
  ops: ParsedPushOp[];
  lookupPairs: LookupPair[];
  projectIdsToCheck: string[];
}

export function entityHomeKey(entity: EntityName, entityId: string): string {
  return `${entity}:${entityId}`;
}

/**
 * Parses and validates raw push ops and collects the D1 entityHome and purgedProject
 * lookup keys required before planning.
 */
export function parsePushBatch(rawOps: readonly unknown[]): ParsedPushBatch {
  const lookupPairsMap = new Map<string, LookupPair>();
  const projectIdsToCheck = new Set<string>();

  const ops = rawOps.map((raw): ParsedPushOp => {
    const rec =
      raw && typeof raw === 'object' && !Array.isArray(raw)
        ? (raw as Record<string, unknown>)
        : null;
    const rawOpId = rec && typeof rec.opId === 'string' ? rec.opId : '';
    const entity = rec && isEntityName(rec.entity) ? rec.entity : null;
    const entityId =
      entity && rec && typeof rec.entityId === 'string' && parseEntityId(entity, rec.entityId)
        ? rec.entityId
        : null;
    const validated = validateSyncOp(raw);

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

    return { raw, rec, rawOpId, entity, entityId, validated };
  });

  return {
    ops,
    lookupPairs: Array.from(lookupPairsMap.values()),
    projectIdsToCheck: Array.from(projectIdsToCheck),
  };
}
