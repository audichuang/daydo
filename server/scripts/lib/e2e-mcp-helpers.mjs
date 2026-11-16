// Helpers for scripts/e2e-mcp.mjs: dev server lifecycle, fake identity providers,
// App sign-in and sync, the browser side of /authorize, /token and JSON-RPC calls.
import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { createHash, randomBytes, randomUUID } from 'node:crypto';
import http from 'node:http';
import net from 'node:net';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { exportJWK, generateKeyPair, SignJWT } from 'jose';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
export const serverDir = path.resolve(__dirname, '../..');

export const APPLE_KID = 'apple-e2e-mcp-1';
export const APP_APPLE_AUDIENCE = 'com.audichuang.daydo';
export const WEB_APPLE_AUDIENCE = 'com.audichuang.daydo.web';
export const GOOGLE_WEB_CLIENT_ID = 'daydo-web-e2e-client-id';
export const GOOGLE_WEB_CLIENT_SECRET = 'daydo-web-e2e-client-secret';

export function sha256Hex(input) {
  return createHash('sha256').update(input, 'utf8').digest('hex');
}

export function b64url(buf) {
  return Buffer.from(buf).toString('base64url');
}

export function pkcePair() {
  const verifier = b64url(randomBytes(32));
  const challenge = createHash('sha256').update(verifier, 'ascii').digest('base64url');
  return { verifier, challenge };
}

export function getFreePort() {
  return new Promise((resolve, reject) => {
    const srv = net.createServer();
    srv.unref();
    srv.on('error', reject);
    srv.listen(0, '127.0.0.1', () => {
      const addr = srv.address();
      if (!addr || typeof addr === 'string') {
        srv.close(() => reject(new Error('Failed to resolve free port')));
        return;
      }
      const port = addr.port;
      srv.close((err) => (err ? reject(err) : resolve(port)));
    });
  });
}

function killProcessTree(child) {
  if (!child || child.exitCode !== null || child.signalCode !== null) return;
  try {
    process.kill(-child.pid, 'SIGTERM');
  } catch {
    try {
      child.kill('SIGTERM');
    } catch {
      return;
    }
  }
  setTimeout(() => {
    if (child.exitCode === null && child.signalCode === null) {
      try {
        process.kill(-child.pid, 'SIGKILL');
      } catch {
        try {
          child.kill('SIGKILL');
        } catch {
          // ignore
        }
      }
    }
  }, 1500).unref();
}

async function waitForHealth(baseUrl, child, getLogs) {
  const deadline = Date.now() + 30_000;
  while (Date.now() < deadline) {
    if (child.exitCode !== null) {
      throw new Error(`Dev server exited early (${child.exitCode}):\n${getLogs()}`);
    }
    try {
      const res = await fetch(`${baseUrl}/health`);
      if (res.ok) {
        const body = await res.json();
        if (body && body.ok === true) return;
      }
    } catch {
      // Server not listening yet
    }
    await new Promise((r) => setTimeout(r, 200));
  }
  throw new Error(`Timed out waiting for dev server at ${baseUrl}:\n${getLogs()}`);
}

/**
 * Fake identity providers on 127.0.0.1: an Apple JWKS (shared by the App audience and the
 * web Services ID) and a Google token endpoint that records every exchange request.
 */
export async function startFakeProviders() {
  const applePair = await generateKeyPair('RS256');
  const appleJwk = await exportJWK(applePair.publicKey);
  appleJwk.kid = APPLE_KID;
  appleJwk.alg = 'RS256';
  appleJwk.use = 'sig';

  const googleTokenRequests = [];
  const server = http.createServer((req, res) => {
    res.setHeader('Content-Type', 'application/json');
    if (req.method === 'GET' && req.url === '/apple/keys') {
      res.end(JSON.stringify({ keys: [appleJwk] }));
      return;
    }
    if (req.method === 'POST' && req.url === '/google/token') {
      let body = '';
      req.on('data', (chunk) => {
        body += chunk;
      });
      req.on('end', () => {
        googleTokenRequests.push({
          contentType: req.headers['content-type'] ?? '',
          form: Object.fromEntries(new URLSearchParams(body)),
        });
        // No id_token: the Worker treats it as a retryable provider error.
        res.end(JSON.stringify({ access_token: 'fake-google-access', token_type: 'Bearer' }));
      });
      return;
    }
    res.statusCode = 404;
    res.end(JSON.stringify({ error: 'Not found' }));
  });

  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const addr = server.address();
  assert(addr && typeof addr !== 'string', 'fake provider server failed to bind');
  const baseUrl = `http://127.0.0.1:${addr.port}`;

  return {
    baseUrl,
    googleTokenRequests,
    signApple: ({ sub, aud, nonce }) =>
      new SignJWT({ nonce, email: `${sub}@example.com` })
        .setProtectedHeader({ alg: 'RS256', kid: APPLE_KID })
        .setIssuer('https://appleid.apple.com')
        .setAudience(aud)
        .setSubject(sub)
        .setIssuedAt()
        .setExpirationTime('10m')
        .sign(applePair.privateKey),
    close: () => new Promise((resolve) => server.close(() => resolve())),
  };
}

