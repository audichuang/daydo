import { describe, expect, it, vi } from 'vitest';
import { acceptInvite, createInvite } from '../src/sharing';
import {
  HINTS,
  TOOL_DEFS,
} from '../src/mcp/registry';
import { advancingNow } from './helpers/advancingClock';
import {
  call,
  createServerHarness,
  deviceOp,
  NOW_ISH,
  seedBasic,
  seedUser,
  taskRow,
  pulled,
} from './helpers/serverHarness';

function createHarness() {
  // One-shot: runs before the next MCP push reaches the scope (simulates a phone edit in between).
  const hooks: { beforeMcpPush?: () => Promise<unknown> } = {};
  const world = createServerHarness({
    onPush: async (input, proceed) => {
      if (input.deviceId === 'mcp' && hooks.beforeMcpPush) {
        const hook = hooks.beforeMcpPush;
        hooks.beforeMcpPush = undefined;
        await hook();
      }
      return proceed(input);
    },
  });
  return { ...world, hooks };
}

type Harness = ReturnType<typeof createHarness>;

/** u-a (owner of p1, with t1), u-b as `role` on p1. */
async function seedShared(h: Harness, role: 'viewer' | 'editor') {
  await seedBasic(h);
  await seedUser(h, 'u-b', 'm-b');
  const invite = await createInvite(h.db, { userId: 'u-a', projectId: 'p1', role, nowMs: Date.now() });
  await acceptInvite(h.db, {
    code: invite.code, userId: 'u-b', getScopeStub: (s) => h.deps('u-b').getScopeStub(s), nowMs: Date.now(),
  });
}

const mcpOps = (h: Harness) => h.calls.filter((c) => c.deviceId === 'mcp').flatMap((c) => c.ops);

const WRITE_TOOLS: Record<string, string> = {
  create_task: 'write',
  update_task: 'idempotent-overwrite',
  delete_task: 'destructive',
  move_task: 'idempotent-write',
  move_all: 'idempotent-write',
};

describe('M11b registry', () => {
  it('registers the write tools with hints, without TickTick wording or a kind field', async () => {
    for (const [name, hint] of Object.entries(WRITE_TOOLS)) {
      const def = TOOL_DEFS.find((t) => t.name === name);
      expect(def, name).toBeDefined();
      expect(HINTS[name]).toBe(hint);
      expect(def!.description).not.toMatch(/ticktick/i);
      expect(Object.keys(def!.inputSchema.properties)).not.toContain('kind');
    }
    expect(TOOL_DEFS.find((t) => t.name === 'delete_task')!.description).toMatch(/trash/i);
  });

  it('rejects kind as an unknown argument without pushing', async () => {
    const h = createHarness();
    await seedBasic(h);
    h.calls.length = 0;
    const c = await call(h, 'u-a', 'create_task', { project_id: 'p1', title: 'x', kind: 'TEXT' });
    expect(c.isError).toBe(true);
    expect(c.text).toContain("Unknown argument 'kind'");
    const u = await call(h, 'u-a', 'update_task', { project_id: 'p1', task_id: 't1', kind: 'NOTE' });
    expect(u.isError).toBe(true);
    expect(h.calls).toEqual([]);
  });
});

