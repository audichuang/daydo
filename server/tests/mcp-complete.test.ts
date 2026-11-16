import { readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { acceptInvite, createInvite } from '../src/sharing';
import {
  HINTS,
  TOOL_DEFS,
} from '../src/mcp/registry';
import { uuidv5 } from '../src/domain/uuid';
import { advancingNow } from './helpers/advancingClock';
import {
  call,
  createServerHarness,
  deviceOp,
  projectRow,
  seedBasic,
  seedUser,
  taskRow,
  pulled,
} from './helpers/serverHarness';

type Harness = ReturnType<typeof createServerHarness>;

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

const mcpCalls = (h: Harness) => h.calls.filter((c) => c.deviceId === 'mcp');

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const fixturePath = path.resolve(__dirname, '../../spec/fixtures/sync-ops.json');
const FIXTURE = JSON.parse(readFileSync(fixturePath, 'utf8')) as { ops: Array<Record<string, any>> };
const FIX_NOW = 1794715200000; // 2026-11-15 12:00 Asia/Taipei, the App's clock when it wrote the fixture
const FIX_TASK_ID = '01a1dd5b-fc89-75e1-b4c4-fb62891e2107';
const FIX_COPY_ID = 'cc64dbd5-1983-5448-8442-0fba63492416';
const FIX_ITEM_COPY_ID = '9295d8c6-ba7b-5466-a4b7-0a5a17b4e573';
const FIX_MEMBER_ID = '01a1dd5b-fc85-7f74-88e6-a04f8baa6fc6';

/** The fixture op that writes `entityId`, the n-th one when it is written several times. */
function fixtureOp(entityId: string, nth = 0): Record<string, any> {
  const op = FIXTURE.ops.filter((o) => o.entityId === entityId)[nth];
  if (!op) throw new Error(`fixture has no op #${nth} for ${entityId}`);
  return op;
}

/** p1 with a weekly 09:00 task `rep` from 2026-11-15 (Asia/Taipei). */
async function seedRepeating(h: Harness, extra: Record<string, unknown> = {}) {
  await seedUser(h, 'u-a', 'm-a');
  const res = await h.devicePush('u-a', [
    deviceOp(h, 'project', projectRow('p1')),
    deviceOp(
      h,
      'task',
      taskRow('rep', 'p1', {
        title: 'Weekly sync', startDay: '2026-11-15', startMinute: 540, endDay: '2026-11-15', endMinute: 600,
        timeZone: 'Asia/Taipei', repeatRule: 'RRULE:FREQ=WEEKLY', reminders: ['TRIGGER:PT0S'], tags: ['work'],
        ...extra,
      }),
    ),
  ]);
  expect(res.results.map((r) => r.status)).toEqual(['applied', 'applied']);
}

const repCopyId = (day = '2026-11-15', minute: string | number = 540) => uuidv5(`rep|${day}|${minute}`);

beforeEach(() => {
  vi.useFakeTimers({ toFake: ['Date'] });
  vi.setSystemTime(FIX_NOW);
});

afterEach(() => {
  vi.useRealTimers();
});

describe('M12 registry', () => {
  it('registers complete_task as idempotent-write without TickTick or habit wording', () => {
    const def = TOOL_DEFS.find((t) => t.name === 'complete_task');
    expect(def).toBeDefined();
    expect(HINTS.complete_task).toBe('idempotent-write');
    expect(def!.description).not.toMatch(/ticktick|habit/i);
    expect(def!.inputSchema.required).toEqual(['project_id', 'task_id']);
  });
});

describe('M12 complete_task, one-off tasks', () => {
  it('writes status=2 with completedAt and returns the completed task', async () => {
    const h = createServerHarness();
    await seedBasic(h);
    h.calls.length = 0;
    const r = await call(h, 'u-a', 'complete_task', { project_id: 'p1', task_id: 't1' });
    expect(r.isError, r.text).toBe(false);
    expect(r.json).toMatchObject({ id: 't1', status: 2, completed_at: FIX_NOW });
    const ops = mcpOps(h);
    expect(ops).toHaveLength(1);
    expect(ops[0]!.row).toMatchObject({ id: 't1', status: 2, completedAt: FIX_NOW });
    expect(pulled(await h.pull('u-a'), 'task', 't1')).toMatchObject({ status: 2, completedAt: FIX_NOW });
  });

  it('returns an already completed task unchanged without pushing', async () => {
    const h = createServerHarness();
    await seedBasic(h);
    await h.devicePush('u-a', [deviceOp(h, 'task', { id: 't1', status: 2, completedAt: 123 })]);
    h.calls.length = 0;
    const r = await call(h, 'u-a', 'complete_task', { project_id: 'p1', task_id: 't1' });
    expect(r.isError, r.text).toBe(false);
    expect(r.json).toMatchObject({ id: 't1', status: 2, completed_at: 123 });
    expect(mcpCalls(h)).toEqual([]);
  });

  it('errors when the task is in another project, and for viewers, without pushing', async () => {
    const h = createServerHarness();
    await seedShared(h, 'viewer');
    h.calls.length = 0;
    const wrong = await call(h, 'u-a', 'complete_task', { project_id: 'inbox-u-a', task_id: 't1' });
    expect(wrong.isError).toBe(true);
    expect(wrong.text).toContain('not in project');
    const viewer = await call(h, 'u-b', 'complete_task', { project_id: 'p1', task_id: 't1' });
    expect(viewer.isError).toBe(true);
    expect(viewer.text).toContain('read-only');
    expect(mcpCalls(h)).toEqual([]);
  });
});

describe('M12 complete_task, repeating tasks', () => {
  // App alignment (push order, fixture ops, ids, catch-up) is in task-writes.test.ts.
  it('returns the completed copy with its checklist copy for the App fixture', async () => {
    const h = createServerHarness();
    const project = fixtureOp('01a1dd5b-fc88-7f98-9743-8bbff3400c35').row;
    const task = fixtureOp(FIX_TASK_ID).row;
    const item = fixtureOp('01a1dd5b-fc8a-7648-b8cc-9f08d7e42a43').row;
    await seedUser(h, 'u-a', FIX_MEMBER_ID);
    const seeded = await h.devicePush('u-a', [
      deviceOp(h, 'project', project),
      deviceOp(h, 'task', task),
      deviceOp(h, 'checklistItem', item),
    ]);
    expect(seeded.results.map((r) => r.status)).toEqual(['applied', 'applied', 'applied']);
    h.calls.length = 0;

    const r = await call(h, 'u-a', 'complete_task', { project_id: project.id, task_id: FIX_TASK_ID });
    expect(r.isError, r.text).toBe(false);
    expect(r.json).toMatchObject({ id: FIX_COPY_ID, status: 2, completed_at: FIX_NOW, repeat: null, title: '每週讀書會' });
    expect(r.json.items.map((i: any) => i.id)).toEqual([FIX_ITEM_COPY_ID]);
  });

  it('takes today from the task zone, or DEFAULT_TIMEZONE for floating tasks', async () => {
    vi.setSystemTime(Date.parse('2026-11-15T17:00:00Z')); // 2026-11-16 01:00 in Asia/Taipei
    for (const [timeZone, expected] of [['UTC', '2026-11-15'], [null, '2026-11-16'], ['Asia/Taipei', '2026-11-16']] as const) {
      const h = createServerHarness();
      await seedRepeating(h, { startDay: '2026-11-10', endDay: '2026-11-10', timeZone, repeatRule: 'RRULE:FREQ=DAILY' });
      const r = await call(h, 'u-a', 'complete_task', { project_id: 'p1', task_id: 'rep' });
      expect(r.isError, r.text).toBe(false);
      expect(pulled(await h.pull('u-a'), 'task', 'rep')?.startDay, String(timeZone)).toBe(expected);
    }
  });

  it('refuses a rule whose next occurrence cannot be computed before writing anything', async () => {
    const h = createServerHarness();
    await seedRepeating(h, { repeatRule: 'RRULE:FREQ=YEARLY;INTERVAL=8000' });
    h.calls.length = 0;
    const r = await call(h, 'u-a', 'complete_task', { project_id: 'p1', task_id: 'rep' });
    expect(r.isError).toBe(true);
    expect(mcpCalls(h)).toEqual([]);
    expect(pulled(await h.pull('u-a'), 'task', await repCopyId())).toBeUndefined();
  });
});

describe('complete_task carries one now into every stamp', () => {
  it('stamps a one-off completion with the same now for completedAt and updatedAt', async () => {
    const h = createServerHarness({ getNow: advancingNow(FIX_NOW) });
    await seedBasic(h);
    const r = await call(h, 'u-a', 'complete_task', { project_id: 'p1', task_id: 't1' });
    expect(r.isError, r.text).toBe(false);
    const row = pulled(await h.pull('u-a'), 'task', 't1')!;
    expect(row.completedAt).toBeTypeOf('number');
    expect(row.updatedAt).toBe(row.completedAt);
  });

  it('stamps the completed copy of a repeating task with one now', async () => {
    const h = createServerHarness({ getNow: advancingNow(FIX_NOW) });
    await seedRepeating(h);
    const r = await call(h, 'u-a', 'complete_task', { project_id: 'p1', task_id: 'rep' });
    expect(r.isError, r.text).toBe(false);
    const copy = pulled(await h.pull('u-a'), 'task', await repCopyId())!;
    expect(copy.completedAt).toBeTypeOf('number');
    expect(copy.createdAt).toBe(copy.completedAt);
    expect(copy.updatedAt).toBe(copy.completedAt);
  });
});