/**
 * Applies local D1 migrations and boots the Worker on 127.0.0.1. With MCP_HOST=localhost,
 * http://localhost:<port> is the MCP host and http://127.0.0.1:<port> is the API host.
 */
export async function startDevServer(extraEnv) {
  const port = await getFreePort();
  const env = {
    ...process.env,
    JWT_SECRET: 'e2e-test-jwt-secret-must-be-at-least-32-bytes',
    ...extraEnv,
  };

  const migrateRes = spawnSync(path.join(serverDir, 'node_modules/.bin/void'), ['db', 'migrate'], {
    cwd: serverDir,
    env,
    encoding: 'utf8',
  });
  assert.equal(migrateRes.status, 0, `void db migrate failed:\n${migrateRes.stdout}\n${migrateRes.stderr}`);

  const logs = [];
  const appendLog = (chunk) => {
    logs.push(chunk.toString());
    if (logs.length > 400) logs.shift();
  };
  const getLogs = () => logs.join('');

  const child = spawn(
    path.join(serverDir, 'node_modules/.bin/vite'),
    ['--port', String(port), '--host', '127.0.0.1', '--strictPort'],
    { cwd: serverDir, env, detached: true, stdio: ['ignore', 'pipe', 'pipe'] },
  );
  child.stdout.on('data', appendLog);
  child.stderr.on('data', appendLog);

  const apiBase = `http://127.0.0.1:${port}`;
  const mcpBase = `http://localhost:${port}`;
  const stop = () => killProcessTree(child);
  try {
    await waitForHealth(apiBase, child, getLogs);
  } catch (error) {
    stop();
    throw error;
  }
  return { apiBase, mcpBase, env, getLogs, stop };
}

/** Number of rows in the local D1 `user` table, read through the void CLI. */
export function countUsers(env) {
  const res = spawnSync(
    path.join(serverDir, 'node_modules/.bin/void'),
    ['db', 'execute', 'SELECT count(*) AS userCount FROM user'],
    { cwd: serverDir, env, encoding: 'utf8' },
  );
  assert.equal(res.status, 0, `void db execute failed:\n${res.stdout}\n${res.stderr}`);
  const match = `${res.stdout}\n${res.stderr}`.match(/userCount\D*(\d+)/);
  assert(match, `could not read user count from:\n${res.stdout}\n${res.stderr}`);
  return Number(match[1]);
}

// ---------------------------------------------------------------------------
// HTTP helpers

export async function postJson(url, body, token) {
  const headers = { 'Content-Type': 'application/json' };
  if (token) headers.Authorization = `Bearer ${token}`;
  const res = await fetch(url, { method: 'POST', headers, body: JSON.stringify(body) });
  const data = await res.json().catch(() => null);
  return { status: res.status, headers: res.headers, data };
}

export async function postForm(url, fields, headers = {}) {
  const res = await fetch(url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded', ...headers },
    body: new URLSearchParams(fields),
    redirect: 'manual',
  });
  return { status: res.status, location: res.headers.get('location'), text: await res.text() };
}

async function getManual(url, headers = {}) {
  const res = await fetch(url, { headers, redirect: 'manual' });
  return { status: res.status, headers: res.headers, location: res.headers.get('location'), text: await res.text() };
}

// ---------------------------------------------------------------------------
// App (device) side

export async function appLogin(apiBase, providers, sub, deviceId = `dev-${randomUUID()}`) {
  const rawNonce = `nonce-${randomUUID()}`;
  const identityToken = await providers.signApple({ sub, aud: APP_APPLE_AUDIENCE, nonce: sha256Hex(rawNonce) });
  const res = await postJson(`${apiBase}/auth/apple`, { identityToken, nonce: rawNonce, deviceId });
  assert.equal(res.status, 200, `App Apple login failed: ${JSON.stringify(res.data)}`);
  return { ...res.data, deviceId: deviceId.toLowerCase() };
}

function makeHlc(ms, counter, deviceId) {
  return `${String(ms).padStart(13, '0')}:${String(counter).padStart(4, '0')}:${deviceId}`;
}