describe('M11b create_task', () => {
  // Sort keys, tag rows and checklist rows follow the App; see task-writes.test.ts.
  it('creates a full task that another device pulls, with checklist and tag rows', async () => {
    const h = createHarness();
    await seedBasic(h);
    const r = await call(h, 'u-a', 'create_task', {
      project_id: 'p1',
      title: '  Dentist  ',
      content: 'line1\\nline2\\r\\nline3',
      priority: 'high',
      start: '2026-12-01T13:00:00+0800',
      due: '2026-12-01T14:00:00+08:00',
      reminder: 'TRIGGER:-PT24H, TRIGGER:PT0S',
      repeat: 'FREQ=WEEKLY',
      subtasks: ['bring card', '  ', 'pay'],
      tags: ['#Work', 'work', 'Home'],
    });
    expect(r.isError, r.text).toBe(false);
    expect(r.json).toMatchObject({
      project_id: 'p1',
      title: 'Dentist',
      content: 'line1\nline2\nline3',
      priority: 5,
      status: 0,
      start: '2026-12-01T13:00:00+08:00',
      due: '2026-12-01T14:00:00+08:00',
      all_day: false,
      timezone: 'Asia/Taipei',
      reminders: ['TRIGGER:-P1D', 'TRIGGER:PT0S'],
      repeat: 'RRULE:FREQ=WEEKLY',
      tags: ['work', 'home'],
    });
    expect(r.json.items.map((i: any) => [i.title, i.status])).toEqual([['bring card', 0], ['pay', 0]]);
    expect(r.json.items[0].sort_key < r.json.items[1].sort_key).toBe(true);

    const res = await h.pull('u-a');
    const task = pulled(res, 'task', r.json.id);
    expect(task).toMatchObject({ projectId: 'p1', title: 'Dentist', startDay: '2026-12-01', startMinute: 780, endMinute: 840 });
    // New task goes first in its list: before(MIN) of the existing 'a0'.
    expect(String(task!.sortKey) < 'a0').toBe(true);
    for (const item of r.json.items) {
      const row = pulled(res, 'checklistItem', item.id);
      expect(row?.taskId).toBe(r.json.id);
      expect(row?.deletedAt ?? null).toBeNull();
    }
    expect(pulled(res, 'tag', 'work')).toMatchObject({ label: 'Work' });
    expect(pulled(res, 'tag', 'home')).toMatchObject({ label: 'Home' });
    const tags = await call(h, 'u-a', 'list_tags');
    expect(tags.json.map((t: any) => t.name)).toEqual(['work', 'home']);
  });

  it('handles all-day, floating and offset-inferred schedules', async () => {
    const h = createHarness();
    await seedBasic(h);
    const allDay = await call(h, 'u-a', 'create_task', { project_id: 'p1', title: 'a', start: '2026-12-01', due: '2026-12-03' });
    expect(allDay.json).toMatchObject({ start: '2026-12-01', due: '2026-12-03', all_day: true, timezone: null });
    const floating = await call(h, 'u-a', 'create_task', { project_id: 'p1', title: 'f', start: '2026-12-01T09:30' });
    expect(floating.json).toMatchObject({ start: '2026-12-01T09:30:00', all_day: false, timezone: null });
    const tokyo = await call(h, 'u-a', 'create_task', { project_id: 'p1', title: 't', start: '2026-12-01T09:30:00+09:00' });
    expect(tokyo.json).toMatchObject({ start: '2026-12-01T09:30:00+09:00', timezone: 'Asia/Tokyo' });
    const zoned = await call(h, 'u-a', 'create_task', {
      project_id: 'p1', title: 'z', start: '2026-12-01T09:30:00+08:00', timezone: 'Europe/London',
    });
    expect(zoned.json).toMatchObject({ start: '2026-12-01T01:30:00Z', timezone: 'Europe/London' });
    const plain = await call(h, 'u-a', 'create_task', { project_id: 'p1', title: 'p' });
    expect(plain.json).toMatchObject({ start: null, due: null, reminders: [], repeat: null, items: [], tags: [] });
  });

  it('rejects bad input before pushing', async () => {
    const h = createHarness();
    await seedBasic(h);
    h.calls.length = 0;
    const bad: Array<[Record<string, unknown>, string]> = [
      [{ title: 'x', reminder: 'TRIGGER:-PT5M' }, 'reminder'],
      [{ title: 'x', repeat: 'FREQ=DAILY' }, 'repeat'],
      [{ title: 'x', start: '2026-12-01', repeat: 'FREQ=HOURLY' }, 'repeat'],
      [{ title: 'x', start: '2026-12-01', reminder: 'soon' }, 'reminder'],
      [{ title: 'x', start: 'tomorrow' }, 'date'],
      [{ title: 'x', start: '2026-12-01T10:00', due: '2026-12-01T09:00' }, 'due'],
      [{ title: 'x', start: '2026-12-01T10:00', timezone: 'Mars/Base' }, 'Mars/Base'],
      [{ title: '   ' }, 'title'],
      [{ title: 'x', priority: 'urgent' }, 'priority'],
      [{ title: 'x', subtasks: 'one' }, 'subtasks'],
      [{ title: 'x', tags: [1] }, 'tags'],
    ];
    for (const [args, hint] of bad) {
      const r = await call(h, 'u-a', 'create_task', { project_id: 'p1', ...args });
      expect(r.isError, JSON.stringify(args)).toBe(true);
      expect(r.text.toLowerCase(), JSON.stringify(args)).toContain(hint.toLowerCase());
    }
    expect((await call(h, 'u-a', 'create_task', { project_id: 'nope', title: 'x' })).text).toContain('list_projects');
    expect(h.calls).toEqual([]);
  });

  it('asks an account that never synced to log in first', async () => {
    const h = createHarness();
    await seedUser(h, 'u-a', null);
    h.calls.length = 0;
    const r = await call(h, 'u-a', 'create_task', { project_id: 'inbox-u-a', title: 'x' });
    expect(r.isError).toBe(true);
    expect(r.text).toContain('請先在 DayDo App 登入並同步一次');
    const none = createHarness();
    await seedUser(none, 'u-a', 'm-a', false);
    const r2 = await call(none, 'u-a', 'create_task', { project_id: 'p1', title: 'x' });
    expect(r2.text).toContain('請先在 DayDo App 登入並同步一次');
    expect(h.calls).toEqual([]);
  });

  it('lets an editor create in a shared list that the owner then pulls', async () => {
    const h = createHarness();
    await seedShared(h, 'editor');
    const r = await call(h, 'u-b', 'create_task', { project_id: 'p1', title: 'from b', tags: ['Shared'] });
    expect(r.isError, r.text).toBe(false);
    const res = await h.pull('u-a');
    expect(pulled(res, 'task', r.json.id)).toMatchObject({ projectId: 'p1', title: 'from b' });
    // Tags are per user: b's tag row lives in b's scope, not a's.
    expect(pulled(await h.pull('u-b'), 'tag', 'shared')).toBeDefined();
  });
});

