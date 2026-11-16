// e2e:ics (spec/mcp.md 11): cron runtime probe, then a local http server serves ICS fixtures to
// add_ics_source / sync_ics_now / the dev cron, and a second device pulls the resulting tasks.
// MCP_HOST=localhost makes http://localhost:<port> the MCP host and http://127.0.0.1:<port> the API host.
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import http from 'node:http';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  appLogin,
  authorizeWithApple,
  callTool,
  postJson,
  pullOwnScope,
  registerClient,
  seedMemberAndInbox,
  serverDir,
  startDevServer,
  startFakeProviders,
} from './lib/e2e-mcp-helpers.mjs';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const REDIRECT_URI = 'http://127.0.0.1:65530/callback';
const DAY_MS = 86_400_000;

function parseOnlyArg(argv) {
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--only') {
      const val = argv[i + 1];
      if (!val) throw new Error('Missing value after --only');
      return val;
    }
    if (arg.startsWith('--only=')) return arg.slice('--only='.length);
  }
  return null;
}

const ANSI_RE = new RegExp(`${String.fromCharCode(27)}\\[[0-9;]*m`, 'g');
const stripAnsi = (s) => s.replace(ANSI_RE, '');

async function devTriggerToken(getLogs) {
  // The token hint prints after the server is ready, so it may land after /health succeeds.
  const tokenRe = /x-void-dev-trigger:\s*([0-9a-f-]{8,})/i;
  const deadline = Date.now() + 15_000;
  let match = null;
  while (Date.now() < deadline && !(match = stripAnsi(getLogs()).match(tokenRe))) await sleep(100);
  assert(match, `dev-trigger token not found in dev server output:\n${getLogs()}`);
  return match[1];
}


const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function toolJson(result) {
  assert(Array.isArray(result.content) && result.content[0]?.type === 'text', JSON.stringify(result));
  return result.content[0].text;
}

async function toolOk(ctx, name, args) {
  const result = await callTool(ctx.mcpBase, ctx.accessToken, name, args);
  assert.notEqual(result.isError, true, `${name} failed: ${toolJson(result)}`);
  return JSON.parse(toolJson(result));
}

const isoDay = (ms) => new Date(ms).toISOString().slice(0, 10);

/** Fixture files carry {{D1}}/{{D2}} (YYYYMMDD); the dates are relative to today so they stay inside the default window. */
function loadFixture(name) {
  const d1 = isoDay(Date.now() + 3 * DAY_MS).replaceAll('-', '');
  const d2 = isoDay(Date.now() + 4 * DAY_MS).replaceAll('-', '');
  const text = fs
    .readFileSync(path.join(__dirname, 'fixtures', name), 'utf8')
    .replaceAll('{{D1}}', d1)
    .replaceAll('{{D2}}', d2);
  return text.replace(/\r?\n/g, '\r\n');
}

async function startFixtureServer() {
  let current = '';
  const server = http.createServer((req, res) => {
    if (req.url?.startsWith('/feed.ics')) {
      res.setHeader('Content-Type', 'text/calendar');
      res.end(current);
      return;
    }
    res.statusCode = 404;
    res.end('not found');
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const addr = server.address();
  assert(addr && typeof addr !== 'string');
  return {
    url: `http://127.0.0.1:${addr.port}/feed.ics`,
    serve: (fixture) => {
      current = loadFixture(fixture);
    },
    close: () => new Promise((resolve) => server.close(() => resolve())),
  };
}

function executeSql(env, sql) {
  const res = spawnSync(path.join(serverDir, 'node_modules/.bin/void'), ['db', 'execute', sql], {
    cwd: serverDir,
    env,
    encoding: 'utf8',
  });
  assert.equal(res.status, 0, `void db execute failed:\n${res.stdout}\n${res.stderr}`);
}

function makeHlc(ms, counter, deviceId) {
  return `${String(ms).padStart(13, '0')}:${String(counter).padStart(4, '0')}:${deviceId}`;
}

/** An App edit: a delta push of the given task fields from `login`'s device. */
async function appEditTask(apiBase, login, taskId, set) {
  const now = Date.now();
  const row = { id: taskId, ...set, updatedAt: now };
  const res = await postJson(
    `${apiBase}/sync/push`,
    {
      deviceId: login.deviceId,
      ops: [
        {
          opId: randomUUID(),
          hlc: makeHlc(now, 0, login.deviceId),
          entity: 'task',
          entityId: taskId,
          op: 'upsert',
          fields: [...Object.keys(set), 'updatedAt'],
          row,
        },
      ],
    },
    login.accessToken,
  );
  assert.equal(res.status, 200, `App edit failed: ${JSON.stringify(res.data)}`);
  for (const r of res.data.results) assert.equal(r.status, 'applied', `App edit not applied: ${JSON.stringify(r)}`);
}

/** Latest task rows by id from a second device's full pull. */
async function pullTasks(apiBase, login) {
  const rows = await pullOwnScope(apiBase, login);
  const byId = new Map();
  for (const r of rows) if (r.entity === 'task' && r.row?.id) byId.set(r.row.id, r.row);
  return byId;
}

const taskByTitle = (tasks, title) => [...tasks.values()].find((t) => t.title === title);

async function newUser(server, providers) {
  const sub = `apple-ics-${randomUUID()}`;
  const device1 = await appLogin(server.apiBase, providers, sub);
  const { inboxId } = await seedMemberAndInbox(server.apiBase, device1);
  const clientId = await registerClient(server.mcpBase, REDIRECT_URI);
  const flow = await authorizeWithApple(server.mcpBase, providers, { clientId, redirectUri: REDIRECT_URI, sub });
  const device2 = await appLogin(server.apiBase, providers, sub);
  return {
    apiBase: server.apiBase,
    mcpBase: server.mcpBase,
    env: server.env,
    accessToken: flow.tokens.access_token,
    inboxId,
    device1,
    device2,
  };
}

async function triggerCron(server) {
  const token = await devTriggerToken(server.getLogs);
  const res = await fetch(`${server.apiBase}/__void/scheduled`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'x-void-dev-trigger': token },
    body: JSON.stringify({ cron: '*/5 * * * *', scheduledTime: Date.now() }),
  });
  const text = await res.text();
  assert.equal(res.status, 200, `scheduled trigger failed: ${res.status} ${text}`);
}

