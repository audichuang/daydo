import { eq } from 'drizzle-orm';
import { describe, expect, it } from 'vitest';
import * as schema from '../db/schema';
import { acceptInvite, createInvite } from '../src/sharing';
import { parseHlc } from '../src/sync/hlc';
import { loadSnapshot } from '../src/serverops/snapshot';
import {
  NO_DATA_MESSAGE,
  WriteError,
  WriteValidationError,
  pushIntents,
  writeOrThrow,
  type WriteIntent,
} from '../src/serverops/writer';
import { MAX_OPS_PER_PUSH } from '../src/sync/envelope';
import { createScopeWorld } from './helpers/scopeWorld';

function createHarness() {
  const { db, calls, clock, getScopeStub, push } = createScopeWorld();
  let seq = 0;
  // Device HLCs sit in the past unless a test asks for a lead.
  const deviceHlc = (ms = Date.now() - 60_000) => `${ms}:${String(seq++ % 10000).padStart(4, '0')}:dev-a`;
  const devicePush = (userId: string, ops: unknown[]) => push(userId, 'dev-a', ops);
  const deps = (userId: string) => ({ db, userId, deviceId: 'mcp' as const, getScopeStub, clock });
  const snapshot = (userId: string) => loadSnapshot(db, userId, getScopeStub);
  return { db, calls, deviceHlc, devicePush, deps, snapshot };
}

type Harness = ReturnType<typeof createHarness>;

const NOW_ISH = 1_700_000_000_000;

function projectRow(id: string, extra: Record<string, unknown> = {}) {
  return {
    id, name: id, viewMode: 'list', kind: 'TASK', isInbox: false, ownerId: 'm-a',
    sortKey: 'a0', showInSmart: 'all', notifyMode: 'all', createdAt: NOW_ISH, updatedAt: NOW_ISH,
    ...extra,
  };
}

function taskRow(id: string, projectId: string, extra: Record<string, unknown> = {}) {
  return {
    id, projectId, title: id, content: '', priority: 0, status: 0, sortKey: 'a0',
    reminders: [], tags: [], createdAt: NOW_ISH, updatedAt: NOW_ISH, ...extra,
  };
}

function deviceOp(h: Harness, entity: string, row: Record<string, unknown>, hlc = h.deviceHlc()) {
  return {
    opId: `dev-${entity}-${String(row.id)}-${hlc}`,
    hlc,
    entity,
    entityId: String(row.id),
    op: 'upsert',
    fields: Object.keys(row),
    row,
  };
}

async function seedUser(h: Harness, userId: string, memberId: string | null, withInbox = true) {
  await h.db.insert(schema.user).values({
    id: userId, name: userId, initial: userId[0], color: '#007AFF', avatarUrl: null,
    createdAt: NOW_ISH,
  });
  if (memberId) {
    await h.db.update(schema.user).set({ meMemberId: memberId }).where(eq(schema.user.id, userId));
  }
  if (withInbox) {
    const res = await h.devicePush(userId, [
      deviceOp(h, 'project', projectRow(`inbox-${userId}`, { isInbox: true, ownerId: memberId ?? '' })),
    ]);
    expect(res.results[0]?.status).toBe('applied');
  }
}

/** u-a with inbox, list p1 and task t1 (scheduled). */
async function seedBasic(h: Harness) {
  await seedUser(h, 'u-a', 'm-a');
  const res = await h.devicePush('u-a', [
    deviceOp(h, 'project', projectRow('p1')),
    deviceOp(
      h,
      'task',
      taskRow('t1', 'p1', {
        startDay: '2026-11-20', startMinute: 540, endDay: '2026-11-20', endMinute: 600,
        timeZone: 'Asia/Taipei', reminders: ['TRIGGER:PT0S'],
      }),
    ),
  ]);
  expect(res.results.map((r) => r.status)).toEqual(['applied', 'applied']);
}

