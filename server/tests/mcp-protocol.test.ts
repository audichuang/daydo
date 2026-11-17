import { describe, expect, it, vi } from 'vitest';
import pkg from '../package.json' with { type: 'json' };
import { signAccessToken } from '../src/auth/crypto';
import type { DatabaseClient } from '../src/auth/session';
import { authenticateMcp } from '../src/mcp/auth';
import { handleMcpPost, SERVER_INFO, type ProtocolDeps } from '../src/mcp/protocol';
import {
  annotationsFor,
  describeTools,
  handleToolCall,
  TOOL_DEFS,
  validateArgs,
  type Hint,
} from '../src/mcp/registry';
import { requireInt, requireStr, ToolValidationError, type ToolDef, type ToolSchema } from '../src/mcp/toolkit';
import { signMcpAccessToken } from '../src/oauth/tokens';
import { createTestD1 } from './sqliteD1';

const SECRET = 'unit-test-jwt-secret-32-bytes-minimum';
const ORIGIN = 'https://daydo-mcp.audichuang.app';
const CTX = { userId: 'user-1', clientId: 'mcp-test' };

interface Envelope {
  id: string | number | null;
  result?: unknown;
  error?: { code: number; message: string };
}

function post(raw: string): Request {
  return new Request(`${ORIGIN}/`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: raw });
}
const postJson = (obj: unknown) => post(JSON.stringify(obj));

const fakeDeps = (over: Partial<ProtocolDeps> = {}): ProtocolDeps => ({
  defs: TOOL_DEFS,
  call: async () => ({ content: [{ type: 'text', text: '{}' }] }),
  ...over,
});

describe('handleMcpPost transport', () => {
  it('malformed JSON -> -32700, HTTP 400', async () => {
    const res = await handleMcpPost(post('{not json'), CTX);
    expect(res.status).toBe(400);
    const body = (await res.json()) as Envelope;
    expect(body.error?.code).toBe(-32700);
    expect(body.id).toBeNull();
  });

  it.each([
    ['a bare number', 42],
    ['a bare string', 'x'],
    ['an array (batch)', []],
    ['an object with no method', { jsonrpc: '2.0' }],
    ['null', null],
  ])('invalid envelope (%s) -> -32600, HTTP 400', async (_label, value) => {
    const res = await handleMcpPost(postJson(value), CTX);
    expect(res.status).toBe(400);
    const body = (await res.json()) as Envelope;
    expect(body.error).toMatchObject({ code: -32600, message: 'Invalid Request' });
    expect(body.id).toBeNull();
  });

  it('invalid envelope with an id echoes it', async () => {
    const res = await handleMcpPost(postJson({ jsonrpc: '2.0', id: 7 }), CTX);
    expect(res.status).toBe(400);
    expect(((await res.json()) as Envelope).id).toBe(7);
  });

  it('notification -> 202 with empty body', async () => {
    const res = await handleMcpPost(postJson({ jsonrpc: '2.0', method: 'notifications/initialized' }), CTX);
    expect(res.status).toBe(202);
    expect(await res.text()).toBe('');
  });

  it('unknown method as notification -> 202', async () => {
    const res = await handleMcpPost(postJson({ jsonrpc: '2.0', method: 'nope' }), CTX);
    expect(res.status).toBe(202);
  });

  it('initialize -> 2025-06-18, serverInfo daydo, tools capability', async () => {
    const res = await handleMcpPost(postJson({ jsonrpc: '2.0', id: 1, method: 'initialize', params: {} }), CTX);
    expect(res.status).toBe(200);
    const body = (await res.json()) as Envelope;
    expect(body.result).toMatchObject({
      protocolVersion: '2025-06-18',
      capabilities: { tools: {} },
      serverInfo: { name: 'daydo', version: pkg.version },
    });
  });

  it('SERVER_INFO version tracks package.json', () => {
    expect(SERVER_INFO).toEqual({ name: 'daydo', version: pkg.version });
  });

  it('ping -> {}', async () => {
    const res = await handleMcpPost(postJson({ jsonrpc: '2.0', id: 9, method: 'ping' }), CTX);
    expect(((await res.json()) as Envelope).result).toEqual({});
  });

  it('tools/list returns the registry', async () => {
    const res = await handleMcpPost(postJson({ jsonrpc: '2.0', id: 2, method: 'tools/list' }), CTX);
    expect(((await res.json()) as Envelope).result).toEqual({ tools: TOOL_DEFS });
    expect(TOOL_DEFS.map((t) => t.name)).toContain('list_projects');
  });

  it('tools/call without a name -> -32602, HTTP 200', async () => {
    const res = await handleMcpPost(
      postJson({ jsonrpc: '2.0', id: 3, method: 'tools/call', params: { arguments: {} } }),
      CTX,
    );
    expect(res.status).toBe(200);
    const body = (await res.json()) as Envelope;
    expect(body.error?.code).toBe(-32602);
    expect(body.result).toBeUndefined();
  });

  it('unknown method -> -32601, HTTP 200', async () => {
    const res = await handleMcpPost(postJson({ jsonrpc: '2.0', id: 4, method: 'does/not/exist' }), CTX);
    expect(res.status).toBe(200);
    expect(((await res.json()) as Envelope).error?.code).toBe(-32601);
  });

  it('a throwing tool layer -> -32603 in-band, not HTTP 500', async () => {
    const deps = fakeDeps({
      call: async () => {
        throw new Error('boom');
      },
    });
    const res = await handleMcpPost(
      postJson({ jsonrpc: '2.0', id: 5, method: 'tools/call', params: { name: 'x', arguments: {} } }),
      CTX,
      null,
      deps,
    );
    expect(res.status).toBe(200);
    const body = (await res.json()) as Envelope;
    expect(body.error?.code).toBe(-32603);
    expect(body.error?.message).toContain('boom');
  });

  it('unknown tool through the real registry -> isError tool result, not rpc error', async () => {
    const res = await handleMcpPost(
      postJson({ jsonrpc: '2.0', id: 6, method: 'tools/call', params: { name: 'nope', arguments: {} } }),
      CTX,
    );
    const body = (await res.json()) as Envelope;
    expect(body.error).toBeUndefined();
    expect(body.result).toMatchObject({ isError: true });
  });

  it('success wraps the result as JSON text', async () => {
    const tool: ToolDef = {
      name: 'echo',
      description: 'd',
      inputSchema: { type: 'object', properties: { a: { type: 'string' } } },
      run: async (args) => ({ got: args.a }),
    };
    const out = await handleToolCall('echo', { a: 'v' }, CTX, [tool]);
    expect(out).toEqual({ content: [{ type: 'text', text: '{"got":"v"}' }] });
  });
});

