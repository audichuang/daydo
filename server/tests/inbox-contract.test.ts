// Contract: login/refresh (Scope DO getInboxProjectId) and MCP/ICS (loadSnapshot) must agree on
// which project is the inbox for the same data (spec/sync.md, spec/mcp.md).
import { eq } from 'drizzle-orm';
import { describe, expect, it } from 'vitest';
import * as schema from '../db/schema';
import { createSessionForIdentity, rotateRefreshToken, type DatabaseClient } from '../src/auth/session';
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

const JWT_SECRET = 'unit-test-jwt-secret-32-bytes-minimum';

/** Real login and refresh path (createSessionForIdentity / rotateRefreshToken). */
async function loginInbox(h: ServerHarness) {
  const database = h.db as unknown as DatabaseClient;
  await h.db.insert(schema.identity).values({ provider: 'apple', sub: 'sub-a', userId: U, email: null });
  const login = await createSessionForIdentity(database, {
    provider: 'apple', sub: 'sub-a', email: null, deviceId: 'dev-login',
    jwtSecret: JWT_SECRET, getScopeStub: h.getScopeStub,
  });
  const refreshed = await rotateRefreshToken(database, {
    refreshToken: login.refreshToken, jwtSecret: JWT_SECRET, getScopeStub: h.getScopeStub,
  });
  return { login, refreshed };
}

async function expectAgree(h: ServerHarness, expected: string | null) {
  const { login, refreshed } = await loginInbox(h);
  const snap = await h.snapshot(U);
  expect({
    login: login.inboxProjectId,
    loginHasData: login.hasData,
    refresh: refreshed?.inboxProjectId,
    mcp: snap.inboxProjectId,
  }).toEqual({ login: expected, loginHasData: expected !== null, refresh: expected, mcp: expected });
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

  it('two inboxes: both pick the lowest serverSeq (last change), even after the first was updated', async () => {
    const h = createServerHarness();
    await setup(h, [projectRow('inbox-1', { isInbox: true })]);
    let res = await h.devicePush(U, [deviceOp(h, 'project', projectRow('inbox-2', { isInbox: true }))]);
    expect(res.results[0]?.status).toBe('applied');
    // Touch inbox-1 so its serverSeq (last change) is now higher than inbox-2's.
    res = await h.devicePush(U, [deviceOp(h, 'project', projectRow('inbox-1', { isInbox: true, name: 'renamed' }))]);
    expect(res.results[0]?.status).toBe('applied');
    await expectAgree(h, 'inbox-2');
  });

  it('trashed first inbox falls through to the second for both', async () => {
    const h = createServerHarness();
    await setup(h, [projectRow('inbox-1', { isInbox: true, deletedAt: 5 })]);
    const res = await h.devicePush(U, [deviceOp(h, 'project', projectRow('inbox-2', { isInbox: true }))]);
    expect(res.results[0]?.status).toBe('applied');
    await expectAgree(h, 'inbox-2');
  });
});