async function waitForSyncLog(getLogs, sourceId) {
  const deadline = Date.now() + 15_000;
  while (Date.now() < deadline) {
    for (const m of stripAnsi(getLogs()).matchAll(/\{"event":"ics\.sync"[^}]*\}/g)) {
      const entry = JSON.parse(m[0]);
      if (entry.source_id === sourceId) return entry;
    }
    await sleep(100);
  }
  throw new Error(`ics.sync log for source ${sourceId} not found:\n${getLogs()}`);
}

async function runSyncScenario(server, providers) {
  const fixture = await startFixtureServer();
  const cleanups = [];
  try {
    const ctx = await newUser(server, providers);
    const { apiBase, device2 } = ctx;

    // http to a host outside ICS_ALLOW_INSECURE_HOSTS is refused (https only, no private hosts).
    const rejected = await callTool(ctx.mcpBase, ctx.accessToken, 'add_ics_source', {
      name: 'insecure',
      url: 'http://192.168.1.10/feed.ics',
      project_id: ctx.inboxId,
    });
    assert.equal(rejected.isError, true, 'http source on a non-allowed host must be refused');
    assert.deepEqual(await toolOk(ctx, 'list_ics_sources', {}), []);

    // add_ics_source -> sync_ics_now -> the second device pulls the all-day and the timed task.
    fixture.serve('base.ics');
    const source = await toolOk(ctx, 'add_ics_source', {
      name: 'e2e feed',
      url: fixture.url,
      project_id: ctx.inboxId,
      timezone: 'Asia/Taipei',
    });
    cleanups.push(() => toolOk(ctx, 'remove_ics_source', { source_id: source.id }).catch(() => {}));
    const first = await toolOk(ctx, 'sync_ics_now', { source_id: source.id });
    assert.equal(first.created, 5, JSON.stringify(first));
    assert.equal(first.errors, 0, JSON.stringify(first));

    const d1 = isoDay(Date.now() + 3 * DAY_MS);
    let tasks = await pullTasks(apiBase, device2);
    const allDay = taskByTitle(tasks, 'E2E All day');
    assert(allDay, 'all-day task missing from second device pull');
    assert.equal(allDay.startDay, d1);
    assert.equal(allDay.startMinute ?? null, null, 'all-day task must have no start minute');
    assert.deepEqual(allDay.reminders ?? [], [], 'all-day task has no reminder');
    const timed = taskByTitle(tasks, 'E2E Timed meeting');
    assert(timed, 'timed task missing from second device pull');
    assert.equal(timed.startDay, d1);
    assert.equal(timed.startMinute, 600);
    assert.equal(timed.endMinute, 660);
    assert.equal(timed.timeZone, 'Asia/Taipei');
    assert.deepEqual(timed.reminders, ['TRIGGER:-PT15M']);
    assert.equal(timed.projectId, ctx.inboxId);
    console.log('e2e-ics: add + sync + second-device pull passed');

    // App edits made between two source revisions.
    const plain = taskByTitle(tasks, 'E2E Plain event');
    const done = taskByTitle(tasks, 'E2E Done event');
    const gone = taskByTitle(tasks, 'E2E Gone event');
    assert(plain && done && gone, 'plain/done/gone tasks missing');
    await appEditTask(apiBase, ctx.device1, plain.id, { priority: 3 });
    await appEditTask(apiBase, ctx.device1, done.id, { status: 2, completedAt: Date.now() });

    // The source changes; the dev cron (not sync_ics_now) picks the due source up.
    fixture.serve('changed.ics');
    executeSql(server.env, `UPDATE icsSource SET enabled = 0 WHERE id <> ${source.id}`);
    executeSql(server.env, `UPDATE icsSource SET lastSyncAt = 0, enabled = 1 WHERE id = ${source.id}`);
    await triggerCron(server);
    const log = await waitForSyncLog(server.getLogs, source.id);
    assert.equal(log.updated, 2, JSON.stringify(log));
    assert.equal(log.deleted, 1, JSON.stringify(log));
    assert.equal(log.errors, 0, JSON.stringify(log));

    tasks = await pullTasks(apiBase, device2);
    const timedAfter = tasks.get(timed.id);
    assert.equal(timedAfter.title, 'E2E Timed meeting moved', 'the same task is updated, not duplicated');
    assert.equal(timedAfter.startMinute, 840);
    assert.equal(timedAfter.endMinute, 900);
    assert.equal([...tasks.values()].filter((t) => t.title.startsWith('E2E Timed')).length, 1);
    const plainAfter = tasks.get(plain.id);
    assert.equal(plainAfter.title, 'E2E Plain event renamed');
    assert.equal(plainAfter.priority, 3, 'App-set priority survives a source update');
    assert(tasks.get(gone.id).deletedAt, 'task of a removed event must carry deletedAt');
    const doneAfter = tasks.get(done.id);
    assert.equal(doneAfter.status, 2, 'completed task stays completed while its event is unchanged');
    assert(!doneAfter.deletedAt);
    console.log('e2e-ics: cron update + priority kept + deletedAt + completion kept passed');

    // Mass-delete guard: six brand-new UIDs replace six imported ones, the whole round is refused.
    fixture.serve('mass-a.ics');
    const mass = await toolOk(ctx, 'add_ics_source', {
      name: 'e2e mass',
      url: fixture.url,
      project_id: ctx.inboxId,
      timezone: 'Asia/Taipei',
    });
    cleanups.push(() => toolOk(ctx, 'remove_ics_source', { source_id: mass.id }).catch(() => {}));
    const massFirst = await toolOk(ctx, 'sync_ics_now', { source_id: mass.id });
    assert.equal(massFirst.created, 6, JSON.stringify(massFirst));
    fixture.serve('mass-b.ics');
    const massSecond = await toolOk(ctx, 'sync_ics_now', { source_id: mass.id });
    assert.equal(massSecond.deleted, 0, JSON.stringify(massSecond));
    assert.equal(massSecond.created, 0, JSON.stringify(massSecond));
    assert(massSecond.lastError, `a refused round reports why: ${JSON.stringify(massSecond)}`);
    tasks = await pullTasks(apiBase, device2);
    for (let i = 1; i <= 6; i += 1) {
      const a = taskByTitle(tasks, `E2E Mass a${i}`);
      assert(a && !a.deletedAt, `mass-a${i} must survive a refused round`);
      assert.equal(taskByTitle(tasks, `E2E Mass b${i}`), undefined, `mass-b${i} must not be created`);
    }
    console.log('e2e-ics: mass-delete guard passed');
  } finally {
    for (const fn of cleanups) await fn();
    await fixture.close();
  }
}