describe('mcp.call log', () => {
  it('records arg key names but never values or token-ish fields', async () => {
    const lines: string[] = [];
    const spies = (['log', 'warn', 'error'] as const).map((level) =>
      vi.spyOn(console, level).mockImplementation((...args: unknown[]) => {
        lines.push(args.map(String).join(' '));
      }),
    );
    try {
      await handleMcpPost(
        postJson({
          jsonrpc: '2.0',
          id: 1,
          method: 'tools/call',
          params: { name: 'create_task', arguments: { title: 'CANARY-4111 card', content: 'CANARY-4111' } },
        }),
        CTX,
        'ray-1',
      );
      await handleMcpPost(postJson({ jsonrpc: '2.0', id: 2, method: 'ping' }), CTX);
    } finally {
      for (const spy of spies) spy.mockRestore();
    }
    expect(lines.join('\n')).not.toContain('CANARY');
    const calls = lines.map((l) => JSON.parse(l) as Record<string, unknown>).filter((l) => l.event === 'mcp.call');
    expect(calls).toHaveLength(1);
    expect(calls[0]).toMatchObject({
      method: 'tools/call',
      tool: 'create_task',
      arg_keys: ['content', 'title'],
      outcome: 'tool_error',
      client_id: 'mcp-test',
      userId: 'user-1',
      ray: 'ray-1',
    });
    expect(typeof calls[0].ms).toBe('number');
  });
});

describe('tool schemas', () => {
  // MCP clients only see these strings; an undescribed parameter leaves the model guessing its meaning.
  it('every parameter of every tool has a description', () => {
    const missing = TOOL_DEFS.flatMap((t) =>
      Object.entries(t.inputSchema.properties ?? {})
        .filter(([, p]) => !p.description?.trim())
        .map(([name]) => `${t.name}.${name}`),
    );
    expect(missing).toEqual([]);
  });
});

describe('HINTS and annotations', () => {
  const hints: Record<string, Hint> = {
    r: 'read',
    w: 'write',
    iw: 'idempotent-write',
    io: 'idempotent-overwrite',
    d: 'destructive',
  };

  it('maps each hint to annotations', () => {
    const none = new Set<string>();
    expect(annotationsFor('r', hints, none)).toEqual({ readOnlyHint: true, openWorldHint: false });
    expect(annotationsFor('w', hints, none)).toEqual({
      readOnlyHint: false,
      destructiveHint: false,
      idempotentHint: false,
      openWorldHint: false,
    });
    expect(annotationsFor('iw', hints, none)).toMatchObject({ destructiveHint: false, idempotentHint: true });
    expect(annotationsFor('io', hints, none)).toMatchObject({ destructiveHint: true, idempotentHint: true });
    expect(annotationsFor('d', hints, none)).toMatchObject({ destructiveHint: true, idempotentHint: true });
    expect(annotationsFor('r', hints, new Set(['r'])).openWorldHint).toBe(true);
  });

  it('a tool without a HINTS entry fails registration', () => {
    const tool: ToolDef = {
      name: 'unhinted',
      description: '',
      inputSchema: { type: 'object', properties: {} },
      run: async () => null,
    };
    expect(() => describeTools([tool], hints, new Set())).toThrow(/no HINTS entry/);
  });
});

