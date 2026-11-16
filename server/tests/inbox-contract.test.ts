// Contract: login/refresh (Scope DO getInboxProjectId) and MCP/ICS (loadSnapshot) must agree on
// which project is the inbox for the same data (spec/sync.md, spec/mcp.md).
import { eq } from 'drizzle-orm';
import { describe, expect, it } from 'vitest';
import * as schema from '../db/schema';
import { activeProjectIds, decodeProjectIds } from '../src/membership/statements';
import { userScope } from '../src/sync/scopeName';
import { createServerHarness, deviceOp, projectRow, type ServerHarness } from './helpers/serverHarness';

const U = 'u-a';

async function setup(h: ServerHarness, rows: Array<Record<string, unknown>>) {
  await h.db.insert(schema.user).values({
    id: U, name: U, initial: 'u', color: '#007AFF', avatarUrl: null, createdAt: 1,
  });
  await h.db.update(schema.user).set({ meMemberId: 'm-a' }).where(eq(schema.user.id, U));
  const res = await h.devicePush(U, rows.map((r) => deviceOp(h, 'project', r)));
  expect(res.results.every((r) => r.status === 'applied')).toBe(true);
}

/** Same call chain as auth/session.ts resolveUserSyncState. */
async function loginInbox(h: ServerHarness): Promise<string | null> {
  const [rows] = await h.db.batch([activeProjectIds(h.db, U)]);
  const readableProjectIds = decodeProjectIds(rows as never);
  if (readableProjectIds.length === 0) return null;
  return h.getScopeStub(userScope(U)).getInboxProjectId({ readableProjectIds });
}

async function expectAgree(h: ServerHarness, expected: string | null) {
  const login = await loginInbox(h);
  const snap = await h.snapshot(U);
  expect({ login, mcp: snap.inboxProjectId }).toEqual({ login: expected, mcp: expected });
}

describe('inbox definition agrees between login and MCP snapshot', () => {
  it('normal inbox', async () => {
    const h = createServerHarness();
    await setup(h, [projectRow('inbox', { isInbox: true })]);
    await expectAgree(h, 'inbox');
  });

  it('inbox in trash (deletedAt) is no inbox for either', async () => {
    const h = createServerHarness();
    await setup(h, [projectRow('inbox', { isInbox: true, deletedAt: 5 })]);
    await expectAgree(h, null);
  });

  it('purged inbox is no inbox for either', async () => {
    const h = createServerHarness();
    await setup(h, [projectRow('inbox', { isInbox: true })]);
    const res = await h.devicePush(U, [
      { opId: 'del-inbox', hlc: h.deviceHlc(), entity: 'project', entityId: 'inbox', op: 'delete', fields: [], row: {} },
    ]);
    expect(res.results[0]?.status).toBe('applied');
    await expectAgree(h, null);
  });

  it('two inboxes: both pick the earliest pushed one', async () => {
    const h = createServerHarness();
    await setup(h, [projectRow('inbox-1', { isInbox: true })]);
    const res = await h.devicePush(U, [deviceOp(h, 'project', projectRow('inbox-2', { isInbox: true }))]);
    expect(res.results[0]?.status).toBe('applied');
    await expectAgree(h, 'inbox-1');
  });

  it('trashed first inbox falls through to the second for both', async () => {
    const h = createServerHarness();
    await setup(h, [projectRow('inbox-1', { isInbox: true, deletedAt: 5 })]);
    const res = await h.devicePush(U, [deviceOp(h, 'project', projectRow('inbox-2', { isInbox: true }))]);
    expect(res.results[0]?.status).toBe('applied');
    await expectAgree(h, 'inbox-2');
  });
});
