import { readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import {
  dbRecordToState,
  serializePublicRow,
  stateToDbValues,
  validateSyncOp,
  type EntityName,
} from '../src/sync/entities';
import { clampHlc, compareHlc, formatHlc, MAX_FUTURE_DRIFT_MS, parseHlc } from '../src/sync/hlc';
import { mergeOp, type MergeExistingState } from '../src/sync/merge';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const fixturePath = path.resolve(__dirname, '../../spec/fixtures/sync-ops.json');

describe('sync HLC', () => {
  it('parses and formats valid HLC strings and normalizes uppercase deviceId', () => {
    const raw = '1794715200000:0007:01932A1B-0000-7000-8000-000000000001';
    const parsed = parseHlc(raw);
    expect(parsed).toEqual({
      ms: 1794715200000,
      counter: 7,
      deviceId: '01932a1b-0000-7000-8000-000000000001',
    });
    expect(formatHlc(parsed!)).toBe('1794715200000:0007:01932a1b-0000-7000-8000-000000000001');
  });

  it('rejects malformed HLC strings', () => {
    expect(parseHlc('123:0000:dev')).toBeNull();
    expect(parseHlc('0000000000123:00:dev')).toBeNull();
    expect(parseHlc('0000000000123:0000:')).toBeNull();
    expect(parseHlc('0000000000123:0000:dev id')).toBeNull();
    expect(parseHlc('abcdefghijklm:0000:dev')).toBeNull();
    expect(parseHlc('no-colons')).toBeNull();
  });

  it('carries counter overflow into ms', () => {
    expect(formatHlc({ ms: 5000, counter: 10000, deviceId: 'DEV-A' })).toBe(
      '0000000005001:0000:dev-a',
    );
  });

  it('compares HLCs causally by ms, counter, then deviceId', () => {
    const a = '0000000000999:9999:zzz';
    const b = '0000000001000:0000:aaa';
    const c = '0000000001000:0001:aaa';
    const d = '0000000001000:0001:bbb';
    expect(compareHlc(a, b)).toBe(-1);
    expect(compareHlc(b, c)).toBe(-1);
    expect(compareHlc(c, d)).toBe(-1);
    expect(compareHlc(d, c)).toBe(1);
    expect(compareHlc(c, c)).toBe(0);
  });

  it('clamps HLCs more than 5 minutes ahead of server time and leaves boundary untouched', () => {
    const now = 1_700_000_000_000;
    const atLimit = formatHlc({ ms: now + MAX_FUTURE_DRIFT_MS, counter: 3, deviceId: 'dev1' });
    const atLimitRes = clampHlc(atLimit, now);
    expect(atLimitRes.clamped).toBe(false);
    expect(atLimitRes.formatted).toBe(atLimit);

    const tooFar = formatHlc({ ms: now + MAX_FUTURE_DRIFT_MS + 1, counter: 9, deviceId: 'dev1' });
    const clamped1 = clampHlc(tooFar, now);
    expect(clamped1.clamped).toBe(true);
    expect(clamped1.formatted).toBe(`${String(now).padStart(13, '0')}:0000:dev1`);

    // Monotonic within same millisecond when lastClamped is supplied
    const clamped2 = clampHlc(tooFar, now, clamped1.hlc);
    expect(clamped2.clamped).toBe(true);
    expect(clamped2.formatted).toBe(`${String(now).padStart(13, '0')}:0001:dev1`);
    expect(compareHlc(clamped2.formatted, clamped1.formatted)).toBe(1);
  });
});

describe('sync merge', () => {
  const hlc1 = '1700000000001:0000:dev-a';
  const hlc2 = '1700000000002:0000:dev-a';
  const hlc3 = '1700000000003:0000:dev-a';

  it('creates a missing row and sets clocks only for fields in op.fields', () => {
    const res = mergeOp(
      null,
      {
        entity: 'task',
        entityId: 't1',
        op: 'upsert',
        hlc: hlc1,
        fields: ['id', 'projectId', 'title', 'createdAt', 'updatedAt'],
        row: {
          id: 't1',
          projectId: 'p1',
          title: 'First',
          createdAt: 1000,
          updatedAt: 1000,
        },
      },
      1000,
    );

    expect(res.changed).toBe(true);
    expect(res.purgedAt).toBeNull();
    expect(res.clocks).toEqual({
      id: hlc1,
      projectId: hlc1,
      title: hlc1,
      createdAt: hlc1,
      updatedAt: hlc1,
    });
    const pub = serializePublicRow('task', res.row, res.purgedAt);
    expect(pub).toEqual({
      id: 't1',
      projectId: 'p1',
      title: 'First',
      content: '',
      priority: 0,
      status: 0,
      reminders: [],
      tags: [],
      sortKey: '',
      createdAt: 1000,
      updatedAt: 1000,
    });
  });

  it('only considers fields listed in op.fields and treats absent listed fields as null', () => {
    const created = mergeOp(
      null,
      {
        entity: 'task',
        entityId: 't1',
        op: 'upsert',
        hlc: hlc1,
        fields: ['id', 'projectId', 'title', 'content', 'repeatRule', 'createdAt', 'updatedAt'],
        row: {
          id: 't1',
          projectId: 'p1',
          title: 'Initial',
          content: 'Keep me',
          repeatRule: 'RRULE:FREQ=DAILY',
          createdAt: 1000,
          updatedAt: 1000,
        },
      },
      1000,
    );

    const updated = mergeOp(
      created,
      {
        entity: 'task',
        entityId: 't1',
        op: 'upsert',
        hlc: hlc2,
        fields: ['repeatRule'],
        row: {
          id: 't1',
          projectId: 'p1',
          title: 'Should be ignored because not in fields',
          content: 'Should also be ignored',
        },
      },
      2000,
    );

    expect(updated.changed).toBe(true);
    expect(updated.row.title).toBe('Initial');
    expect(updated.row.content).toBe('Keep me');
    expect(updated.row.repeatRule).toBeNull();
    expect(updated.clocks.repeatRule).toBe(hlc2);
    expect(updated.clocks.title).toBe(hlc1);
    expect(serializePublicRow('task', updated.row, null).repeatRule).toBeUndefined();
  });

  it('applies LWW strictly (HLC > clocks[field]); equal or older HLC loses', () => {
    const initial: MergeExistingState = {
      row: { id: 't1', projectId: 'p1', title: 'Newer', createdAt: 1000, updatedAt: 2000 },
      clocks: { title: hlc2, updatedAt: hlc2 },
      purgedAt: null,
    };

    const equalRes = mergeOp(
      initial,
      {
        entity: 'task',
        entityId: 't1',
        op: 'upsert',
        hlc: hlc2,
        fields: ['title'],
        row: { title: 'Equal' },
      },
      3000,
    );
    expect(equalRes.changed).toBe(false);
    expect(equalRes.row.title).toBe('Newer');

    const olderRes = mergeOp(
      initial,
      {
        entity: 'task',
        entityId: 't1',
        op: 'upsert',
        hlc: hlc1,
        fields: ['title'],
        row: { title: 'Older' },
      },
      3000,
    );
    expect(olderRes.changed).toBe(false);
    expect(olderRes.row.title).toBe('Newer');
    expect(olderRes.clocks.title).toBe(hlc2);
  });

  it('treats task schedule fields as one group with clock key "schedule"', () => {
    const s1 = mergeOp(
      null,
      {
        entity: 'task',
        entityId: 't1',
        op: 'upsert',
        hlc: hlc1,
        fields: ['id', 'projectId', 'title', 'startDay', 'startMinute', 'timeZone', 'createdAt', 'updatedAt'],
        row: {
          id: 't1',
          projectId: 'p1',
          title: 'Meeting',
          startDay: '2026-11-15',
          startMinute: 600,
          timeZone: 'Asia/Taipei',
          createdAt: 1000,
          updatedAt: 1000,
        },
      },
      1000,
    );
    expect(s1.clocks.schedule).toBe(hlc1);
    expect(s1.clocks.startDay).toBeUndefined();

    // Updating just startDay clears unspecified schedule fields (e.g. startMinute, timeZone) together
    const s2 = mergeOp(
      s1,
      {
        entity: 'task',
        entityId: 't1',
        op: 'upsert',
        hlc: hlc3,
        fields: ['startDay'],
        row: { startDay: '2026-11-20' },
      },
      2000,
    );
    expect(s2.changed).toBe(true);
    expect(s2.row.startDay).toBe('2026-11-20');
    expect(s2.row.startMinute).toBeNull();
    expect(s2.row.timeZone).toBeNull();
    expect(s2.clocks.schedule).toBe(hlc3);

    // Older HLC touching timeZone loses against newer schedule clock
    const s3 = mergeOp(
      s2,
      {
        entity: 'task',
        entityId: 't1',
        op: 'upsert',
        hlc: hlc2,
        fields: ['timeZone'],
        row: { timeZone: 'UTC' },
      },
      3000,
    );
    expect(s3.changed).toBe(false);
    expect(s3.row.startDay).toBe('2026-11-20');
    expect(s3.row.timeZone).toBeNull();
  });

  it('replaces array fields (reminders, tags) as whole values', () => {
    const s1 = mergeOp(
      null,
      {
        entity: 'task',
        entityId: 't1',
        op: 'upsert',
        hlc: hlc1,
        fields: ['reminders', 'tags'],
        row: { reminders: ['TRIGGER:-PT15M', 'TRIGGER:-PT5M'], tags: ['a', 'b'] },
      },
      1000,
    );
    const s2 = mergeOp(
      s1,
      {
        entity: 'task',
        entityId: 't1',
        op: 'upsert',
        hlc: hlc2,
        fields: ['tags'],
        row: { tags: ['c'] },
      },
      2000,
    );
    expect(s2.row.reminders).toEqual(['TRIGGER:-PT15M', 'TRIGGER:-PT5M']);
    expect(s2.row.tags).toEqual(['c']);
  });

  it('ignores non-synced fields (member.isMe, attachment.localPath, attachment.originalPath)', () => {
    const memberRes = mergeOp(
      null,
      {
        entity: 'member',
        entityId: 'm1',
        op: 'upsert',
        hlc: hlc1,
        fields: ['id', 'name', 'initial', 'color', 'isMe', 'createdAt', 'updatedAt'],
        row: {
          id: 'm1',
          name: 'Me',
          initial: 'M',
          color: '#fff',
          isMe: true,
          createdAt: 1000,
          updatedAt: 1000,
        },
      },
      1000,
    );
    expect(memberRes.clocks.isMe).toBeUndefined();
    expect(serializePublicRow('member', memberRes.row, null)).not.toHaveProperty('isMe');

    const onlyNonSynced = mergeOp(
      memberRes,
      {
        entity: 'member',
        entityId: 'm1',
        op: 'upsert',
        hlc: hlc2,
        fields: ['isMe'],
        row: { isMe: false },
      },
      2000,
    );
    expect(onlyNonSynced.changed).toBe(false);

    const attRes = mergeOp(
      null,
      {
        entity: 'attachment',
        entityId: 'a1',
        op: 'upsert',
        hlc: hlc1,
        fields: ['id', 'taskId', 'fileName', 'size', 'mimeType', 'localPath', 'originalPath', 'createdAt', 'updatedAt'],
        row: {
          id: 'a1',
          taskId: 't1',
          fileName: 'doc.pdf',
          size: 42,
          mimeType: 'application/pdf',
          localPath: 'a1.pdf',
          originalPath: '/tmp/doc.pdf',
          createdAt: 1000,
          updatedAt: 1000,
        },
      },
      1000,
    );
    expect(attRes.clocks.localPath).toBeUndefined();
    expect(attRes.clocks.originalPath).toBeUndefined();
    const pubAtt = serializePublicRow('attachment', attRes.row, null);
    expect(pubAtt).not.toHaveProperty('localPath');
    expect(pubAtt).not.toHaveProperty('originalPath');
  });

  it('sets purgedAt on delete and ignores subsequent upserts to purged rows', () => {
    const created = mergeOp(
      null,
      {
        entity: 'task',
        entityId: 't1',
        op: 'upsert',
        hlc: hlc1,
        fields: ['id', 'projectId', 'title', 'createdAt', 'updatedAt'],
        row: { id: 't1', projectId: 'p1', title: 'Doomed', createdAt: 1000, updatedAt: 1000 },
      },
      1000,
    );

    const deleted = mergeOp(
      created,
      {
        entity: 'task',
        entityId: 't1',
        op: 'delete',
        hlc: hlc2,
        fields: [],
        row: {},
      },
      5000,
    );
    expect(deleted.changed).toBe(true);
    expect(deleted.purgedAt).toBe(5000);

    const afterPurgeUpsert = mergeOp(
      deleted,
      {
        entity: 'task',
        entityId: 't1',
        op: 'upsert',
        hlc: hlc3,
        fields: ['title'],
        row: { title: 'Resurrected' },
      },
      6000,
    );
    expect(afterPurgeUpsert.changed).toBe(false);
    expect(afterPurgeUpsert.purgedAt).toBe(5000);
    expect(afterPurgeUpsert.row.title).toBe('Doomed');

    const duplicateDelete = mergeOp(
      deleted,
      {
        entity: 'task',
        entityId: 't1',
        op: 'delete',
        hlc: hlc3,
        fields: [],
        row: {},
      },
      7000,
    );
    expect(duplicateDelete.changed).toBe(false);
    expect(duplicateDelete.purgedAt).toBe(5000);
  });

  it('validates ops and rejects malformed shapes', () => {
    expect(validateSyncOp({ opId: 'o1', entity: 'bogus', entityId: '1', op: 'upsert', hlc: hlc1, fields: [], row: {} })).toMatchObject({
      ok: false,
      opId: 'o1',
    });
    expect(validateSyncOp({ opId: 'o2', entity: 'task', entityId: '1', op: 'drop', hlc: hlc1, fields: [], row: {} })).toMatchObject({
      ok: false,
      opId: 'o2',
    });
    expect(validateSyncOp({ opId: 'o3', entity: 'task', entityId: '1', op: 'upsert', hlc: 'bad', fields: [], row: {} })).toMatchObject({
      ok: false,
      opId: 'o3',
    });
    expect(validateSyncOp({ opId: 'o4', entity: 'projectMember', entityId: 'only-one-part', op: 'upsert', hlc: hlc1, fields: [], row: {} })).toMatchObject({
      ok: false,
      opId: 'o4',
    });
    expect(validateSyncOp({ opId: 'o5', entity: 'task', entityId: 't1', op: 'upsert', hlc: hlc1, fields: ['priority'], row: { priority: 'high' } })).toMatchObject({
      ok: false,
      opId: 'o5',
    });
    expect(validateSyncOp({ opId: 'o6', entity: 'task', entityId: 't1', op: 'upsert', hlc: hlc1, fields: ['title'], row: { title: null } })).toMatchObject({
      ok: false,
      opId: 'o6',
    });
    expect(validateSyncOp({ opId: 'o7', entity: 'task', entityId: 't1', op: 'upsert', hlc: hlc1, fields: ['id'], row: { id: 't2' } })).toMatchObject({
      ok: false,
      opId: 'o7',
    });
  });

  it('round-trips DB encoding (booleans, arrays) and applies all ops in spec/fixtures/sync-ops.json', () => {
    const fixture = JSON.parse(readFileSync(fixturePath, 'utf8')) as { ops: Array<Record<string, unknown>> };
    const stateMap = new Map<string, { entity: EntityName; state: MergeExistingState }>();

    for (const rawOp of fixture.ops) {
      const validated = validateSyncOp(rawOp);
      expect(validated.ok).toBe(true);
      if (!validated.ok) continue;
      const op = validated.op;
      const key = `${op.entity}:${op.entityId}`;
      const existing = stateMap.get(key)?.state ?? null;
      const merged = mergeOp(existing, op, 1794715200999);
      stateMap.set(key, {
        entity: op.entity,
        state: {
          row: merged.row,
          clocks: merged.clocks,
          purgedAt: merged.purgedAt,
        },
      });
    }

    // Verify DB serialization round-trip on project (isInbox boolean) and task (arrays)
    const inbox = stateMap.get('project:01a1dd14-d0d4-7537-9830-45c44251a77f')!;
    const dbVals = stateToDbValues('project', {
      ...inbox.state,
      ownerUserId: 'u1',
      serverSeq: 2,
    });
    expect(dbVals.isInbox).toBe(1);
    const restored = dbRecordToState('project', dbVals);
    expect(serializePublicRow('project', restored.row, restored.purgedAt).isInbox).toBe(true);

    // Verify recurring task got updated to 2026-11-22 while keeping startMinute/endMinute/timeZone
    const recurring = serializePublicRow(
      'task',
      stateMap.get('task:01a1dd14-d0d8-76cf-a7a7-11627263cc73')!.state.row,
      stateMap.get('task:01a1dd14-d0d8-76cf-a7a7-11627263cc73')!.state.purgedAt,
    );
    expect(recurring.startDay).toBe('2026-11-22');
    expect(recurring.endDay).toBe('2026-11-22');
    expect(recurring.startMinute).toBe(1140);
    expect(recurring.endMinute).toBe(1230);
    expect(recurring.timeZone).toBe('Asia/Taipei');

    // Verify cleared + soft-deleted + purged task
    const purgedEntry = stateMap.get('task:01a1dd14-d0da-7615-9fc9-b489db47b969')!.state;
    const purgedRow = serializePublicRow('task', purgedEntry.row, purgedEntry.purgedAt);
    expect(purgedRow.repeatRule).toBeUndefined();
    expect(purgedRow.startDay).toBeUndefined();
    expect(purgedRow.startMinute).toBeUndefined();
    expect(purgedRow.timeZone).toBeUndefined();
    expect(purgedRow.deletedAt).toBe(1794715200000);
    expect(purgedRow.purgedAt).toBe(1794715200999);
  });
});