describe('validateArgs', () => {
  const schema: ToolSchema = {
    type: 'object',
    properties: { title: { type: 'string' }, priority: { type: 'string', enum: ['none', 'low', 'high'] } },
    required: ['title'],
  };

  it('rejects missing or blank required fields', () => {
    expect(() => validateArgs('t', schema, {})).toThrow(/Missing required argument 'title'/);
    expect(() => validateArgs('t', schema, { title: '  ' })).toThrow(ToolValidationError);
  });

  it('rejects unknown fields and lists the accepted ones', () => {
    expect(() => validateArgs('t', schema, { title: 'a', startDate: 'x' })).toThrow(
      /Unknown argument 'startDate'.*Accepted arguments: title, priority/,
    );
  });

  it('rejects values outside an enum, allows empty enum values', () => {
    expect(() => validateArgs('t', schema, { title: 'a', priority: 5 })).toThrow(/Invalid value 5/);
    expect(() => validateArgs('t', schema, { title: 'a', priority: 'low' })).not.toThrow();
    expect(() => validateArgs('t', schema, { title: 'a', priority: '' })).not.toThrow();
  });

  it('requireStr and requireInt', () => {
    expect(requireStr({ a: 'x' }, 'a')).toBe('x');
    expect(() => requireStr({}, 'a')).toThrow(ToolValidationError);
    expect(requireInt({ n: 3 }, 'n')).toBe(3);
    expect(requireInt({ n: '12' }, 'n')).toBe(12);
    for (const bad of [true, 1.5, '1e3', 'abc']) {
      expect(() => requireInt({ n: bad }, 'n')).toThrow(/must be an integer/);
    }
    expect(() => requireInt({}, 'n')).toThrow(/Missing required/);
  });

  it('a bad call never reaches run()', async () => {
    const run = vi.fn(async () => 1);
    const tool: ToolDef = { name: 't', description: '', inputSchema: schema, run };
    const out = await handleToolCall('t', { bogus: 1, title: 'a' }, CTX, [tool]);
    expect(out.isError).toBe(true);
    expect(run).not.toHaveBeenCalled();
  });
});

describe('authenticateMcp', () => {
  function setup() {
    const { db, sqlite } = createTestD1();
    sqlite.prepare('INSERT INTO user (id, createdAt) VALUES (?, ?)').run('user-1', 0);
    return db as unknown as DatabaseClient;
  }
  const mkReq = (token?: string, url = `${ORIGIN}/`) =>
    new Request(url, {
      method: 'POST',
      headers: token ? { Authorization: `Bearer ${token}` } : {},
    });
  const mcpToken = (over: { userId?: string; scope?: string; origin?: string } = {}) =>
    signMcpAccessToken(SECRET, {
      origin: over.origin ?? ORIGIN,
      userId: over.userId ?? 'user-1',
      scope: over.scope ?? 'mcp offline_access',
      clientId: 'mcp-test',
    });

  async function expect401(res: unknown) {
    expect(res).toBeInstanceOf(Response);
    const r = res as Response;
    expect(r.status).toBe(401);
    expect(r.headers.get('WWW-Authenticate')).toBe(
      `Bearer realm="daydo", resource_metadata="${ORIGIN}/.well-known/oauth-protected-resource", error="invalid_token"`,
    );
  }

  it('accepts a valid token for an existing user', async () => {
    const database = setup();
    const out = await authenticateMcp(mkReq(await mcpToken()), { database, secret: SECRET });
    expect(out).toEqual({ userId: 'user-1', clientId: 'mcp-test' });
  });

  it('rejects missing Bearer', async () => {
    await expect401(await authenticateMcp(mkReq(), { database: setup(), secret: SECRET }));
  });

  it('rejects an App access token', async () => {
    const app = await signAccessToken('user-1', SECRET);
    await expect401(await authenticateMcp(mkReq(app), { database: setup(), secret: SECRET }));
  });

  it('rejects token for another origin, missing mcp scope, and unknown user', async () => {
    const database = setup();
    await expect401(
      await authenticateMcp(mkReq(await mcpToken({ origin: 'https://evil.example' })), { database, secret: SECRET }),
    );
    await expect401(await authenticateMcp(mkReq(await mcpToken({ scope: 'offline_access' })), { database, secret: SECRET }));
    await expect401(await authenticateMcp(mkReq(await mcpToken({ userId: 'ghost' })), { database, secret: SECRET }));
  });

  it('rejects a token signed with a different secret', async () => {
    const t = await signMcpAccessToken('another-secret-another-secret-123456', {
      origin: ORIGIN,
      userId: 'user-1',
      scope: 'mcp',
      clientId: 'c',
    });
    await expect401(await authenticateMcp(mkReq(t), { database: setup(), secret: SECRET }));
  });
});