describe('M11b viewer', () => {
  it('refuses every write tool on a read-only list without pushing', async () => {
    const h = createHarness();
    await seedShared(h, 'viewer');
    h.calls.length = 0;
    const attempts: Array<[string, Record<string, unknown>]> = [
      ['create_task', { project_id: 'p1', title: 'x' }],
      ['update_task', { project_id: 'p1', task_id: 't1', title: 'x' }],
      ['delete_task', { project_id: 'p1', task_id: 't1' }],
      ['move_task', { task_id: 't1', from_project_id: 'p1', to_project_id: 'inbox-u-b' }],
      ['move_all', { from_project_id: 'p1', to_project_id: 'inbox-u-b' }],
    ];
    for (const [name, args] of attempts) {
      const r = await call(h, 'u-b', name, args);
      expect(r.isError, name).toBe(true);
      expect(r.text, name).toContain('read-only');
    }
    expect(h.calls).toEqual([]);
  });

  it('treats an archived list as unknown before checking the role', async () => {
    const h = createHarness();
    await seedShared(h, 'viewer');
    const own = await call(h, 'u-a', 'create_task', { project_id: 'inbox-u-a', title: 'mine' });
    const archived = await h.devicePush('u-a', [{ ...deviceOp(h, 'project', { id: 'p1', archivedAt: NOW_ISH }), fields: ['archivedAt'] }]);
    expect(archived.results[0]?.status).toBe('applied');
    h.calls.length = 0;
    for (const userId of ['u-a', 'u-b']) {
      const r = await call(h, userId, 'create_task', { project_id: 'p1', title: 'x' });
      expect(r.isError, userId).toBe(true);
      expect(r.text, userId).toContain("Unknown project_id 'p1'");
    }
    const move = await call(h, 'u-a', 'move_task', { task_id: own.json.id, from_project_id: 'inbox-u-a', to_project_id: 'p1' });
    expect(move.text).toContain("Unknown project_id 'p1'");
    expect(h.calls).toEqual([]);
  });

  it('refuses moving into a read-only list', async () => {
    const h = createHarness();
    await seedShared(h, 'viewer');
    const own = await call(h, 'u-b', 'create_task', { project_id: 'inbox-u-b', title: 'mine' });
    h.calls.length = 0;
    const r = await call(h, 'u-b', 'move_task', { task_id: own.json.id, from_project_id: 'inbox-u-b', to_project_id: 'p1' });
    expect(r.isError).toBe(true);
    expect(r.text).toContain('read-only');
    expect(h.calls).toEqual([]);
  });
});