describe('M9b writer: no-data account', () => {
  it('rejects writes when meMemberId is missing, before pushing anything', async () => {
    const h = createHarness();
    await seedUser(h, 'u-a', null);
    const snap = await h.snapshot('u-a');
    h.calls.length = 0;
    await expect(
      writeOrThrow(h.deps('u-a'), snap, [
        { entity: 'task', entityId: 't-new', set: taskRow('t-new', 'inbox-u-a') },
      ]),
    ).rejects.toThrow(NO_DATA_MESSAGE);
    expect(h.calls).toEqual([]);
  });

  it('rejects writes when the account has no inbox', async () => {
    const h = createHarness();
    await seedUser(h, 'u-a', 'm-a', false);
    const snap = await h.snapshot('u-a');
    await expect(pushIntents(h.deps('u-a'), snap, [])).rejects.toThrow(NO_DATA_MESSAGE);
    expect(h.calls).toEqual([]);
  });
});

describe('M9b writer: ops and HLC', () => {
  it('creates a new row with a fresh UUIDv7 opId and the mcp device id', async () => {
    const h = createHarness();
    await seedBasic(h);
    const snap = await h.snapshot('u-a');
    h.calls.length = 0;
    const [out] = await writeOrThrow(h.deps('u-a'), snap, [
      { entity: 'task', entityId: 't-new', set: taskRow('t-new', 'p1', { title: 'hello', sortKey: 'h' }) },
    ]);
    expect(out?.status).toBe('applied');
    expect(out?.row?.title).toBe('hello');
    const op = h.calls[0]!.ops[0]!;
    expect(h.calls[0]!.deviceId).toBe('mcp');
    expect(op.opId).toMatch(/^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
    expect(String(op.hlc)).toMatch(/:server$/);
  });

  it('updates a row the phone stamped ahead of the server clock (max clock + 1)', async () => {
    const h = createHarness();
    await seedBasic(h);
    const lead = Date.now() + 3 * 60_000;
    const res = await h.devicePush('u-a', [
      { ...deviceOp(h, 'task', { id: 't1', title: 'phone' }, `${lead}:0000:dev-a`), fields: ['title'] },
    ]);
    expect(res.results[0]?.status).toBe('applied');
    const snap = await h.snapshot('u-a');
    h.calls.length = 0;
    const [out] = await writeOrThrow(h.deps('u-a'), snap, [
      { entity: 'task', entityId: 't1', set: { title: 'mcp' } },
    ]);
    expect(out?.status).toBe('applied');
    expect(out?.row?.title).toBe('mcp');
    const hlc = parseHlc(String(h.calls[0]!.ops[0]!.hlc))!;
    expect(hlc.ms).toBe(lead + 1);
    expect(hlc.deviceId).toBe('server');
    // The snapshot row is refreshed from the response.
    expect(snap.findRow('task', 't1')?.row.title).toBe('mcp');
  });

  it('reports fields that lost to a phone edit after the snapshot, without resending', async () => {
    const h = createHarness();
    await seedBasic(h);
    const snap = await h.snapshot('u-a');
    const lead = Date.now() + 3 * 60_000;
    await h.devicePush('u-a', [
      { ...deviceOp(h, 'task', { id: 't1', title: 'phone' }, `${lead}:0000:dev-a`), fields: ['title'] },
    ]);
    h.calls.length = 0;
    const intents: WriteIntent[] = [{ entity: 'task', entityId: 't1', set: { title: 'mcp', priority: 3 } }];
    const [out] = await pushIntents(h.deps('u-a'), snap, intents);
    expect(out?.status).toBe('unapplied');
    expect(out?.unappliedFields).toEqual(['title']);
    expect(out?.row?.title).toBe('phone');
    expect(out?.row?.priority).toBe(3);
    expect(h.calls).toHaveLength(1);

    // Same situation through writeOrThrow surfaces a tool error naming the field and the server row.
    const snap2 = await h.snapshot('u-a');
    await h.devicePush('u-a', [
      {
        ...deviceOp(h, 'task', { id: 't1', title: 'phone2' }, `${lead + 1000}:0000:dev-a`),
        fields: ['title'],
      },
    ]);
    const err = await writeOrThrow(h.deps('u-a'), snap2, [
      { entity: 'task', entityId: 't1', set: { title: 'mcp2' } },
    ]).catch((e: unknown) => e);
    expect(err).toBeInstanceOf(WriteError);
    expect((err as WriteError).outcome.unappliedFields).toEqual(['title']);
    expect((err as Error).message).toContain('title');
    expect((err as Error).message).toContain('phone2');
  });

  it('increments the counter for several ops on the same row in one call', async () => {
    const h = createHarness();
    await seedBasic(h);
    const snap = await h.snapshot('u-a');
    h.calls.length = 0;
    await writeOrThrow(h.deps('u-a'), snap, [
      { entity: 'task', entityId: 't1', set: { title: 'a' } },
      { entity: 'task', entityId: 't1', set: { content: 'b' } },
    ]);
    const [a, b] = h.calls[0]!.ops.map((o) => parseHlc(String(o.hlc))!);
    expect(b!.ms).toBe(a!.ms);
    expect(b!.counter).toBe(a!.counter + 1);
    expect(snap.findRow('task', 't1')?.row).toMatchObject({ title: 'a', content: 'b' });
  });

  it('chunks at 200 ops with tasks ahead of their child rows', async () => {
    const h = createHarness();
    await seedBasic(h);
    const snap = await h.snapshot('u-a');
    h.calls.length = 0;
    const items: WriteIntent[] = Array.from({ length: 205 }, (_, i) => ({
      entity: 'checklistItem',
      entityId: `c-${i}`,
      set: {
        id: `c-${i}`, taskId: 't-big', title: `item ${i}`, status: 0, sortKey: 'i',
        createdAt: NOW_ISH, updatedAt: NOW_ISH,
      },
    }));
    const outs = await writeOrThrow(h.deps('u-a'), snap, [
      ...items,
      { entity: 'task', entityId: 't-big', set: taskRow('t-big', 'p1', { sortKey: 'h' }) },
    ]);
    expect(MAX_OPS_PER_PUSH).toBe(200);
    expect(h.calls.map((c) => c.ops.length)).toEqual([200, 6]);
    expect(h.calls[0]!.ops[0]!.entity).toBe('task');
    expect(outs).toHaveLength(206);
    expect(outs.every((o) => o.status === 'applied')).toBe(true);
    // Outcomes stay in intent order.
    expect(outs[205]?.entity).toBe('task');
  });

  it('flags a tombstoned row as purged instead of an LWW loss', async () => {
    const h = createHarness();
    await seedBasic(h);
    const snap = await h.snapshot('u-a');
    await h.devicePush('u-a', [
      { opId: 'dev-del-t1', hlc: h.deviceHlc(), entity: 'task', entityId: 't1', op: 'delete', fields: [], row: {} },
    ]);
    const [out] = await pushIntents(h.deps('u-a'), snap, [
      { entity: 'task', entityId: 't1', set: { title: 'late' } },
    ]);
    expect(out?.status).toBe('purged');
    expect(out?.row?.purgedAt).toBeTypeOf('number');
 
    const err = await writeOrThrow(h.deps('u-a'), snap, [
      { entity: 'task', entityId: 't1', set: { title: 'later' } },
    ]).catch((e: unknown) => e);
    expect(err).toBeInstanceOf(WriteError);
    expect((err as WriteError).outcome.status).toBe('purged');
  });

  it('keeps caller order for lists and tasks (tasks trashed before their list)', async () => {
    const h = createHarness();
    await seedBasic(h);
    const snap = await h.snapshot('u-a');
    h.calls.length = 0;
    const now = Date.now();
    await writeOrThrow(h.deps('u-a'), snap, [
      { entity: 'task', entityId: 't1', set: { deletedAt: now, updatedAt: now } },
      { entity: 'project', entityId: 'p1', set: { deletedAt: now, updatedAt: now } },
    ]);
    expect(h.calls[0]!.ops.map((o) => o.entity)).toEqual(['task', 'project']);
  });
});

describe('M9b writer: permissions', () => {
  it('turns a viewer list write into the server Forbidden error', async () => {
    const h = createHarness();
    await seedBasic(h);
    await seedUser(h, 'u-b', 'm-b');
    const invite = await createInvite(h.db, {
      userId: 'u-a', projectId: 'p1', role: 'viewer', nowMs: Date.now(),
    });
    await acceptInvite(h.db, {
      code: invite.code, userId: 'u-b', getScopeStub: (s) => h.deps('u-b').getScopeStub(s), nowMs: Date.now(),
    });
    const snap = await h.snapshot('u-b');
    expect(snap.findRow('task', 't1')).toBeDefined();
    h.calls.length = 0;
    const [out] = await pushIntents(h.deps('u-b'), snap, [
      { entity: 'task', entityId: 't1', set: { title: 'nope' } },
    ]);
    expect(h.calls).toHaveLength(1);
    expect(out?.status).toBe('rejected');
    expect(out?.reason).toBe('Forbidden');
    await expect(
      writeOrThrow(h.deps('u-b'), snap, [{ entity: 'task', entityId: 't1', set: { title: 'nope' } }]),
    ).rejects.toThrow('Forbidden');
  });
});

describe('M9b writer: schedule group', () => {
  it('sends all five schedule fields when only the due changes', async () => {
    const h = createHarness();
    await seedBasic(h);
    const snap = await h.snapshot('u-a');
    h.calls.length = 0;
    const [out] = await writeOrThrow(h.deps('u-a'), snap, [
      { entity: 'task', entityId: 't1', set: { endDay: '2026-11-21', endMinute: 660 } },
    ]);
    const op = h.calls[0]!.ops[0]!;
    expect([...(op.fields as string[])].sort()).toEqual(
      ['endDay', 'endMinute', 'startDay', 'startMinute', 'timeZone', 'updatedAt'],
    );
    expect(op.row).toMatchObject({
      startDay: '2026-11-20', startMinute: 540, endDay: '2026-11-21', endMinute: 660,
      timeZone: 'Asia/Taipei',
    });
    expect(out?.row).toMatchObject({
      startDay: '2026-11-20', startMinute: 540, endDay: '2026-11-21', endMinute: 660,
      timeZone: 'Asia/Taipei',
    });
  });

  it('sends only the delta for an existing row, never the key or createdAt', async () => {
    const h = createHarness();
    await seedBasic(h);
    const snap = await h.snapshot('u-a');
    h.calls.length = 0;
    await writeOrThrow(h.deps('u-a'), snap, [
      { entity: 'task', entityId: 't1', set: { id: 't1', createdAt: 5, title: 'x', updatedAt: Date.now() } },
    ]);
    expect([...(h.calls[0]!.ops[0]!.fields as string[])].sort()).toEqual(['title', 'updatedAt']);
  });
});

describe('writer: createdAt and updatedAt stamps', () => {
  const LATER = NOW_ISH + 5_000;

  it('stamps a new row with createdAt and updatedAt from nowMs', async () => {
    const h = createHarness();
    await seedBasic(h);
    const snap = await h.snapshot('u-a');
    h.calls.length = 0;
    const { createdAt: _c, updatedAt: _u, ...set } = taskRow('t-new', 'p1', { sortKey: 'h' });
    const [out] = await writeOrThrow(h.deps('u-a'), snap, [{ entity: 'task', entityId: 't-new', set }], { nowMs: LATER });
    expect(out?.status).toBe('applied');
    const op = h.calls[0]!.ops[0]!;
    expect(op.fields).toEqual(expect.arrayContaining(['createdAt', 'updatedAt']));
    expect(op.row).toMatchObject({ createdAt: LATER, updatedAt: LATER });
  });

  it('bumps updatedAt on a delta write: nowMs, or one past a row stamped ahead of it', async () => {
    const h = createHarness();
    await seedBasic(h);
    const snap = await h.snapshot('u-a');
    h.calls.length = 0;
    await pushIntents(h.deps('u-a'), snap, [{ entity: 'task', entityId: 't1', set: { title: 'a' } }], { nowMs: LATER });
    expect([...(h.calls[0]!.ops[0]!.fields as string[])].sort()).toEqual(['title', 'updatedAt']);
    expect(h.calls[0]!.ops[0]!.row).toMatchObject({ updatedAt: LATER });
    // The row now says LATER; an earlier clock still moves it forward.
    await writeOrThrow(h.deps('u-a'), snap, [{ entity: 'task', entityId: 't1', set: { title: 'b' } }], { nowMs: NOW_ISH });
    expect(h.calls[1]!.ops[0]!.row).toMatchObject({ updatedAt: LATER + 1 });
  });

  it('keeps an updatedAt the caller gives', async () => {
    const h = createHarness();
    await seedBasic(h);
    const snap = await h.snapshot('u-a');
    h.calls.length = 0;
    await writeOrThrow(h.deps('u-a'), snap, [{ entity: 'task', entityId: 't1', set: { title: 'a', updatedAt: 42 } }], { nowMs: LATER });
    expect(h.calls[0]!.ops[0]!.row).toMatchObject({ updatedAt: 42 });
  });

  it('refuses a write with no delta and pushes nothing (no bare updatedAt bump)', async () => {
    const h = createHarness();
    await seedBasic(h);
    const snap = await h.snapshot('u-a');
    h.calls.length = 0;
    for (const set of [{}, { id: 't1', createdAt: 5 }]) {
      await expect(writeOrThrow(h.deps('u-a'), snap, [{ entity: 'task', entityId: 't1', set }])).rejects.toThrow(
        'Nothing to write for task t1',
      );
    }
    expect(h.calls).toEqual([]);
  });

  it('touch writes only updatedAt', async () => {
    const h = createHarness();
    await seedBasic(h);
    const snap = await h.snapshot('u-a');
    h.calls.length = 0;
    const [out] = await writeOrThrow(h.deps('u-a'), snap, [{ entity: 'task', entityId: 't1', set: {}, touch: true }], { nowMs: LATER });
    expect(out?.status).toBe('applied');
    expect(h.calls[0]!.ops[0]!.fields).toEqual(['updatedAt']);
    expect(out?.row?.updatedAt).toBe(LATER);
  });
});

describe('M9b writer: value validation', () => {
  const bad: Array<[string, WriteIntent]> = [
    ['priority', { entity: 'task', entityId: 't1', set: { priority: 2 } }],
    ['task status', { entity: 'task', entityId: 't1', set: { status: 1 } }],
    ['startDay unpadded', { entity: 'task', entityId: 't1', set: { startDay: '2026-11-5' } }],
    ['startDay unreal', { entity: 'task', entityId: 't1', set: { startDay: '2026-02-30' } }],
    ['endMinute', { entity: 'task', entityId: 't1', set: { endMinute: 1440 } }],
    ['startMinute', { entity: 'task', entityId: 't1', set: { startMinute: -1 } }],
    ['timeZone', { entity: 'task', entityId: 't1', set: { timeZone: 'Mars/Olympus' } }],
    ['timeZone casing', { entity: 'task', entityId: 't1', set: { timeZone: 'asia/taipei' } }],
    ['reminder', { entity: 'task', entityId: 't1', set: { reminders: ['TRIGGER:soon'] } }],
    ['reminder beyond a year', { entity: 'task', entityId: 't1', set: { reminders: ['TRIGGER:-P999999999999999D'] } }],
    ['repeat interval above 999', { entity: 'task', entityId: 't1', set: { repeatRule: 'RRULE:FREQ=YEARLY;INTERVAL=8000' } }],
    ['repeat interval beyond a safe integer', { entity: 'task', entityId: 't1', set: { repeatRule: 'RRULE:FREQ=WEEKLY;INTERVAL=9223372036854775807' } }],
    ['repeat', { entity: 'task', entityId: 't1', set: { repeatRule: 'RRULE:FREQ=MONTHLY;BYMONTHDAY=-1' } }],
    ['sortKey ends in 0', { entity: 'task', entityId: 't1', set: { sortKey: 'i0' } }],
    ['sortKey empty', { entity: 'task', entityId: 't1', set: { sortKey: '' } }],
    ['done without completedAt', { entity: 'task', entityId: 't1', set: { status: 2 } }],
    ['completedAt while open', { entity: 'task', entityId: 't1', set: { completedAt: 5 } }],
    [
      'reminders without schedule',
      {
        entity: 'task', entityId: 't1',
        set: { startDay: null, startMinute: null, endDay: null, endMinute: null, timeZone: null },
      },
    ],
    [
      'repeat without schedule',
      { entity: 'task', entityId: 't-new', set: taskRow('t-new', 'p1', { repeatRule: 'RRULE:FREQ=DAILY', sortKey: 'h' }) },
    ],
    [
      'checklist status',
      {
        entity: 'checklistItem', entityId: 'c1',
        set: { id: 'c1', taskId: 't1', title: 'c', status: 2, sortKey: 'i', createdAt: 1, updatedAt: 1 },
      },
    ],
    ['project owner', { entity: 'project', entityId: 'p-x', set: projectRow('p-x', { ownerId: 'm-z', sortKey: 'b' }) }],
    ['project inbox', { entity: 'project', entityId: 'p-x', set: projectRow('p-x', { isInbox: true, sortKey: 'b' }) }],
    ['missing required field on a new row', { entity: 'task', entityId: 't-new', set: { id: 't-new', title: 'x' } }],
    ['wrong type', { entity: 'task', entityId: 't1', set: { title: 5 } }],
  ];

  it.each(bad)('blocks %s before pushing', async (_name, intent) => {
    const h = createHarness();
    await seedBasic(h);
    const snap = await h.snapshot('u-a');
    h.calls.length = 0;
    await expect(writeOrThrow(h.deps('u-a'), snap, [intent])).rejects.toBeInstanceOf(WriteValidationError);
    expect(h.calls).toEqual([]);
  });

  it('accepts good values, verbatim copied sort keys and untouched legacy values', async () => {
    const h = createHarness();
    await seedBasic(h);
    const snap = await h.snapshot('u-a');
    const now = Date.now();
    const outs = await writeOrThrow(h.deps('u-a'), snap, [
      // t1 keeps its App sortKey 'a0' (ends in 0) and is still editable.
      { entity: 'task', entityId: 't1', set: { status: 2, completedAt: now, priority: 5 } },
      {
        entity: 'task', entityId: 't-copy',
        set: taskRow('t-copy', 'p1', { status: 2, completedAt: now, sortKey: 'a0' }),
        verbatim: ['sortKey'],
      },
      {
        entity: 'task', entityId: 't-rep',
        set: taskRow('t-rep', 'p1', {
          sortKey: 'h', startDay: '2026-11-20', startMinute: null, endDay: null, endMinute: null,
          timeZone: null, repeatRule: 'RRULE:FREQ=WEEKLY;BYDAY=MO', reminders: ['TRIGGER:-P1D'],
        }),
      },
      {
        entity: 'checklistItem', entityId: 'c1',
        set: { id: 'c1', taskId: 't1', title: 'c', status: 1, sortKey: 'i', createdAt: now, updatedAt: now },
      },
      { entity: 'project', entityId: 'p-x', set: projectRow('p-x', { sortKey: 'b' }) },
    ]);
    expect(outs.map((o) => o.status)).toEqual(['applied', 'applied', 'applied', 'applied', 'applied']);
  });
});
