// e2e:mcp (spec/mcp.md 11): OAuth on the MCP host → MCP tools → a second device pulls the
// task from the API host. MCP_HOST=localhost makes http://localhost:<port> the MCP host and
// http://127.0.0.1:<port> the API host on one dev server.
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import {
  GOOGLE_WEB_CLIENT_ID,
  GOOGLE_WEB_CLIENT_SECRET,
  WEB_APPLE_AUDIENCE,
  appEmailLogin,
  appLogin,
  appleCallback,
  approveConsent,
  authorizeWithApple,
  beginAuthorize,
  callTool,
  countUsers,
  emailAuthorizeStart,
  emailAuthorizeVerify,
  googleCallback,
  mcpRpc,
  postJson,
  pullOwnScope,
  readMailCode,
  registerClient,
  seedMemberAndInbox,
  startDevServer,
  startFakeProviders,
  startProvider,
  tokenRequest,
} from './lib/e2e-mcp-helpers.mjs';

const REDIRECT_URI = 'http://127.0.0.1:65530/callback';
const NO_DATA_MESSAGE = '請先在 DayDo App 登入並同步一次';

function toolText(result) {
  assert(Array.isArray(result.content) && result.content[0]?.type === 'text', JSON.stringify(result));
  return result.content[0].text;
}

async function hostGate({ apiBase, mcpBase }) {
  const health = await fetch(`${mcpBase}/`);
  assert.equal(health.status, 200);
  const body = await health.json();
  assert.equal(body.ok, true);
  assert.equal(body.resource, mcpBase);
  assert.deepEqual(body.authorization_servers, [mcpBase]);

  // MCP paths are 404 on the API host.
  for (const p of ['/', '/register', '/token', '/authorize', '/authorize/start', '/authorize/email/start', '/authorize/email/verify', '/.well-known/oauth-authorization-server', '/.well-known/oauth-protected-resource']) {
    const res = await fetch(`${apiBase}${p}`, { redirect: 'manual' });
    assert.equal(res.status, 404, `API host ${p} should be 404, got ${res.status}`);
  }
  // API paths are 404 on the MCP host.
  assert.equal((await fetch(`${mcpBase}/health`)).status, 404);
  assert.equal((await postJson(`${mcpBase}/sync/pull`, { cursors: {} })).status, 404);
  assert.equal((await postJson(`${mcpBase}/auth/apple`, {})).status, 404);
  assert.equal((await fetch(`${mcpBase}/attachments/att-1/content`)).status, 404);
  assert.equal((await fetch(`${mcpBase}/attachments/att-1/content`, { method: 'PUT', body: 'x' })).status, 404);
  assert.equal((await fetch(`${apiBase}/health`)).status, 200);
}