describe('M11b update_task', () => {
  it('changes only the given fields and leaves the schedule out of the op', async () => {
    const h = createHarness();
    await seedBasic(h);
    h.calls.length = 0;
    const r = await call(h, 'u-a', 'update_task', { project_id: 'p1', task_id: 't1', title: 'Renamed', content: 'a\\nb', priority: 'low' });
    expect(r.isError, r.text).toBe(false);
    expect(r.json).toMatchObject({ title: 'Renamed', content: 'a\nb', priority: 1, start: '2026-11-20T09:00:00+08:00', timezone: 'Asia/Taipei', reminders: ['TRIGGER:PT0S'] });
    const ops = mcpOps(h);
    expect(ops).toHaveLength(1);
    expect(ops[0]!.fields).toEqual(expect.arrayContaining(['title', 'content', 'priority', 'updatedAt']));
    for (const f of ['startDay', 'startMinute', 'endDay', 'endMinute', 'timeZone', 'reminders']) {
      expect(ops[0]!.fields).not.toContain(f);
    }
    expect(pulled(await h.pull('u-a'), 'task', 't1')).toMatchObject({ title: 'Renamed', priority: 1 });
  });

  it('rebuilds the end from due alone on the wall clock', async () => {
    const h = createHarness();
    await seedBasic(h);
    const r = await call(h, 'u-a', 'update_task', { project_id: 'p1', task_id: 't1', due: '2026-11-20T11:30:00+08:00' });
    expect(r.json).toMatchObject({ start: '2026-11-20T09:00:00+08:00', due: '2026-11-20T11:30:00+08:00', timezone: 'Asia/Taipei' });
  });

  it('rebuilds the schedule from start, keeping the task zone', async () => {
    const h = createHarness();
    await seedBasic(h);
    const r = await call(h, 'u-a', 'update_task', { project_id: 'p1', task_id: 't1', start: '2026-11-21T09:00:00Z' });
    expect(r.json).toMatchObject({ start: '2026-11-21T17:00:00+08:00', due: null, timezone: 'Asia/Taipei' });
  });

  it("clears only the end with due:'', and dates a dateless task from due alone", async () => {
    const h = createHarness();
    await seedBasic(h);
    const r = await call(h, 'u-a', 'update_task', { project_id: 'p1', task_id: 't1', due: '' });
    expect(r.json).toMatchObject({ start: '2026-11-20T09:00:00+08:00', due: null, timezone: 'Asia/Taipei', reminders: ['TRIGGER:PT0S'] });
    const plain = await call(h, 'u-a', 'create_task', { project_id: 'p1', title: 'dateless' });
    const dated = await call(h, 'u-a', 'update_task', { project_id: 'p1', task_id: plain.json.id, due: '2026-12-05' });
    expect(dated.json).toMatchObject({ start: '2026-12-05', due: null, all_day: true });
  });

  it('relabels the zone when only timezone is given, and rejects all_day without a date', async () => {
    const h = createHarness();
    await seedBasic(h);
    const r = await call(h, 'u-a', 'update_task', { project_id: 'p1', task_id: 't1', timezone: 'Asia/Tokyo' });
    expect(r.json).toMatchObject({ start: '2026-11-20T09:00:00+09:00', timezone: 'Asia/Tokyo' });
    h.calls.length = 0;
    const a = await call(h, 'u-a', 'update_task', { project_id: 'p1', task_id: 't1', all_day: true });
    expect(a.isError).toBe(true);
    expect(a.text).toContain('all_day');
    expect(h.calls).toEqual([]);
  });

  it("clears the schedule, reminders and repeat with start:''", async () => {
    const h = createHarness();
    await seedBasic(h);
    await call(h, 'u-a', 'update_task', { project_id: 'p1', task_id: 't1', repeat: 'FREQ=DAILY' });
    const r = await call(h, 'u-a', 'update_task', { project_id: 'p1', task_id: 't1', start: '' });
    expect(r.isError, r.text).toBe(false);
    expect(r.json).toMatchObject({ start: null, due: null, all_day: false, reminders: [], repeat: null });
    const row = pulled(await h.pull('u-a'), 'task', 't1');
    expect(row?.startDay ?? null).toBeNull();
    expect(row?.reminders).toEqual([]);
    expect(row?.repeatRule ?? null).toBeNull();
  });

  it("clears repeat with repeat:'' and rejects reminders or repeat on a dateless task", async () => {
    const h = createHarness();
    await seedBasic(h);
    await call(h, 'u-a', 'update_task', { project_id: 'p1', task_id: 't1', repeat: 'RRULE:FREQ=MONTHLY;BYMONTHDAY=20' });
    expect((await call(h, 'u-a', 'get_task', { project_id: 'p1', task_id: 't1' })).json.repeat).toBe('RRULE:FREQ=MONTHLY;BYMONTHDAY=20');
    const r = await call(h, 'u-a', 'update_task', { project_id: 'p1', task_id: 't1', repeat: '' });
    expect(r.json.repeat).toBeNull();
    expect(r.json.start).toBe('2026-11-20T09:00:00+08:00');
    const plain = await call(h, 'u-a', 'create_task', { project_id: 'p1', title: 'dateless' });
    h.calls.length = 0;
    const rem = await call(h, 'u-a', 'update_task', { project_id: 'p1', task_id: plain.json.id, reminder: 'TRIGGER:PT0S' });
    expect(rem.isError).toBe(true);
    expect(rem.text).toContain('reminder');
    const rep = await call(h, 'u-a', 'update_task', { project_id: 'p1', task_id: plain.json.id, repeat: 'FREQ=DAILY' });
    expect(rep.isError).toBe(true);
    expect(rep.text).toContain('repeat');
    const both = await call(h, 'u-a', 'update_task', { project_id: 'p1', task_id: 't1', start: '', reminder: 'TRIGGER:PT0S' });
    expect(both.isError).toBe(true);
    expect(h.calls).toEqual([]);
  });

  it('replaces the whole checklist: old items are soft-deleted, new ones get new ids', async () => {
    const h = createHarness();
    await seedBasic(h);
    await h.devicePush('u-a', [
      deviceOp(h, 'checklistItem', { id: 'c-old', taskId: 't1', title: 'old', status: 1, sortKey: 'i', createdAt: NOW_ISH, updatedAt: NOW_ISH }),
    ]);
    const r = await call(h, 'u-a', 'update_task', { project_id: 'p1', task_id: 't1', subtasks: ['new one', 'new two'] });
    expect(r.isError, r.text).toBe(false);
    expect(r.json.items.map((i: any) => i.title)).toEqual(['new one', 'new two']);
    expect(r.json.items.map((i: any) => i.id)).not.toContain('c-old');
    const res = await h.pull('u-a');
    expect(pulled(res, 'checklistItem', 'c-old')?.deletedAt).toBeTypeOf('number');
    const cleared = await call(h, 'u-a', 'update_task', { project_id: 'p1', task_id: 't1', subtasks: [] });
    expect(cleared.json.items).toEqual([]);
  });

  it('maps tags to the task and its tag rows, reviving a trashed one', async () => {
    const h = createHarness();
    await seedBasic(h);
    await h.devicePush('u-a', [
      deviceOp(h, 'tag', { id: 'old', name: 'old', label: 'Old', sortKey: 'i', createdAt: NOW_ISH, updatedAt: NOW_ISH, deletedAt: NOW_ISH }),
    ]);
    const r = await call(h, 'u-a', 'update_task', { project_id: 'p1', task_id: 't1', tags: ['Old', 'fresh'] });
    expect(r.isError, r.text).toBe(false);
    expect(r.json.tags).toEqual(['old', 'fresh']);
    const list = await call(h, 'u-a', 'list_tags');
    expect(list.json.map((t: any) => t.name)).toEqual(['old', 'fresh']);
  });

  it('errors on a task in another project, an unknown task, or nothing to change', async () => {
    const h = createHarness();
    await seedBasic(h);
    h.calls.length = 0;
    const wrong = await call(h, 'u-a', 'update_task', { project_id: 'inbox-u-a', task_id: 't1', title: 'x' });
    expect(wrong.isError).toBe(true);
    expect(wrong.text).toContain('not in project');
    expect((await call(h, 'u-a', 'update_task', { project_id: 'p1', task_id: 'nope', title: 'x' })).isError).toBe(true);
    const nothing = await call(h, 'u-a', 'update_task', { project_id: 'p1', task_id: 't1' });
    expect(nothing.isError).toBe(true);
    expect(nothing.text).toContain('Nothing to update');
    expect(h.calls).toEqual([]);
  });

  it('reports isError with the lost field when a phone edit wins LWW in between', async () => {
    const h = createHarness();
    await seedBasic(h);
    const lead = Date.now() + 3 * 60_000;
    h.hooks.beforeMcpPush = () =>
      h.devicePush('u-a', [{ ...deviceOp(h, 'task', { id: 't1', title: 'phone' }, `${lead}:0000:dev-a`), fields: ['title'] }]);
    const r = await call(h, 'u-a', 'update_task', { project_id: 'p1', task_id: 't1', title: 'mcp', priority: 'medium' });
    expect(h.hooks.beforeMcpPush).toBeUndefined();
    expect(r.isError).toBe(true);
    expect(r.text).toContain('title');
    expect(r.text).toContain('phone');
    const row = pulled(await h.pull('u-a'), 'task', 't1');
    expect(row).toMatchObject({ title: 'phone', priority: 3 });
  });
});

