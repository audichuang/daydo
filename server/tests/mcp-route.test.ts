// M17: the MCP route (routes/index.ts) must hand the tools their services. Against a real
// ScopeObject behind a mocked Scope.get, a real D1 and a real MCP access token.
import { drizzle } from 'drizzle-orm/d1';
import { eq } from 'drizzle-orm';
import type { CloudContext } from 'void';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import * as schema from '../db/schema';
import { signMcpAccessToken } from '../src/oauth/tokens';
import { createScopeWorld, type ScopeWorld } from './helpers/scopeWorld';
import { createTestD1 } from './sqliteD1';

const SECRET = 'mcp-route-test-jwt-secret-at-least-32-bytes';
const ORIGIN = 'https://daydo-mcp.audichuang.app';
const NOW_ISH = 1_700_000_000_000;

const testEnv: { JWT_SECRET: string; DEFAULT_TIMEZONE?: string; ICS_ALLOW_INSECURE_HOSTS?: string } = {
  JWT_SECRET: SECRET,
};

vi.mock('void', () => ({ defineHandler: (handler: unknown) => handler }));
vi.mock('void/env', () => ({ env: testEnv }));

// Scope.get resolves to in-memory ScopeObjects shared with the test's device pushes.
let world: ScopeWorld | null = null;
const scopeGets: string[] = [];
vi.mock('../durable-objects/scope', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../durable-objects/scope')>();
  const mocked = {
    ...actual.default,
    get: (scope: string) => {
      scopeGets.push(scope);
      return world!.getScopeStub(scope);
    },
  };
  return { ...actual, default: mocked, Scope: mocked };
});

const { POST } = await import('../routes/index');
const postMcp = POST as unknown as (c: CloudContext) => Promise<Response>;
const { productionToolServices } = await import('../src/mcp/services');

function context(d1: D1Database, body: unknown, token: string): CloudContext {
  const raw = new Request(`${ORIGIN}/`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
    body: JSON.stringify(body),
  });
  return {
    env: { DB: d1 },
    req: { raw, url: raw.url, header: (name: string) => raw.headers.get(name) ?? undefined },
  } as unknown as CloudContext;
}

async function seedUserWithInbox() {
  const { db, d1, push } = world!;
  await db.insert(schema.user).values({
    id: 'u-a', name: 'A', initial: 'A', color: '#007AFF', avatarUrl: null, createdAt: NOW_ISH,
  });
  await db.update(schema.user).set({ meMemberId: 'm-a' }).where(eq(schema.user.id, 'u-a'));
  const hlc = `${Date.now() - 60_000}:0000:dev-a`;
  const inbox = {
    id: 'inbox-a', name: 'Inbox', viewMode: 'list', kind: 'TASK', isInbox: true, ownerId: 'm-a',
    sortKey: 'a0', showInSmart: 'all', notifyMode: 'all', createdAt: NOW_ISH, updatedAt: NOW_ISH,
  };
  const res = await push('u-a', 'dev-a', [
    { opId: 'seed-inbox', hlc, entity: 'project', entityId: inbox.id, op: 'upsert', fields: Object.keys(inbox), row: inbox },
  ]);
  expect(res.results[0]?.status).toBe('applied');
  const token = await signMcpAccessToken(SECRET, { origin: ORIGIN, userId: 'u-a', scope: 'mcp', clientId: 'mcp-test' });
  return { d1, token };
}

async function callTool(d1: D1Database, token: string, name: string, args: Record<string, unknown>) {
  const res = await postMcp(context(d1, { jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name, arguments: args } }, token));
  expect(res.status).toBe(200);
  const body = (await res.json()) as { result: { isError?: boolean; content: Array<{ text: string }> } };
  return { isError: body.result.isError === true, text: body.result.content[0]!.text };
}

beforeEach(() => {
  world = createScopeWorld();
  scopeGets.length = 0;
  delete testEnv.DEFAULT_TIMEZONE;
  delete testEnv.ICS_ALLOW_INSECURE_HOSTS;
});

describe('POST / (MCP route)', () => {
  it('gives the tools D1 and the Scope DO: list_projects then create_task reach the user data', async () => {
    const { d1, token } = await seedUserWithInbox();
    scopeGets.length = 0;

    const list = await callTool(d1, token, 'list_projects', {});
    expect(list.isError, list.text).toBe(false);
    expect(list.text).toContain('inbox-a');
    expect(scopeGets).toContain('u:u-a');

    const created = await callTool(d1, token, 'create_task', { project_id: 'inbox-a', title: 'from mcp' });
    expect(created.isError, created.text).toBe(false);
    const task = JSON.parse(created.text) as { id: string; title: string };
    expect(task.title).toBe('from mcp');

    const after = await callTool(d1, token, 'get_task', { project_id: 'inbox-a', task_id: task.id });
    expect(after.isError, after.text).toBe(false);
  });
});

describe('productionToolServices', () => {
  const { d1 } = createTestD1();
  const db = drizzle(d1, { schema }) as never;

  it('passes DEFAULT_TIMEZONE and only non-empty insecure ICS hosts', () => {
    const s = productionToolServices(db, { DEFAULT_TIMEZONE: 'Europe/Paris', ICS_ALLOW_INSECURE_HOSTS: '127.0.0.1, localhost' });
    expect(s.db).toBe(db);
    expect(s.defaultTimeZone).toBe('Europe/Paris');
    expect(s.ics?.fetchOptions?.insecureHosts).toEqual(['127.0.0.1', 'localhost']);

    const bare = productionToolServices(db, { ICS_ALLOW_INSECURE_HOSTS: ' ' });
    expect(bare.defaultTimeZone).toBeUndefined();
    expect(bare.ics).toBeUndefined();
  });

  it('resolves scope stubs through Scope.get', () => {
    const s = productionToolServices(db, {});
    s.getScopeStub('u:x');
    expect(scopeGets).toEqual(['u:x']);
  });
});
