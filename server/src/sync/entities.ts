import { parseHlc } from './hlc';

export const ENTITY_NAMES = [
  'member',
  'folder',
  'project',
  'projectMember',
  'task',
  'checklistItem',
  'tag',
  'attachment',
  'comment',
] as const;

export type EntityName = (typeof ENTITY_NAMES)[number];

const ENTITY_NAME_SET = new Set<string>(ENTITY_NAMES);

export const SCHEDULE_FIELDS = [
  'startDay',
  'startMinute',
  'endDay',
  'endMinute',
  'timeZone',
] as const;

export const SCHEDULE_FIELD_SET = new Set<string>(SCHEDULE_FIELDS);
export const SCHEDULE_CLOCK_KEY = 'schedule';

export const NON_SYNCED_FIELDS: Readonly<Partial<Record<EntityName, ReadonlySet<string>>>> = {
  member: new Set(['isMe']),
  attachment: new Set(['localPath', 'originalPath']),
};

export type FieldKind = 'string' | 'int' | 'bool' | 'stringArray';

export interface FieldSpec {
  kind: FieldKind;
  nullable: boolean;
  defaultValue?: unknown;
}

export const ENTITY_FIELDS: Record<EntityName, Record<string, FieldSpec>> = {
  member: {
    id: { kind: 'string', nullable: false },
    name: { kind: 'string', nullable: false, defaultValue: '' },
    initial: { kind: 'string', nullable: false, defaultValue: '' },
    color: { kind: 'string', nullable: false, defaultValue: '' },
    createdAt: { kind: 'int', nullable: false },
    updatedAt: { kind: 'int', nullable: false },
    deletedAt: { kind: 'int', nullable: true },
  },
  folder: {
    id: { kind: 'string', nullable: false },
    name: { kind: 'string', nullable: false, defaultValue: '' },
    sortKey: { kind: 'string', nullable: false, defaultValue: '' },
    createdAt: { kind: 'int', nullable: false },
    updatedAt: { kind: 'int', nullable: false },
    deletedAt: { kind: 'int', nullable: true },
  },
  project: {
    id: { kind: 'string', nullable: false },
    name: { kind: 'string', nullable: false, defaultValue: '' },
    color: { kind: 'string', nullable: true },
    icon: { kind: 'string', nullable: true },
    folderId: { kind: 'string', nullable: true },
    viewMode: { kind: 'string', nullable: false, defaultValue: 'list' },
    kind: { kind: 'string', nullable: false, defaultValue: 'TASK' },
    isInbox: { kind: 'bool', nullable: false, defaultValue: false },
    ownerId: { kind: 'string', nullable: false, defaultValue: '' },
    sortKey: { kind: 'string', nullable: false, defaultValue: '' },
    showInSmart: { kind: 'string', nullable: false, defaultValue: 'all' },
    notifyMode: { kind: 'string', nullable: false, defaultValue: 'all' },
    archivedAt: { kind: 'int', nullable: true },
    createdAt: { kind: 'int', nullable: false },
    updatedAt: { kind: 'int', nullable: false },
    deletedAt: { kind: 'int', nullable: true },
  },
  projectMember: {
    projectId: { kind: 'string', nullable: false },
    memberId: { kind: 'string', nullable: false },
    role: { kind: 'string', nullable: false, defaultValue: 'viewer' },
    createdAt: { kind: 'int', nullable: false },
    updatedAt: { kind: 'int', nullable: false },
    deletedAt: { kind: 'int', nullable: true },
  },
  task: {
    id: { kind: 'string', nullable: false },
    projectId: { kind: 'string', nullable: false, defaultValue: '' },
    title: { kind: 'string', nullable: false, defaultValue: '' },
    content: { kind: 'string', nullable: false, defaultValue: '' },
    priority: { kind: 'int', nullable: false, defaultValue: 0 },
    status: { kind: 'int', nullable: false, defaultValue: 0 },
    startDay: { kind: 'string', nullable: true },
    startMinute: { kind: 'int', nullable: true },
    endDay: { kind: 'string', nullable: true },
    endMinute: { kind: 'int', nullable: true },
    timeZone: { kind: 'string', nullable: true },
    reminders: { kind: 'stringArray', nullable: false, defaultValue: [] },
    repeatRule: { kind: 'string', nullable: true },
    tags: { kind: 'stringArray', nullable: false, defaultValue: [] },
    assigneeId: { kind: 'string', nullable: true },
    sortKey: { kind: 'string', nullable: false, defaultValue: '' },
    completedAt: { kind: 'int', nullable: true },
    sourceRaw: { kind: 'string', nullable: true },
    importNote: { kind: 'string', nullable: true },
    createdAt: { kind: 'int', nullable: false },
    updatedAt: { kind: 'int', nullable: false },
    deletedAt: { kind: 'int', nullable: true },
  },
  checklistItem: {
    id: { kind: 'string', nullable: false },
    taskId: { kind: 'string', nullable: false, defaultValue: '' },
    title: { kind: 'string', nullable: false, defaultValue: '' },
    status: { kind: 'int', nullable: false, defaultValue: 0 },
    sortKey: { kind: 'string', nullable: false, defaultValue: '' },
    createdAt: { kind: 'int', nullable: false },
    updatedAt: { kind: 'int', nullable: false },
    deletedAt: { kind: 'int', nullable: true },
  },
  tag: {
    name: { kind: 'string', nullable: false },
    label: { kind: 'string', nullable: false, defaultValue: '' },
    color: { kind: 'string', nullable: true },
    sortKey: { kind: 'string', nullable: false, defaultValue: '' },
    createdAt: { kind: 'int', nullable: false },
    updatedAt: { kind: 'int', nullable: false },
    deletedAt: { kind: 'int', nullable: true },
  },
  attachment: {
    id: { kind: 'string', nullable: false },
    taskId: { kind: 'string', nullable: false, defaultValue: '' },
    fileName: { kind: 'string', nullable: false, defaultValue: '' },
    size: { kind: 'int', nullable: false, defaultValue: 0 },
    mimeType: { kind: 'string', nullable: false, defaultValue: '' },
    createdAt: { kind: 'int', nullable: false },
    updatedAt: { kind: 'int', nullable: false },
    deletedAt: { kind: 'int', nullable: true },
  },
  comment: {
    id: { kind: 'string', nullable: false },
    taskId: { kind: 'string', nullable: false, defaultValue: '' },
    authorId: { kind: 'string', nullable: false, defaultValue: '' },
    body: { kind: 'string', nullable: false, defaultValue: '' },
    createdAt: { kind: 'int', nullable: false },
    updatedAt: { kind: 'int', nullable: false },
    deletedAt: { kind: 'int', nullable: true },
  },
};