describe('M11b delete_task', () => {
  it('soft-deletes into the trash and returns the title', async () => {
    const h = createHarness();
    await seedBasic(h);
    const r = await call(h, 'u-a', 'delete_task', { project_id: 'p1', task_id: 't1' });
    expect(r.json).toEqual({ deleted: true, task_id: 't1', title: 't1' });
    const row = pulled(await h.pull('u-a'), 'task', 't1');
    expect(row?.deletedAt).toBeTypeOf('number');
    expect(row?.purgedAt ?? null).toBeNull();
    expect((await call(h, 'u-a', 'get_task', { project_id: 'p1', task_id: 't1' })).isError).toBe(true);
  });

  it('stamps deletedAt and updatedAt with the same now', async () => {
    const h = createHarness();
    await seedBasic(h);
    advancingNow(Date.now() + 120_000);
    try {
      const r = await call(h, 'u-a', 'delete_task', { project_id: 'p1', task_id: 't1' });
      expect(r.isError, r.text).toBe(false);
    } finally {
      vi.restoreAllMocks();
    }
    const row = pulled(await h.pull('u-a'), 'task', 't1')!;
    expect(row.deletedAt).toBeTypeOf('number');
    expect(row.updatedAt).toBe(row.deletedAt);
  });

  it('errors when the task is not in that project', async () => {
    const h = createHarness();
    await seedBasic(h);
    h.calls.length = 0;
    const r = await call(h, 'u-a', 'delete_task', { project_id: 'inbox-u-a', task_id: 't1' });
    expect(r.isError).toBe(true);
    expect(r.text).toContain('not in project');
    expect(h.calls).toEqual([]);
  });
});

