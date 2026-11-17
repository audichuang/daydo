import type { CloudContext } from 'void';
import { describe, expect, it } from 'vitest';
import { createHostGateMiddleware, isMcpHost, isMcpPath } from '../src/auth/host';

const MCP_HOST = 'mcp.daydoapp.com';
const MCP_ORIGIN = `https://${MCP_HOST}`;
const API_ORIGIN = 'https://api.daydoapp.com';

const MCP_PATHS = [
  '/',
  '/register',
  '/token',
  '/authorize',
  '/authorize/start',
  '/authorize/google/callback',
  '/authorize/apple/callback',
  '/authorize/email/start',
  '/authorize/email/verify',
  '/.well-known/oauth-authorization-server',
  '/.well-known/oauth-protected-resource',
];

const NON_MCP_PATHS = [
  '/health',
  '/sync/pull',
  '/auth/apple',
  '/auth/email/start',
  '/auth/email/verify',
  '/authorizeX',
  '/registerx',
  '/token/x',
  '/attachments/att-1/content',
  '/.well-known/other',
  '/.well-known/oauth-protected-resource/extra',
];

function makeContext(url: string, method = 'GET'): CloudContext {
  return {
    req: { url, method, raw: new Request(url, { method }) },
    json: (body: unknown, status = 200) =>
      new Response(JSON.stringify(body), {
        status,
        headers: { 'Content-Type': 'application/json' },
      }),
  } as unknown as CloudContext;
}

async function run(url: string, method = 'GET') {
  const middleware = createHostGateMiddleware({ getMcpHost: () => MCP_HOST });
  let nextCalled = false;
  const res = await middleware(makeContext(url, method), async () => {
    nextCalled = true;
  });
  return { res, nextCalled };
}

describe('isMcpPath', () => {
  it('accepts exactly the MCP endpoints', () => {
    for (const p of MCP_PATHS) expect(isMcpPath(p), p).toBe(true);
    for (const p of NON_MCP_PATHS) expect(isMcpPath(p), p).toBe(false);
  });
});

describe('isMcpHost', () => {
  it('compares hostname only, ignoring port and case', () => {
    expect(isMcpHost(`${MCP_ORIGIN}/`, MCP_HOST)).toBe(true);
    expect(isMcpHost('http://localhost:5173/token', 'localhost')).toBe(true);
    expect(isMcpHost('http://MCP.DAYDOAPP.com:8443/', MCP_HOST)).toBe(true);
    expect(isMcpHost(`${API_ORIGIN}/`, MCP_HOST)).toBe(false);
    expect(isMcpHost('http://127.0.0.1:5173/', 'localhost')).toBe(false);
  });
});

describe('host gate middleware', () => {
  it('lets MCP paths through on the MCP host', async () => {
    for (const p of MCP_PATHS) {
      for (const method of ['GET', 'POST']) {
        const { res, nextCalled } = await run(`${MCP_ORIGIN}${p}`, method);
        expect(res, `${method} ${p}`).toBeUndefined();
        expect(nextCalled, `${method} ${p}`).toBe(true);
      }
    }
  });

  it('returns 404 for every other path on the MCP host', async () => {
    for (const p of NON_MCP_PATHS) {
      const { res, nextCalled } = await run(`${MCP_ORIGIN}${p}`);
      expect(nextCalled, p).toBe(false);
      expect(res?.status, p).toBe(404);
    }
  });

  it('ignores the port when matching the MCP host', async () => {
    const middleware = createHostGateMiddleware({ getMcpHost: () => 'localhost' });
    let nextCalled = false;
    const blocked = await middleware(makeContext('http://localhost:5173/health'), async () => {
      nextCalled = true;
    });
    expect(nextCalled).toBe(false);
    expect(blocked?.status).toBe(404);

    const passed = await middleware(makeContext('http://localhost:5173/register', 'POST'), async () => {
      nextCalled = true;
    });
    expect(passed).toBeUndefined();
    expect(nextCalled).toBe(true);
  });

  it('answers OPTIONS on the MCP host with 204 and CORS headers', async () => {
    const { res, nextCalled } = await run(`${MCP_ORIGIN}/`, 'OPTIONS');
    expect(nextCalled).toBe(false);
    expect(res?.status).toBe(204);
    expect(res?.headers.get('Access-Control-Allow-Origin')).toBe('*');
    expect(res?.headers.get('Access-Control-Allow-Methods')).toContain('POST');
    expect(res?.headers.get('Access-Control-Allow-Headers')).toContain('Authorization');
    expect(res?.headers.get('Access-Control-Allow-Headers')).toContain('Mcp-Session-Id');
  });

  it('returns 404 for MCP paths on other hosts, including OPTIONS', async () => {
    for (const p of MCP_PATHS) {
      for (const method of ['GET', 'POST', 'OPTIONS']) {
        const { res, nextCalled } = await run(`${API_ORIGIN}${p}`, method);
        expect(nextCalled, `${method} ${p}`).toBe(false);
        expect(res?.status, `${method} ${p}`).toBe(404);
      }
    }
  });

  it('passes other paths on other hosts through unchanged', async () => {
    for (const p of NON_MCP_PATHS) {
      const { res, nextCalled } = await run(`${API_ORIGIN}${p}`);
      expect(res, p).toBeUndefined();
      expect(nextCalled, p).toBe(true);
    }
  });
});
