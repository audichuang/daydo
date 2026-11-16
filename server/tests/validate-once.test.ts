// Guard: every op is validated exactly once on its way from the caller to the Scope DO
// (src/sync/envelope.ts is the only caller of validateSyncOp).
import { eq } from 'drizzle-orm';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import * as schema from '../db/schema';
import { loadSnapshot } from '../src/serverops/snapshot';
import { writeOrThrow, type WriteIntent } from '../src/serverops/writer';
import { validateSyncOp } from '../src/sync/entities';
import { createScopeWorld } from './helpers/scopeWorld';
import { deviceOp, NOW_ISH, projectRow, taskRow } from './helpers/serverHarness';

vi.mock('../src/sync/entities', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../src/sync/entities')>();
  return { ...actual, validateSyncOp: vi.fn(actual.validateSyncOp) };
});

const validateSpy = vi.mocked(validateSyncOp);
let seq = 0;
const deviceHlc = () => `${Date.now() - 60_000}:${String(seq++ % 10000).padStart(4, '0')}:dev-a`;


async function seededWorld() {
  const world = createScopeWorld();
  await world.db.insert(schema.user).values({
    id: 'u-a', name: 'u-a', initial: 'u', color: '#007AFF', avatarUrl: null, createdAt: NOW_ISH,
  });
  await world.db.update(schema.user).set({ meMemberId: 'm-a' }).where(eq(schema.user.id, 'u-a'));
  const seeded = await world.push('u-a', 'dev-a', [
    deviceOp({ deviceHlc }, 'project', projectRow('inbox-u-a', { isInbox: true })),
    deviceOp({ deviceHlc }, 'project', projectRow('p1')),
    deviceOp({ deviceHlc }, 'task', taskRow('t1', 'p1')),
  ]);
  expect(seeded.results.map((r) => r.status)).toEqual(['applied', 'applied', 'applied']);
  return world;
}

describe('validateSyncOp runs once per op', () => {
  beforeEach(() => {
    validateSpy.mockClear();
  });

  it('App push: N ops (one invalid but already homed, so it still reaches the DO) → N calls', async () => {
    const world = await seededWorld();
    validateSpy.mockClear();

    const ops = [
      deviceOp({ deviceHlc }, 'project', projectRow('p2')),
      deviceOp({ deviceHlc }, 'task', taskRow('t2', 'p2')),
      { ...deviceOp({ deviceHlc }, 'task', { title: 'renamed' }), entityId: 't1', hlc: 'bad-hlc' },
    ];
    const callsBefore = world.calls.length;
    const res = await world.push('u-a', 'dev-a', ops);

    expect(res.results.map((r) => [r.status, r.reason])).toEqual([
      ['applied', undefined],
      ['applied', undefined],
      ['rejected', 'Invalid hlc'],
    ]);
    const sent = world.calls.slice(callsBefore).flatMap((c) => c.ops.map((o) => o.entityId));
    expect(sent).toEqual(['p2', 't2', 't1']);
    expect(validateSpy).toHaveBeenCalledTimes(ops.length);
  });

  it('writeOrThrow: N intents → N calls', async () => {
    const world = await seededWorld();
    const snapshot = await loadSnapshot(world.db, 'u-a', world.getScopeStub);
    validateSpy.mockClear();

    const intents: WriteIntent[] = [
      { entity: 'task', entityId: 't-new-1', set: taskRow('t-new-1', 'p1', { sortKey: 'h' }) },
      { entity: 'task', entityId: 't-new-2', set: taskRow('t-new-2', 'p1', { sortKey: 'i' }) },
      { entity: 'task', entityId: 't1', set: { title: 'renamed' } },
      { entity: 'project', entityId: 'p1', set: { name: 'renamed list' } },
    ];
    const outcomes = await writeOrThrow(
      { db: world.db, userId: 'u-a', deviceId: 'mcp', getScopeStub: world.getScopeStub, clock: world.clock },
      snapshot,
      intents,
    );

    expect(outcomes.map((o) => o.status)).toEqual(['applied', 'applied', 'applied', 'applied']);
    expect(validateSpy).toHaveBeenCalledTimes(intents.length);
  });
});