describe('M11b move_task / move_all', () => {
  it('moves one task and checks the source project', async () => {
    const h = createHarness();
    await seedBasic(h);
    h.calls.length = 0;
    const wrong = await call(h, 'u-a', 'move_task', { task_id: 't1', from_project_id: 'inbox-u-a', to_project_id: 'p1' });
    expect(wrong.isError).toBe(true);
    const unknown = await call(h, 'u-a', 'move_task', { task_id: 't1', from_project_id: 'p1', to_project_id: 'nope' });
    expect(unknown.text).toContain('list_projects');
    expect(h.calls).toEqual([]);
    const r = await call(h, 'u-a', 'move_task', { task_id: 't1', from_project_id: 'p1', to_project_id: 'inbox-u-a' });
    expect(r.isError, r.text).toBe(false);
    expect(r.json).toMatchObject({ id: 't1', project_id: 'inbox-u-a', start: '2026-11-20T09:00:00+08:00' });
    expect(pulled(await h.pull('u-a'), 'task', 't1')).toMatchObject({ projectId: 'inbox-u-a' });
  });

  it('moves every open task, leaving completed and trashed ones', async () => {
    const h = createHarness();
    await seedBasic(h);
    await h.devicePush('u-a', [
      deviceOp(h, 'task', taskRow('t2', 'p1', { sortKey: 'b' })),
      deviceOp(h, 'task', taskRow('t-done', 'p1', { sortKey: 'c', status: 2, completedAt: NOW_ISH })),
      deviceOp(h, 'task', taskRow('t-trash', 'p1', { sortKey: 'd', deletedAt: NOW_ISH })),
    ]);
    const r = await call(h, 'u-a', 'move_all', { from_project_id: 'p1', to_project_id: 'inbox-u-a' });
    expect(r.json).toMatchObject({ moved: 2 });
    const res = await h.pull('u-a');
    expect(pulled(res, 'task', 't1')?.projectId).toBe('inbox-u-a');
    expect(pulled(res, 'task', 't2')?.projectId).toBe('inbox-u-a');
    expect(pulled(res, 'task', 't-done')?.projectId).toBe('p1');
    expect(pulled(res, 'task', 't-trash')?.projectId).toBe('p1');
    h.calls.length = 0;
    const again = await call(h, 'u-a', 'move_all', { from_project_id: 'p1', to_project_id: 'inbox-u-a' });
    expect(again.json).toMatchObject({ moved: 0 });
    expect(h.calls).toEqual([]);
  });
});