async function main() {
  const providers = await startFakeProviders();
  let server = null;
  const cleanup = () => server?.stop();
  process.on('SIGINT', cleanup);
  process.on('SIGTERM', cleanup);

  try {
    server = await startDevServer({
      MCP_HOST: 'localhost',
      APPLE_AUDIENCE: 'com.audichuang.daydo',
      APPLE_JWKS_URL: `${providers.baseUrl}/apple/keys`,
      APPLE_WEB_AUDIENCE: WEB_APPLE_AUDIENCE,
      APPLE_AUTH_URL: `${providers.baseUrl}/apple/authorize`,
      GOOGLE_WEB_CLIENT_ID,
      GOOGLE_WEB_CLIENT_SECRET,
      GOOGLE_AUTH_URL: `${providers.baseUrl}/google/auth`,
      GOOGLE_TOKEN_URL: `${providers.baseUrl}/google/token`,
    });
    const { apiBase, mcpBase, env } = server;

    await hostGate({ apiBase, mcpBase });
    console.log('e2e-mcp: host gate passed');

    // A DayDo user with data: App login + push of the me-member and the inbox.
    const usersBefore = countUsers(env);
    const sub = `apple-mcp-${randomUUID()}`;
    const device1 = await appLogin(apiBase, providers, sub);
    assert.equal(device1.isNewAccount, true);
    // The count is read from the live local D1, so a new App account must show up.
    assert.equal(countUsers(env), usersBefore + 1, 'user count must see the new App account');
    const { inboxId } = await seedMemberAndInbox(apiBase, device1);

    const clientId = await registerClient(mcpBase, REDIRECT_URI);

    // Main flow: authorize (Apple form_post) → consent → token.
    const main = await authorizeWithApple(mcpBase, providers, { clientId, redirectUri: REDIRECT_URI, sub });
    assert.equal(main.tokens.token_type, 'Bearer');
    assert.equal(main.tokens.expires_in, 3600);
    assert.equal(typeof main.tokens.refresh_token, 'string');
    const accessToken = main.tokens.access_token;

    // The code is single-use.
    const reuse = await tokenRequest(mcpBase, {
      grant_type: 'authorization_code',
      code: main.code,
      code_verifier: main.verifier,
      redirect_uri: REDIRECT_URI,
      client_id: clientId,
    });
    assert.equal(reuse.status, 400);
    assert.equal(reuse.data.error, 'invalid_grant');
    console.log('e2e-mcp: authorize + token passed');

    // MCP: initialize → tools/list → create_task.
    const init = await mcpRpc(mcpBase, accessToken, 'initialize', {
      protocolVersion: '2025-06-18',
      capabilities: {},
      clientInfo: { name: 'e2e', version: '1' },
    });
    assert.equal(init.status, 200, JSON.stringify(init.data));
    assert.equal(init.data.result.protocolVersion, '2025-06-18');
    assert.equal(init.data.result.serverInfo.name, 'daydo');

    const list = await mcpRpc(mcpBase, accessToken, 'tools/list');
    assert.equal(list.status, 200);
    const toolNames = list.data.result.tools.map((t) => t.name);
    for (const name of ['create_task', 'list_projects', 'complete_task', 'add_ics_source']) {
      assert(toolNames.includes(name), `tools/list is missing ${name}: ${toolNames.join(', ')}`);
    }

    const title = `MCP e2e ${randomUUID()}`;
    const created = await callTool(mcpBase, accessToken, 'create_task', { project_id: inboxId, title });
    assert.notEqual(created.isError, true, toolText(created));
    const createdTask = JSON.parse(toolText(created));
    assert.equal(createdTask.title, title);
    assert.equal(typeof createdTask.id, 'string');

    const attPayload = Buffer.from('MCP e2e attachment bytes');
    const uploaded = await callTool(mcpBase, accessToken, 'upload_attachment', {
      project_id: inboxId,
      task_id: createdTask.id,
      content_base64: attPayload.toString('base64'),
      filename: 'docs/mcp-note.txt',
      content_type: 'text/plain',
    });
    assert.notEqual(uploaded.isError, true, toolText(uploaded));
    const uploadedAtt = JSON.parse(toolText(uploaded));
    assert.equal(uploadedAtt.file_name, 'docs_mcp-note.txt');
    assert.equal(uploadedAtt.size, attPayload.byteLength);
    assert.equal(uploadedAtt.mime_type, 'text/plain');

    const fetchedTaskRes = await callTool(mcpBase, accessToken, 'get_task', {
      project_id: inboxId,
      task_id: createdTask.id,
    });
    assert.notEqual(fetchedTaskRes.isError, true, toolText(fetchedTaskRes));
    const fetchedTask = JSON.parse(toolText(fetchedTaskRes));
    assert.deepEqual(fetchedTask.attachments, [
      {
        id: uploadedAtt.id,
        file_name: 'docs_mcp-note.txt',
        size: attPayload.byteLength,
        mime_type: 'text/plain',
        created_at: uploadedAtt.created_at,
      },
    ]);

    const fetchedAttRes = await callTool(mcpBase, accessToken, 'get_attachment', {
      project_id: inboxId,
      task_id: createdTask.id,
      attachment_id: uploadedAtt.id,
    });
    assert.notEqual(fetchedAttRes.isError, true, toolText(fetchedAttRes));
    const fetchedAtt = JSON.parse(toolText(fetchedAttRes));
    assert.deepEqual(fetchedAtt, {
      id: uploadedAtt.id,
      task_id: createdTask.id,
      file_name: 'docs_mcp-note.txt',
      size: attPayload.byteLength,
      mime_type: 'text/plain',
      created_at: uploadedAtt.created_at,
      content: attPayload.toString('utf8'),
    });

    // Second device: App token on the API host pulls the task + attachment and downloads content.
    const device2 = await appLogin(apiBase, providers, sub);
    assert.equal(device2.isNewAccount, false);
    assert.equal(device2.user.id, device1.user.id);
    const rows = await pullOwnScope(apiBase, device2);
    const pulled = rows.find((r) => r.entity === 'task' && r.row?.id === createdTask.id);
    assert(pulled, `second device did not pull task ${createdTask.id}`);
    assert.equal(pulled.row.title, title);
    assert.equal(pulled.row.projectId, inboxId);
    const pulledAtt = rows.find((r) => r.entity === 'attachment' && r.row?.id === uploadedAtt.id);
    assert(pulledAtt, `second device did not pull attachment ${uploadedAtt.id}`);

    const dlRes = await fetch(`${apiBase}/attachments/${uploadedAtt.id}/content`, {
      headers: { Authorization: `Bearer ${device2.accessToken}` },
    });
    assert.equal(dlRes.status, 200);
    assert.equal(dlRes.headers.get('content-type'), 'text/plain');
    assert.deepEqual(Buffer.from(await dlRes.arrayBuffer()), attPayload);
    console.log('e2e-mcp: initialize + tools/list + create_task + upload_attachment + second-device pull/download passed');

    // Token isolation both ways.
    const appOnMcp = await mcpRpc(mcpBase, device2.accessToken, 'tools/list');
    assert.equal(appOnMcp.status, 401);
    assert.match(appOnMcp.headers.get('www-authenticate') ?? '', /resource_metadata="http:\/\/localhost:\d+\/\.well-known\/oauth-protected-resource"/);
    const mcpOnApi = await postJson(`${apiBase}/sync/pull`, { cursors: {} }, accessToken);
    assert.equal(mcpOnApi.status, 401);
    console.log('e2e-mcp: token isolation passed');

    // Refresh, then two concurrent refreshes of the successor return the same successor.
    const refreshed = await tokenRequest(mcpBase, {
      grant_type: 'refresh_token',
      refresh_token: main.tokens.refresh_token,
      client_id: clientId,
    });
    assert.equal(refreshed.status, 200, JSON.stringify(refreshed.data));
    assert.notEqual(refreshed.data.refresh_token, main.tokens.refresh_token);
    const [r1, r2] = await Promise.all(
      [0, 1].map(() =>
        tokenRequest(mcpBase, { grant_type: 'refresh_token', refresh_token: refreshed.data.refresh_token, client_id: clientId }),
      ),
    );
    assert.equal(r1.status, 200, JSON.stringify(r1.data));
    assert.equal(r2.status, 200, JSON.stringify(r2.data));
    assert.equal(r1.data.refresh_token, r2.data.refresh_token);
    assert.notEqual(r1.data.refresh_token, refreshed.data.refresh_token);
    const afterRefresh = await mcpRpc(mcpBase, r2.data.access_token, 'tools/list');
    assert.equal(afterRefresh.status, 200);
    console.log('e2e-mcp: refresh + concurrent refresh passed');

    // A callback without the bind cookie fails and ends the pending.
    {
      const attempt = await beginAuthorize(mcpBase, { clientId, redirectUri: REDIRECT_URI });
      const appleUrl = await startProvider(mcpBase, attempt, 'apple');
      const nonceHash = appleUrl.searchParams.get('nonce');
      const noCookie = await appleCallback(mcpBase, providers, attempt, { sub, nonceHash, withCookie: false });
      assert.equal(noCookie.status, 400, noCookie.text);
      assert.match(noCookie.text, /同一個瀏覽器/);
      const retry = await appleCallback(mcpBase, providers, attempt, { sub, nonceHash });
      assert.equal(retry.status, 400, 'the pending must be ended after a cookie mismatch');
      assert.match(retry.text, /已失效或已完成/);
    }
    console.log('e2e-mcp: callback without cookie passed');

    // Unknown identity: no account is created.
    {
      const before = countUsers(env);
      const attempt = await beginAuthorize(mcpBase, { clientId, redirectUri: REDIRECT_URI });
      const appleUrl = await startProvider(mcpBase, attempt, 'apple');
      const unknown = await appleCallback(mcpBase, providers, attempt, {
        sub: `apple-unknown-${randomUUID()}`,
        nonceHash: appleUrl.searchParams.get('nonce'),
      });
      assert.equal(unknown.status, 403, unknown.text);
      assert.match(unknown.text, /還沒有 DayDo 帳號/);
      assert.equal(countUsers(env), before, 'unknown identity must not create a user');
    }
    console.log('e2e-mcp: unknown identity passed');

    // Google path (web client): start → cancelled callback keeps the pending → code exchange
    // reaches the token endpoint with the web client credentials.
    {
      const attempt = await beginAuthorize(mcpBase, { clientId, redirectUri: REDIRECT_URI });
      const googleUrl = await startProvider(mcpBase, attempt, 'google');
      assert.equal(`${googleUrl.origin}${googleUrl.pathname}`, `${providers.baseUrl}/google/auth`);
      assert.equal(googleUrl.searchParams.get('client_id'), GOOGLE_WEB_CLIENT_ID);
      assert.equal(googleUrl.searchParams.get('redirect_uri'), `${mcpBase}/authorize/google/callback`);
      assert.equal(googleUrl.searchParams.get('response_type'), 'code');
      assert.equal(googleUrl.searchParams.get('state'), attempt.pendingId);
      assert.equal(googleUrl.searchParams.get('prompt'), 'select_account');
      assert(googleUrl.searchParams.get('nonce'), 'Google authorize URL must carry the raw nonce');

      const cancelled = await googleCallback(mcpBase, attempt, { error: 'access_denied' });
      assert.equal(cancelled.status, 400);
      assert.match(cancelled.text, /登入已取消/);

      const code = `google-code-${randomUUID()}`;
      const exchanged = await googleCallback(mcpBase, attempt, { code });
      assert.equal(providers.googleTokenRequests.length, 1, 'the pending must survive a cancelled callback');
      assert.deepEqual(providers.googleTokenRequests[0].form, {
        grant_type: 'authorization_code',
        code,
        client_id: GOOGLE_WEB_CLIENT_ID,
        client_secret: GOOGLE_WEB_CLIENT_SECRET,
        redirect_uri: `${mcpBase}/authorize/google/callback`,
      });
      // The fake endpoint returns no id_token: a retryable provider error.
      assert.equal(exchanged.status, 400);
      assert.match(exchanged.text, /無法驗證登入結果/);
    }
    console.log('e2e-mcp: Google path passed');

    // Email path: sign up with an email code on the API host, then authorize on the MCP host with
    // an email code (wrong code first, then the right one) → consent → token → tools/list.
    {
      const email = `mcp-email-${randomUUID()}@example.com`;
      const usersBefore = countUsers(env);
      const login = await appEmailLogin(apiBase, email);
      assert.equal(login.isNewAccount, true);
      assert.equal(countUsers(env), usersBefore + 1);
      const { inboxId: emailInbox } = await seedMemberAndInbox(apiBase, login);

      const attempt = await beginAuthorize(mcpBase, { clientId, redirectUri: REDIRECT_URI });
      const noCookie = await emailAuthorizeStart(mcpBase, attempt, email, { withCookie: false });
      assert.equal(noCookie.status, 400, noCookie.text);
      assert.match(noCookie.text, /同一個瀏覽器/);

      const started = await emailAuthorizeStart(mcpBase, attempt, email.toUpperCase());
      assert.equal(started.status, 200, started.text);
      assert.match(started.text, /驗證碼已寄出/);
      assert.match(started.text, /action="\/authorize\/email\/verify"/);
      const code = await readMailCode(apiBase, email);

      const wrong = await emailAuthorizeVerify(mcpBase, attempt, email, code === '000000' ? '111111' : '000000');
      assert.equal(wrong.status, 400, wrong.text);
      assert.match(wrong.text, /驗證碼錯誤/);

      const verified = await emailAuthorizeVerify(mcpBase, attempt, email, code);
      assert.equal(verified.status, 303, verified.text);
      const authCode = await approveConsent(mcpBase, attempt, verified.location, REDIRECT_URI);
      const token = await tokenRequest(mcpBase, {
        grant_type: 'authorization_code',
        code: authCode,
        code_verifier: attempt.verifier,
        redirect_uri: REDIRECT_URI,
        client_id: clientId,
      });
      assert.equal(token.status, 200, JSON.stringify(token.data));
      const emailList = await mcpRpc(mcpBase, token.data.access_token, 'tools/list');
      assert.equal(emailList.status, 200, JSON.stringify(emailList.data));
      assert(emailList.data.result.tools.some((t) => t.name === 'create_task'));

      const emailTitle = `MCP email e2e ${randomUUID()}`;
      const emailTask = await callTool(mcpBase, token.data.access_token, 'create_task', { project_id: emailInbox, title: emailTitle });
      assert.notEqual(emailTask.isError, true, toolText(emailTask));
      const rows = await pullOwnScope(apiBase, login);
      assert(rows.some((r) => r.entity === 'task' && r.row?.title === emailTitle), 'email user did not pull the MCP task');

      // An address without a DayDo account: the code works but no account is bound or created.
      const before = countUsers(env);
      const stranger = `mcp-email-unknown-${randomUUID()}@example.com`;
      const unknownAttempt = await beginAuthorize(mcpBase, { clientId, redirectUri: REDIRECT_URI });
      assert.equal((await emailAuthorizeStart(mcpBase, unknownAttempt, stranger)).status, 200);
      const unknown = await emailAuthorizeVerify(mcpBase, unknownAttempt, stranger, await readMailCode(apiBase, stranger));
      assert.equal(unknown.status, 403, unknown.text);
      assert.match(unknown.text, /還沒有 DayDo 帳號/);
      assert.equal(countUsers(env), before, 'MCP email authorize must not create a user');
    }
    console.log('e2e-mcp: email path passed');

    // An App account that never synced: OAuth works, create_task is a tool error.
    {
      const emptySub = `apple-mcp-empty-${randomUUID()}`;
      const empty = await appLogin(apiBase, providers, emptySub);
      assert.equal(empty.hasData, false);
      const flow = await authorizeWithApple(mcpBase, providers, { clientId, redirectUri: REDIRECT_URI, sub: emptySub });
      const result = await callTool(mcpBase, flow.tokens.access_token, 'create_task', {
        project_id: randomUUID(),
        title: 'should not be created',
      });
      assert.equal(result.isError, true);
      assert.match(toolText(result), new RegExp(NO_DATA_MESSAGE));
    }
    console.log('e2e-mcp: no-data account passed');

    console.log('e2e-mcp: all scenarios passed');
  } finally {
    process.off('SIGINT', cleanup);
    process.off('SIGTERM', cleanup);
    server?.stop();
    await providers.close();
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