export interface ValidatedOp {
  opId: string;
  hlc: string;
  entity: EntityName;
  entityId: string;
  op: 'upsert' | 'delete';
  fields: string[];
  row: Record<string, unknown>;
}

export interface StoredEntityState {
  row: Record<string, unknown>;
  clocks: Record<string, string>;
  purgedAt: number | null;
  ownerUserId: string;
  serverSeq: number;
}

export function isEntityName(value: unknown): value is EntityName {
  return typeof value === 'string' && ENTITY_NAME_SET.has(value);
}

export function parseEntityId(
  entity: EntityName,
  entityId: string,
): Record<string, string> | null {
  if (typeof entityId !== 'string' || entityId.length === 0) return null;
  if (entity === 'projectMember') {
    const colonIdx = entityId.indexOf(':');
    if (colonIdx <= 0 || colonIdx === entityId.length - 1) return null;
    if (entityId.indexOf(':', colonIdx + 1) !== -1) return null;
    return {
      projectId: entityId.slice(0, colonIdx),
      memberId: entityId.slice(colonIdx + 1),
    };
  }
  if (entity === 'tag') {
    return { name: entityId };
  }
  return { id: entityId };
}

export function entityIdFromDbRow(entity: EntityName, dbRow: Record<string, unknown>): string {
  if (entity === 'projectMember') {
    return `${String(dbRow.projectId)}:${String(dbRow.memberId)}`;
  }
  if (entity === 'tag') {
    return String(dbRow.name);
  }
  return String(dbRow.id);
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

export function validateFieldValue(
  spec: FieldSpec,
  value: unknown,
): { ok: true; value: unknown } | { ok: false; reason: string } {
  if (value === undefined || value === null) {
    if (!spec.nullable) {
      return { ok: false, reason: 'cannot be null' };
    }
    return { ok: true, value: null };
  }
  switch (spec.kind) {
    case 'string':
      if (typeof value !== 'string') {
        return { ok: false, reason: 'must be a string' };
      }
      return { ok: true, value };
    case 'int':
      if (typeof value !== 'number' || !Number.isInteger(value) || !Number.isSafeInteger(value)) {
        return { ok: false, reason: 'must be an integer' };
      }
      return { ok: true, value };
    case 'bool':
      if (typeof value !== 'boolean') {
        return { ok: false, reason: 'must be a boolean' };
      }
      return { ok: true, value };
    case 'stringArray':
      if (!Array.isArray(value) || !value.every((item) => typeof item === 'string')) {
        return { ok: false, reason: 'must be an array of strings' };
      }
      return { ok: true, value: [...value] };
  }
}

export function validateSyncOp(
  raw: unknown,
): { ok: true; op: ValidatedOp } | { ok: false; opId: string; reason: string } {
  if (!isPlainObject(raw)) {
    return { ok: false, opId: '', reason: 'Op must be an object' };
  }
  const opId = typeof raw.opId === 'string' ? raw.opId : '';
  if (opId.length === 0) {
    return { ok: false, opId, reason: 'opId must be a non-empty string' };
  }
  if (!isEntityName(raw.entity)) {
    return { ok: false, opId, reason: `Unknown entity: ${String(raw.entity)}` };
  }
  if (typeof raw.entityId !== 'string' || raw.entityId.length === 0) {
    return { ok: false, opId, reason: 'entityId must be a non-empty string' };
  }
  const keys = parseEntityId(raw.entity, raw.entityId);
  if (!keys) {
    return { ok: false, opId, reason: `Malformed entityId for ${raw.entity}` };
  }
  if (raw.op !== 'upsert' && raw.op !== 'delete') {
    return { ok: false, opId, reason: `Invalid op type: ${String(raw.op)}` };
  }
  if (typeof raw.hlc !== 'string' || !parseHlc(raw.hlc)) {
    return { ok: false, opId, reason: 'Invalid hlc' };
  }
  if (!Array.isArray(raw.fields) || !raw.fields.every((f) => typeof f === 'string')) {
    return { ok: false, opId, reason: 'fields must be an array of strings' };
  }
  if (!isPlainObject(raw.row)) {
    return { ok: false, opId, reason: 'row must be a JSON object' };
  }

  const schema = ENTITY_FIELDS[raw.entity];
  if (raw.op === 'upsert') {
    for (const [keyCol, keyVal] of Object.entries(keys)) {
      if (raw.row[keyCol] !== undefined && raw.row[keyCol] !== keyVal) {
        return { ok: false, opId, reason: `row.${keyCol} does not match entityId` };
      }
    }
    const checkKeys = new Set<string>(raw.fields);
    for (const key of Object.keys(raw.row)) {
      if (key in schema) checkKeys.add(key);
    }
    for (const field of checkKeys) {
      const spec = schema[field];
      if (!spec) continue;
      // Only enforce non-nullability for fields explicitly listed in `fields` or present in `row`.
      const val = raw.row[field];
      if (field in raw.row || raw.fields.includes(field)) {
        const res = validateFieldValue(spec, val);
        if (!res.ok) {
          return { ok: false, opId, reason: `Field '${field}' ${res.reason}` };
        }
      }
    }
  }

  return {
    ok: true,
    op: {
      opId,
      hlc: raw.hlc,
      entity: raw.entity,
      entityId: raw.entityId,
      op: raw.op,
      fields: raw.fields,
      row: raw.row,
    },
  };
}

export function buildDefaultRow(
  entity: EntityName,
  entityId: string,
  sourceRow: Record<string, unknown>,
  nowMs: number,
): Record<string, unknown> {
  const schema = ENTITY_FIELDS[entity];
  const keys = parseEntityId(entity, entityId) ?? {};
  const out: Record<string, unknown> = {};

  for (const [field, spec] of Object.entries(schema)) {
    if (field in keys) {
      out[field] = keys[field];
      continue;
    }
    if (field in sourceRow && sourceRow[field] !== undefined) {
      const validated = validateFieldValue(spec, sourceRow[field]);
      if (validated.ok) {
        out[field] = validated.value;
        continue;
      }
    }
    if (spec.nullable) {
      out[field] = null;
    } else if (field === 'createdAt' || field === 'updatedAt') {
      out[field] = nowMs;
    } else if (Array.isArray(spec.defaultValue)) {
      out[field] = [...spec.defaultValue];
    } else {
      out[field] = spec.defaultValue;
    }
  }

  return out;
}

/** Convert a merged internal row (+ purgedAt) into the app's nil-as-absent JSON object. */
export function serializePublicRow(
  entity: EntityName,
  row: Record<string, unknown>,
  purgedAt: number | null,
): Record<string, unknown> {
  const schema = ENTITY_FIELDS[entity];
  const out: Record<string, unknown> = {};
  for (const [field, spec] of Object.entries(schema)) {
    const val = row[field];
    if (val === null || val === undefined) continue;
    if (spec.kind === 'bool') {
      out[field] = Boolean(val);
    } else if (spec.kind === 'stringArray') {
      out[field] = Array.isArray(val) ? [...val] : [];
    } else {
      out[field] = val;
    }
  }
  if (purgedAt !== null && purgedAt !== undefined) {
    out.purgedAt = purgedAt;
  }
  return out;
}

export function parseClocksJson(raw: unknown): Record<string, string> {
  if (typeof raw === 'string') {
    try {
      const parsed: unknown = JSON.parse(raw);
      if (isPlainObject(parsed)) {
        const out: Record<string, string> = {};
        for (const [k, v] of Object.entries(parsed)) {
          if (typeof v === 'string') out[k] = v;
        }
        return out;
      }
    } catch {
      return {};
    }
  }
  if (isPlainObject(raw)) {
    const out: Record<string, string> = {};
    for (const [k, v] of Object.entries(raw)) {
      if (typeof v === 'string') out[k] = v;
    }
    return out;
  }
  return {};
}

export function dbRecordToState(
  entity: EntityName,
  record: Record<string, unknown>,
): StoredEntityState {
  const schema = ENTITY_FIELDS[entity];
  const row: Record<string, unknown> = {};

  for (const [field, spec] of Object.entries(schema)) {
    const raw = record[field];
    if (raw === null || raw === undefined) {
      row[field] = null;
      continue;
    }
    if (spec.kind === 'bool') {
      row[field] = Boolean(raw);
    } else if (spec.kind === 'stringArray') {
      if (typeof raw === 'string') {
        try {
          const parsed: unknown = JSON.parse(raw);
          row[field] = Array.isArray(parsed) ? parsed.filter((x) => typeof x === 'string') : [];
        } catch {
          row[field] = [];
        }
      } else if (Array.isArray(raw)) {
        row[field] = raw.filter((x) => typeof x === 'string');
      } else {
        row[field] = [];
      }
    } else {
      row[field] = raw;
    }
  }

  return {
    row,
    clocks: parseClocksJson(record.clocks),
    purgedAt: typeof record.purgedAt === 'number' ? record.purgedAt : null,
    ownerUserId: String(record.ownerUserId),
    serverSeq: Number(record.serverSeq),
  };
}

export function stateToDbValues(
  entity: EntityName,
  state: StoredEntityState,
): Record<string, unknown> {
  const schema = ENTITY_FIELDS[entity];
  const values: Record<string, unknown> = {};

  for (const [field, spec] of Object.entries(schema)) {
    const val = state.row[field];
    if (val === null || val === undefined) {
      values[field] = null;
    } else if (spec.kind === 'bool') {
      values[field] = val ? 1 : 0;
    } else if (spec.kind === 'stringArray') {
      values[field] = JSON.stringify(Array.isArray(val) ? val : []);
    } else {
      values[field] = val;
    }
  }

  values.ownerUserId = state.ownerUserId;
  values.clocks = JSON.stringify(state.clocks);
  values.serverSeq = state.serverSeq;
  values.purgedAt = state.purgedAt;
  return values;
}