/** Pushes the me-member and the inbox the App creates on first sync; returns their ids. */
export async function seedMemberAndInbox(apiBase, login) {
  const memberId = randomUUID();
  const inboxId = randomUUID();
  const now = Date.now();
  const ops = [
    {
      opId: randomUUID(),
      hlc: makeHlc(now, 0, login.deviceId),
      entity: 'member',
      entityId: memberId,
      op: 'upsert',
      fields: ['id', 'name', 'initial', 'color', 'isMe', 'createdAt', 'updatedAt'],
      row: { id: memberId, name: 'MCP E2E', initial: 'M', color: '#9BB8FF', isMe: true, createdAt: now, updatedAt: now },
    },
    {
      opId: randomUUID(),
      hlc: makeHlc(now, 1, login.deviceId),
      entity: 'project',
      entityId: inboxId,
      op: 'upsert',
      fields: ['id', 'name', 'viewMode', 'kind', 'isInbox', 'ownerId', 'sortKey', 'showInSmart', 'notifyMode', 'createdAt', 'updatedAt'],
      row: {
        id: inboxId,
        name: 'Inbox',
        viewMode: 'list',
        kind: 'TASK',
        isInbox: true,
        ownerId: memberId,
        sortKey: 'a',
        showInSmart: 'all',
        notifyMode: 'all',
        createdAt: now,
        updatedAt: now,
      },
    },
  ];
  const res = await postJson(`${apiBase}/sync/push`, { deviceId: login.deviceId, ops }, login.accessToken);
  assert.equal(res.status, 200, `seed push failed: ${JSON.stringify(res.data)}`);
  for (const r of res.data.results) assert.equal(r.status, 'applied', `seed op not applied: ${JSON.stringify(r)}`);
  return { memberId, inboxId };
}

/** All rows of the user's own scope from cursor 0, following pages. */
export async function pullOwnScope(apiBase, login) {
  const scope = `u:${login.user.id}`;
  const rows = [];
  let cursor = 0;
  for (let page = 0; page < 20; page += 1) {
    const res = await postJson(`${apiBase}/sync/pull`, { cursors: { [scope]: cursor }, limit: 500 }, login.accessToken);
    assert.equal(res.status, 200, `pull failed: ${JSON.stringify(res.data)}`);
    const slice = res.data.scopes.find((s) => s.scope === scope);
    assert(slice, `scope ${scope} missing from pull: ${JSON.stringify(res.data)}`);
    rows.push(...slice.rows);
    if (!slice.hasMore) return rows;
    cursor = slice.cursor;
  }
  throw new Error('pull did not finish within 20 pages');
}

// ---------------------------------------------------------------------------
// OAuth client side

/** Registers one public client. A random CF-Connecting-IP keeps reruns clear of the per-IP limit. */
export async function registerClient(mcpBase, redirectUri) {
  const ip = `198.51.100.${1 + Math.floor(Math.random() * 254)}-${randomUUID()}`;
  const res = await fetch(`${mcpBase}/register`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'CF-Connecting-IP': ip },
    body: JSON.stringify({ client_name: 'DayDo MCP e2e', redirect_uris: [redirectUri] }),
  });
  const data = await res.json().catch(() => null);
  assert.equal(res.status, 201, `register failed: ${res.status} ${JSON.stringify(data)}`);
  assert.match(data.client_id, /^mcp-/);
  return data.client_id;
}

function readBindCookie(headers) {
  for (const value of headers.getSetCookie()) {
    const first = value.split(';')[0];
    const eq = first.indexOf('=');
    if (first.slice(0, eq).trim() === 'daydo_oauth_bind') return first.slice(eq + 1).trim();
  }
  return null;
}

/**
 * GET /authorize as a fresh browser: returns the pending id, the bind cookie header and the
 * PKCE verifier for this attempt.
 */
