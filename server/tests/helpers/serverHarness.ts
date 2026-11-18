import { eq } from 'drizzle-orm';
import { expect } from 'vitest';
import * as schema from '../../db/schema';
import { handleToolCall } from '../../src/mcp/registry';
import type { ToolContext } from '../../src/mcp/toolkit';
import { loadSnapshot } from '../../src/serverops/snapshot';
import { createScopeWorld, type CreateScopeWorldOptions } from './scopeWorld';

/**
 * Shared harness for server tests that drive tools, the writer or the sync path against a real
 * ScopeObject world. Builds on createScopeWorld (does not replace it): per-file concerns such as
 * `onPush` hooks, fake fetches and stores stay in the test file and wrap this.
 */

export const NOW_ISH = 1_700_000_000_000;

export function createServerHarness(options: CreateScopeWorldOptions = {}) {
  const world = createScopeWorld(options);
  const { db, calls, clock, storage, getScopeStub, push, pull } = world;
  let seq = 0;
  // Device HLCs sit in the past unless a test asks for a lead.
  const deviceHlc = (ms = Date.now() - 60_000) => `${ms}:${String(seq++ % 10000).padStart(4, '0')}:dev-a`;
  const devicePush = (userId: string, ops: unknown[]) => push(userId, 'dev-a', ops);
  const deps = (userId: string) => ({ db, userId, deviceId: 'mcp' as const, getScopeStub, clock });
  const snapshot = (userId: string) => loadSnapshot(db, userId, getScopeStub);
  /** Tool context whose `getNow` is the world's injected clock. */
  const toolContext = (userId: string): ToolContext => ({
    userId,
    clientId: 'test',
    services: { db, getScopeStub, storage, getNow: world.deps.getNow },
  });
  return {
    db,
    calls,
    clock,
    storage,
    getScopeStub,
    world,
    deviceHlc,
    devicePush,
    deps,
    snapshot,
    toolContext,
    pull: (userId: string) => pull(userId, { limit: 1000 }),
  };
}

export type ServerHarness = ReturnType<typeof createServerHarness>;

export function projectRow(id: string, extra: Record<string, unknown> = {}) {
  return {
    id, name: id, viewMode: 'list', kind: 'TASK', isInbox: false, ownerId: 'm-a',
    sortKey: 'a0', showInSmart: 'all', notifyMode: 'all', createdAt: NOW_ISH, updatedAt: NOW_ISH,
    ...extra,
  };
}

export function taskRow(id: string, projectId: string, extra: Record<string, unknown> = {}) {
  return {
    id, projectId, title: id, content: '', priority: 0, status: 0, sortKey: 'a0',
    reminders: [], tags: [], createdAt: NOW_ISH, updatedAt: NOW_ISH, ...extra,
  };
}

export function deviceOp(
  h: Pick<ServerHarness, 'deviceHlc'>,
  entity: string,
  row: Record<string, unknown>,
  hlc = h.deviceHlc(),
) {
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

export async function seedUser(
  h: Pick<ServerHarness, 'db' | 'devicePush' | 'deviceHlc'>,
  userId: string,
  memberId: string | null,
  withInbox = true,
) {
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
export async function seedBasic(h: Pick<ServerHarness, 'db' | 'devicePush' | 'deviceHlc'>) {
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

export async function call(
  h: Pick<ServerHarness, 'toolContext'>,
  userId: string,
  name: string,
  args: Record<string, unknown> = {},
) {
  const res = await handleToolCall(name, args, h.toolContext(userId));
  const textBlock = res.content.find((c) => c.type === 'text');
  const text = textBlock?.text ?? '';
  return { isError: res.isError === true, text, json: res.isError ? null : (JSON.parse(text) as any) };
}

export type PullRes = Awaited<ReturnType<ServerHarness['pull']>>;

export function pulled(res: PullRes, entity: string, key: string): Record<string, unknown> | undefined {
  for (const s of res.scopes) {
    for (const r of s.rows) {
      if (r.entity !== entity || 'gone' in r) continue;
      const id = entity === 'tag' ? r.row.name : r.row.id;
      if (id === key) return r.row as Record<string, unknown>;
    }
  }
  return undefined;
}
