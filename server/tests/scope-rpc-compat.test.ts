// Guard: the Worker → Scope DO push RPC stays wire-compatible across a deploy, when old and new
// Workers and DOs run side by side (Cloudflare rolls Workers and DOs out independently).
// The 701de08 wire format is `ops: unknown[]` holding the raw ops as the App sent them.
import { execFileSync } from 'node:child_process';
import { mkdirSync, rmSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { eq } from 'drizzle-orm';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import * as schema from '../db/schema';
import { loadSnapshot } from '../src/serverops/snapshot';
import { writeOrThrow, type WriteIntent } from '../src/serverops/writer';
import type { ScopePushInput } from '../src/scope/api';
import { createScopeWorld, ScopeClass, type CreateScopeWorldOptions } from './helpers/scopeWorld';
import { deviceOp as sharedDeviceOp, NOW_ISH, projectRow, taskRow } from './helpers/serverHarness';
import { createTestDoState } from './sqliteD1';

const LEGACY_COMMIT = '701de08';
const serverDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
let seq = 0;
const deviceHlc = () => `${Date.now() - 60_000}:${String(seq++ % 10000).padStart(4, '0')}:dev-a`;

// Same op shape as the shared builder, bound to this file's module-level device clock.
const deviceOp = (entity: string, row: Record<string, unknown>, hlc = deviceHlc()) =>
  sharedDeviceOp({ deviceHlc }, entity, row, hlc);

/** A world that records every push input exactly as it crosses the RPC boundary. */
async function seededWorld(scopeClass?: CreateScopeWorldOptions['scopeClass']) {
  const inputs: ScopePushInput[] = [];
  const world = createScopeWorld({
    scopeClass,
    onPush: (input, proceed) => {
      inputs.push(structuredClone(input));
      return proceed(input);
    },
  });
  await world.db.insert(schema.user).values({
    id: 'u-a', name: 'u-a', initial: 'u', color: '#007AFF', avatarUrl: null, createdAt: NOW_ISH,
  });
  await world.db.update(schema.user).set({ meMemberId: 'm-a' }).where(eq(schema.user.id, 'u-a'));
  const seedOps = [
    deviceOp('project', projectRow('inbox-u-a', { isInbox: true })),
    deviceOp('project', projectRow('p1')),
    deviceOp('task', taskRow('t1', 'p1')),
  ];
  const seeded = await world.push('u-a', 'dev-a', seedOps);
  return { world, inputs, seedOps, seeded };
}

/** An App push mixing valid ops with an invalid op whose row is already homed (so it reaches the DO). */
function appBatch() {
  return [
    deviceOp('project', projectRow('p2')),
    deviceOp('task', taskRow('t2', 'p2')),
    { ...deviceOp('task', { title: 'renamed' }), entityId: 't1', hlc: 'bad-hlc' },
  ];
}

describe('Scope push RPC: old Worker → new DO', () => {
  it('accepts the 701de08 input (raw ops, no validated) and writes them', async () => {
    const doState = createTestDoState();
    const scope = new ScopeClass(doState.ctx, { SYNC_FAULT: 'none' });
    const ops = [
      deviceOp('project', projectRow('p-1')),
      deviceOp('task', taskRow('t-1', 'p-1')),
      { ...deviceOp('task', { title: 'x' }), entityId: 't-1', hlc: 'bad-hlc' },
    ];
    // Exactly the fields the 701de08 Worker sends; no `validated`.
    const legacyInput = {
      scope: 'u:u-a',
      scopeUserId: 'u-a',
      pusherUserId: 'u-a',
      deviceId: 'dev-a',
      memberships: { 'p-1': 'owner' },
      purgedProjects: [],
      meMemberId: null,
      ops,
    };
    const res = await scope.push(legacyInput as unknown as ScopePushInput);

    expect(res.results.map((r) => [r.opId, r.status, r.reason])).toEqual([
      [ops[0].opId, 'applied', undefined],
      [ops[1].opId, 'applied', undefined],
      [ops[2].opId, 'rejected', 'Invalid hlc'],
    ]);
    const applied = doState.sqlite
      .prepare('SELECT opId, status FROM opApplied ORDER BY opId')
      .all() as Array<{ opId: string; status: string }>;
    expect(applied.map((r) => [r.opId, r.status]).sort()).toEqual(
      [
        [ops[0].opId, 'applied'],
        [ops[1].opId, 'applied'],
        [ops[2].opId, 'rejected'],
      ].sort(),
    );
  });
});

describe('Scope push RPC: new Worker → old DO', () => {
  it('App push sends every op raw, exactly as received', async () => {
    const { world, inputs } = await seededWorld();
    inputs.length = 0;
    const ops = appBatch();
    await world.push('u-a', 'dev-a', ops);

    expect(inputs.flatMap((i) => i.ops)).toEqual(ops);
  });

  it('writeOrThrow sends every op as a raw sync op', async () => {
    const { world, inputs } = await seededWorld();
    const snapshot = await loadSnapshot(world.db, 'u-a', world.getScopeStub);
    inputs.length = 0;
    const intents: WriteIntent[] = [
      { entity: 'task', entityId: 't-new', set: taskRow('t-new', 'p1', { sortKey: 'h' }) },
      { entity: 'task', entityId: 't1', set: { title: 'renamed' } },
    ];
    await writeOrThrow(
      { db: world.db, userId: 'u-a', deviceId: 'mcp', getScopeStub: world.getScopeStub, clock: world.clock },
      snapshot,
      intents,
    );

    const sent = inputs.flatMap((i) => i.ops) as Array<Record<string, unknown>>;
    expect(sent.map((o) => [o.entity, o.entityId, typeof o.opId, typeof o.hlc, o.op])).toEqual([
      ['task', 't-new', 'string', 'string', 'upsert'],
      ['task', 't1', 'string', 'string', 'upsert'],
    ]);
    for (const op of sent) {
      expect(Object.keys(op).sort()).toEqual(['entity', 'entityId', 'fields', 'hlc', 'op', 'opId', 'row']);
    }
  });

  describe(`against the ${LEGACY_COMMIT} ScopeObject`, () => {
    const legacyDir = path.join(serverDir, 'tests', `.legacy-${LEGACY_COMMIT}-${process.pid}`);
    let LegacyScope: CreateScopeWorldOptions['scopeClass'] | null = null;

    beforeAll(async () => {
      const show = (file: string) =>
        execFileSync('git', ['show', `${LEGACY_COMMIT}:server/${file}`], {
          cwd: serverDir,
          encoding: 'utf8',
          stdio: ['ignore', 'pipe', 'ignore'],
        });
      let doSource: string;
      let splitSource: string;
      try {
        doSource = show('durable-objects/scope.ts');
        splitSource = show('durable-objects/dev/splitTxnSnapshotStore.ts');
      } catch {
        return; // History not available (shallow clone): the cross-run test is skipped.
      }
      // Place the legacy DO two levels deeper than durable-objects/ and repoint its src imports.
      const doDir = path.join(legacyDir, 'durable-objects');
      mkdirSync(path.join(doDir, 'dev'), { recursive: true });
      writeFileSync(path.join(doDir, 'scope.ts'), doSource.replaceAll("'../src/", "'../../../src/"));
      writeFileSync(
        path.join(doDir, 'dev', 'splitTxnSnapshotStore.ts'),
        splitSource.replaceAll("'../../src/", "'../../../../src/"),
      );
      const mod = (await import(path.join(doDir, 'scope.ts'))) as {
        ScopeObject: NonNullable<CreateScopeWorldOptions['scopeClass']>;
      };
      LegacyScope = mod.ScopeObject;
    });

    afterAll(() => {
      rmSync(legacyDir, { recursive: true, force: true });
    });

    it('applies App pushes and writeOrThrow writes (no empty-opId rejection)', async (ctx) => {
      if (!LegacyScope) ctx.skip();
      const { world, seedOps, seeded } = await seededWorld(LegacyScope!);
      expect(seeded.results.map((r) => [r.opId, r.status])).toEqual(
        seedOps.map((o) => [o.opId, 'applied']),
      );

      const ops = appBatch();
      const res = await world.push('u-a', 'dev-a', ops);
      expect(res.results.map((r) => [r.opId, r.status, r.reason])).toEqual([
        [ops[0].opId, 'applied', undefined],
        [ops[1].opId, 'applied', undefined],
        [ops[2].opId, 'rejected', 'Invalid hlc'],
      ]);

      const snapshot = await loadSnapshot(world.db, 'u-a', world.getScopeStub);
      const outcomes = await writeOrThrow(
        { db: world.db, userId: 'u-a', deviceId: 'mcp', getScopeStub: world.getScopeStub, clock: world.clock },
        snapshot,
        [{ entity: 'task', entityId: 't1', set: { title: 'from mcp' } }],
      );
      expect(outcomes.map((o) => o.status)).toEqual(['applied']);

      const pulled = await world.pull('u-a');
      const t1 = pulled.scopes
        .flatMap((s) => s.rows)
        .find((r) => r.entity === 'task' && 'row' in r && r.row.id === 't1');
      expect(t1 && 'row' in t1 ? t1.row.title : undefined).toBe('from mcp');
    });
  });
});