export async function beginAuthorize(mcpBase, { clientId, redirectUri, state = `st-${randomUUID()}` }) {
  const pkce = pkcePair();
  const url = new URL(`${mcpBase}/authorize`);
  url.searchParams.set('response_type', 'code');
  url.searchParams.set('client_id', clientId);
  url.searchParams.set('redirect_uri', redirectUri);
  url.searchParams.set('scope', 'mcp offline_access');
  url.searchParams.set('state', state);
  url.searchParams.set('code_challenge', pkce.challenge);
  url.searchParams.set('code_challenge_method', 'S256');
  url.searchParams.set('resource', mcpBase);
  // A fresh address per attempt: the local D1 persists across runs and GET /authorize is limited per IP.
  const res = await getManual(url.toString(), { 'CF-Connecting-IP': `198.51.100.${1 + Math.floor(Math.random() * 254)}-${randomUUID()}` });
  assert.equal(res.status, 200, `GET /authorize failed: ${res.status} ${res.text}`);
  const bind = readBindCookie(res.headers);
  assert(bind, 'GET /authorize did not set the bind cookie');
  const href = res.text.replace(/&amp;/g, '&').match(/\/authorize\/start\?pending=([^&"]+)&provider=apple/);
  assert(href, `login page has no Apple button:\n${res.text}`);
  return { pendingId: decodeURIComponent(href[1]), cookie: `daydo_oauth_bind=${bind}`, verifier: pkce.verifier, state };
}

/** GET /authorize/start; returns the provider redirect URL. */
export async function startProvider(mcpBase, attempt, provider) {
  const res = await getManual(
    `${mcpBase}/authorize/start?pending=${encodeURIComponent(attempt.pendingId)}&provider=${provider}`,
    { Cookie: attempt.cookie },
  );
  assert.equal(res.status, 302, `start ${provider} failed: ${res.status} ${res.text}`);
  return new URL(res.location);
}

/** Apple form_post callback with a locally signed id_token; cookie may be omitted. */
export async function appleCallback(mcpBase, providers, attempt, { sub, nonceHash, withCookie = true }) {
  const idToken = await providers.signApple({ sub, aud: WEB_APPLE_AUDIENCE, nonce: nonceHash });
  return postForm(
    `${mcpBase}/authorize/apple/callback`,
    { state: attempt.pendingId, id_token: idToken, code: 'apple-code-discarded' },
    withCookie ? { Cookie: attempt.cookie } : {},
  );
}

export async function googleCallback(mcpBase, attempt, params) {
  const url = new URL(`${mcpBase}/authorize/google/callback`);
  url.searchParams.set('state', attempt.pendingId);
  for (const [k, v] of Object.entries(params)) url.searchParams.set(k, v);
  return getManual(url.toString(), { Cookie: attempt.cookie });
}

/** Consent page GET then approve POST; returns the authorization code from the redirect. */
export async function approveConsent(mcpBase, attempt, consentLocation, redirectUri) {
  const consentUrl = new URL(consentLocation, mcpBase);
  const page = await getManual(consentUrl.toString(), { Cookie: attempt.cookie });
  assert.equal(page.status, 200, `consent page failed: ${page.status} ${page.text}`);
  assert.match(page.text, /授權存取 DayDo/);
  const ct = consentUrl.searchParams.get('ct');
  const post = await postForm(
    `${mcpBase}/authorize`,
    { pending: attempt.pendingId, ct, decision: 'approve' },
    { Cookie: attempt.cookie },
  );
  assert.equal(post.status, 302, `consent POST failed: ${post.status} ${post.text}`);
  const redirect = new URL(post.location);
  assert.equal(`${redirect.origin}${redirect.pathname}`, redirectUri);
  assert.equal(redirect.searchParams.get('state'), attempt.state);
  const code = redirect.searchParams.get('code');
  assert(code, `no code in redirect ${post.location}`);
  return code;
}

export async function tokenRequest(mcpBase, fields) {
  const res = await fetch(`${mcpBase}/token`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams(fields),
  });
  return { status: res.status, data: await res.json().catch(() => null) };
}

/** Full Apple path for an existing DayDo identity: authorize → callback → consent → token. */
export async function authorizeWithApple(mcpBase, providers, { clientId, redirectUri, sub }) {
  const attempt = await beginAuthorize(mcpBase, { clientId, redirectUri });
  const appleUrl = await startProvider(mcpBase, attempt, 'apple');
  const callback = await appleCallback(mcpBase, providers, attempt, { sub, nonceHash: appleUrl.searchParams.get('nonce') });
  assert.equal(callback.status, 303, `Apple callback failed: ${callback.status} ${callback.text}`);
  const code = await approveConsent(mcpBase, attempt, callback.location, redirectUri);
  const token = await tokenRequest(mcpBase, {
    grant_type: 'authorization_code',
    code,
    code_verifier: attempt.verifier,
    redirect_uri: redirectUri,
    client_id: clientId,
  });
  assert.equal(token.status, 200, `token exchange failed: ${JSON.stringify(token.data)}`);
  return { code, verifier: attempt.verifier, tokens: token.data };
}

// ---------------------------------------------------------------------------
// MCP JSON-RPC

let rpcId = 0;

export async function mcpRpc(mcpBase, accessToken, method, params) {
  rpcId += 1;
  const headers = { 'Content-Type': 'application/json', Accept: 'application/json, text/event-stream' };
  if (accessToken) headers.Authorization = `Bearer ${accessToken}`;
  const res = await fetch(`${mcpBase}/`, {
    method: 'POST',
    headers,
    body: JSON.stringify({ jsonrpc: '2.0', id: rpcId, method, ...(params !== undefined && { params }) }),
  });
  const data = await res.json().catch(() => null);
  return { status: res.status, headers: res.headers, data };
}

export async function callTool(mcpBase, accessToken, name, args) {
  const res = await mcpRpc(mcpBase, accessToken, 'tools/call', { name, arguments: args });
  assert.equal(res.status, 200, `tools/call ${name} HTTP ${res.status}: ${JSON.stringify(res.data)}`);
  assert(res.data && res.data.result, `tools/call ${name} returned no result: ${JSON.stringify(res.data)}`);
  return res.data.result;
}