async function runCronRuntimeScenario({ apiBase: baseUrl, getLogs }) {
  const token = await devTriggerToken(getLogs);
  const res = await fetch(`${baseUrl}/__void/scheduled`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'x-void-dev-trigger': token },
    body: JSON.stringify({ cron: '*/5 * * * *', scheduledTime: Date.now() }),
  });
  const text = await res.text();
  assert.equal(res.status, 200, `scheduled trigger failed: ${res.status} ${text}`);

  // The production cron queries D1 for due sources; a fresh database has none.
  const deadline = Date.now() + 10_000;
  let run = null;
  while (Date.now() < deadline && !run) {
    const m = stripAnsi(getLogs()).match(/\{"event":"ics\.cron\.run"[^}]*\}/);
    if (m) run = JSON.parse(m[0]);
    else await new Promise((r) => setTimeout(r, 100));
  }
  assert(run, `ics.cron.run log not found:\n${getLogs()}`);
  assert.equal(run.due, 0);
}


async function main() {
  const only = parseOnlyArg(process.argv.slice(2));
  const SCENARIOS = { cron_runtime: runCronRuntimeScenario, ics_sync: runSyncScenario };
  if (only !== null && !(only in SCENARIOS)) {
    throw new Error(`Unknown scenario '${only}'. Expected one of: ${Object.keys(SCENARIOS).join(', ')}`);
  }

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
      APPLE_WEB_AUDIENCE: 'com.audichuang.daydo.web',
      APPLE_AUTH_URL: `${providers.baseUrl}/apple/authorize`,
      ICS_ALLOW_INSECURE_HOSTS: '127.0.0.1',
    });

    const toRun = only ? [only] : Object.keys(SCENARIOS);
    for (const name of toRun) {
      await SCENARIOS[name](server, providers);
      console.log(`e2e-ics: scenario '${name}' passed`);
    }
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
