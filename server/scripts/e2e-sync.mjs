import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { createHash, randomUUID } from 'node:crypto';
import { readFileSync } from 'node:fs';
import http from 'node:http';
import net from 'node:net';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { exportJWK, generateKeyPair, SignJWT } from 'jose';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const serverDir = path.resolve(__dirname, '..');
const fixturePath = path.resolve(serverDir, '../spec/fixtures/sync-ops.json');

function sha256Hex(input) {
  return createHash('sha256').update(input, 'utf8').digest('hex');
}

function getFreePort() {
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

async function startJwksServer() {
  const applePair = await generateKeyPair('RS256');
  const appleJwk = await exportJWK(applePair.publicKey);
  appleJwk.kid = 'apple-e2e-sync-1';
  appleJwk.alg = 'RS256';
  appleJwk.use = 'sig';

  const server = http.createServer((req, res) => {
    res.setHeader('Content-Type', 'application/json');
    if (req.url === '/apple/keys') {
      res.end(JSON.stringify({ keys: [appleJwk] }));
      return;
    }
    res.statusCode = 404;
    res.end(JSON.stringify({ error: 'Not found' }));
  });

  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const addr = server.address();
  assert(addr && typeof addr !== 'string', 'JWKS server failed to bind');

  return {
    baseUrl: `http://127.0.0.1:${addr.port}`,
    applePrivateKey: applePair.privateKey,
    close: () => new Promise((resolve) => server.close(() => resolve())),
  };
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

async function postJson(baseUrl, routePath, body, token) {
  const headers = { 'Content-Type': 'application/json' };
  if (token) headers.Authorization = `Bearer ${token}`;
  const res = await fetch(`${baseUrl}${routePath}`, {
    method: 'POST',
    headers,
    body: JSON.stringify(body),
  });
  const data = await res.json().catch(() => null);
  return { status: res.status, data };
}

async function getJson(baseUrl, routePath, token) {
  const headers = {};
  if (token) headers.Authorization = `Bearer ${token}`;
  const res = await fetch(`${baseUrl}${routePath}`, { headers });
  const data = await res.json().catch(() => null);
  return { status: res.status, data };
}

async function createUserToken(baseUrl, jwks, sub = `apple-sync-${randomUUID()}`) {
  const rawNonce = `nonce-${randomUUID()}`;
  const appleToken = await new SignJWT({
    nonce: sha256Hex(rawNonce),
    email: `${sub}@example.com`,
  })
    .setProtectedHeader({ alg: 'RS256', kid: 'apple-e2e-sync-1' })
    .setIssuer('https://appleid.apple.com')
    .setAudience('com.audichuang.daydo')
    .setSubject(sub)
    .setIssuedAt()
    .setExpirationTime('10m')
    .sign(jwks.applePrivateKey);

  const deviceId = `dev-${randomUUID()}`;
  const login = await postJson(baseUrl, '/auth/apple', {
    identityToken: appleToken,
    nonce: rawNonce,
    deviceId,
  });
  assert.equal(login.status, 200, `Apple login failed: ${JSON.stringify(login.data)}`);
  return {
    userId: login.data.user.id,
    token: login.data.accessToken,
    deviceId,
  };
}

function makeHlc(ms, counter, deviceId) {
  return `${String(ms).padStart(13, '0')}:${String(counter).padStart(4, '0')}:${deviceId.toLowerCase()}`;
}

function makeTaskOp({ opId = randomUUID(), hlc, entityId, fields, row, op = 'upsert' }) {
  return {
    opId,
    hlc,
    entity: 'task',
    entityId,
    op,
    fields,
    row,
  };
}

function parseOnlyArg(argv) {
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--only') {
      const val = argv[i + 1];
      if (!val) throw new Error('Missing value after --only');
      return val;
    }
    if (arg.startsWith('--only=')) {
      return arg.slice('--only='.length);
    }
  }
  return null;
}

/** Compute expected final row state from spec/fixtures/sync-ops.json. */
function computeFixtureExpectedState(ops) {
  const rows = new Map();
  for (const op of ops) {
    const key = `${op.entity}:${op.entityId}`;
    if (op.op === 'delete') {
      const prev = rows.get(key) ?? { entity: op.entity, entityId: op.entityId, row: {}, purged: false };
      prev.purged = true;
      rows.set(key, prev);
      continue;
    }
    const entry = rows.get(key) ?? { entity: op.entity, entityId: op.entityId, row: {}, purged: false };
    if (entry.purged) continue;

    const touchedSchedule =
      op.entity === 'task' &&
      op.fields.some((f) => ['startDay', 'startMinute', 'endDay', 'endMinute', 'timeZone'].includes(f));

    if (touchedSchedule) {
      for (const sf of ['startDay', 'startMinute', 'endDay', 'endMinute', 'timeZone']) {
        if (op.row[sf] === undefined || op.row[sf] === null) {
          delete entry.row[sf];
        } else {
          entry.row[sf] = op.row[sf];
        }
      }
    }

    for (const f of op.fields) {
      if (op.entity === 'member' && f === 'isMe') continue;
      if (op.entity === 'attachment' && (f === 'localPath' || f === 'originalPath')) continue;
      if (op.entity === 'task' && ['startDay', 'startMinute', 'endDay', 'endMinute', 'timeZone'].includes(f)) {
        continue;
      }
      if (op.row[f] === undefined || op.row[f] === null) {
        delete entry.row[f];
      } else {
        entry.row[f] = op.row[f];
      }
    }
    rows.set(key, entry);
  }
  return rows;
}

async function runFixtureScenario({ baseUrl, jwks }) {
  const fixture = JSON.parse(readFileSync(fixturePath, 'utf8'));
  const user = await createUserToken(baseUrl, jwks, 'e2e-sync-fixture-user');

  const pushRes = await postJson(
    baseUrl,
    '/sync/push',
    { deviceId: user.deviceId, ops: fixture.ops },
    user.token,
  );
  assert.equal(pushRes.status, 200, `Fixture push failed: ${JSON.stringify(pushRes.data)}`);
  assert.equal(pushRes.data.results.length, fixture.ops.length);
  for (const r of pushRes.data.results) {
    assert.equal(r.status, 'applied', `Expected applied for ${r.opId}, got ${JSON.stringify(r)}`);
  }

  // Verify member row in push response never contains isMe
  const memberResult = pushRes.data.results[0];
  assert.equal('isMe' in memberResult.row, false, 'member row must not contain isMe');

  // Pull all rows for the fixture user
  const pullRes = await getJson(baseUrl, '/sync/pull?since=0&limit=500', user.token);
  assert.equal(pullRes.status, 200);
  assert.equal(pullRes.data.hasMore, false);

  const expected = computeFixtureExpectedState(fixture.ops);
  const pulledByKey = new Map();
  for (const item of pullRes.data.rows) {
    const eid =
      item.entity === 'projectMember'
        ? `${item.row.projectId}:${item.row.memberId}`
        : item.entity === 'tag'
          ? item.row.name
          : item.row.id;
    pulledByKey.set(`${item.entity}:${eid}`, item);
  }

  assert.equal(pulledByKey.size, expected.size, 'Pulled row count should match fixture entity count');

  for (const [key, exp] of expected) {
    const got = pulledByKey.get(key);
    assert(got, `Missing pulled row for ${key}`);
    assert.equal('isMe' in got.row, false, `Pulled row ${key} must not have isMe`);

    if (exp.purged) {
      assert.equal(typeof got.row.purgedAt, 'number', `Expected purgedAt on ${key}`);
      const { purgedAt: _purgedAt, ...rowWithoutPurged } = got.row;
      assert.deepEqual(rowWithoutPurged, exp.row, `Purged row fields mismatch for ${key}`);
    } else {
      assert.equal('purgedAt' in got.row, false, `Non-purged row ${key} must omit purgedAt`);
      assert.deepEqual(got.row, exp.row, `Row mismatch for ${key}`);
    }
  }

  // Verify ?project=<id> backfills only that project's rows (project, projectMember, tasks, checklistItems)
  const travelProjectId = '01a1dd14-d0d7-7cb5-8cc6-d009167593dd';
  const projectPull = await getJson(
    baseUrl,
    `/sync/pull?since=0&limit=500&project=${travelProjectId}`,
    user.token,
  );
  assert.equal(projectPull.status, 200);
  const projectEntities = new Set(projectPull.data.rows.map((r) => r.entity));
  assert.equal(projectEntities.has('member'), false);
  assert.equal(projectEntities.has('tag'), false);
  assert.equal(projectPull.data.rows.length, 7); // 1 project + 1 projectMember + 3 tasks + 2 checklistItems
}

async function runLwwScenario({ baseUrl, jwks }) {
  const user = await createUserToken(baseUrl, jwks);
  const taskId = randomUUID();
  const projectId = randomUUID();
  const baseMs = Date.now();
  const olderHlc = makeHlc(baseMs, 1, user.deviceId);
  const newerHlc = makeHlc(baseMs, 5, user.deviceId);

  const pushNewer = await postJson(
    baseUrl,
    '/sync/push',
    {
      deviceId: user.deviceId,
      ops: [
        makeTaskOp({
          hlc: newerHlc,
          entityId: taskId,
          fields: ['id', 'projectId', 'title', 'sortKey', 'createdAt', 'updatedAt'],
          row: {
            id: taskId,
            projectId,
            title: 'Newer Title',
            sortKey: 'i',
            createdAt: baseMs,
            updatedAt: baseMs,
          },
        }),
      ],
    },
    user.token,
  );
  assert.equal(pushNewer.status, 200);
  assert.equal(pushNewer.data.results[0].status, 'applied');
  assert.equal(pushNewer.data.results[0].row.title, 'Newer Title');
  const seqAfterFirst = pushNewer.data.serverSeq;

  // Push older HLC for the same field -> still applied, but server row retains Newer Title
  const pushOlder = await postJson(
    baseUrl,
    '/sync/push',
    {
      deviceId: user.deviceId,
      ops: [
        makeTaskOp({
          hlc: olderHlc,
          entityId: taskId,
          fields: ['title', 'updatedAt'],
          row: {
            id: taskId,
            title: 'Older Title',
            updatedAt: baseMs - 100,
          },
        }),
      ],
    },
    user.token,
  );
  assert.equal(pushOlder.status, 200);
  assert.equal(pushOlder.data.results[0].status, 'applied');
  assert.equal(pushOlder.data.results[0].row.title, 'Newer Title');
  assert.equal(pushOlder.data.results[0].clocks.title, newerHlc);
  assert.equal(pushOlder.data.serverSeq, seqAfterFirst, 'Losing LWW op must not advance serverSeq');
}

async function runConcurrencyScenario({ baseUrl, jwks }) {
  const user = await createUserToken(baseUrl, jwks);
  const taskId = randomUUID();
  const projectId = randomUUID();
  const baseMs = Date.now();
  const initHlc = makeHlc(baseMs - 10_000, 0, user.deviceId);

  const initRes = await postJson(
    baseUrl,
    '/sync/push',
    {
      deviceId: user.deviceId,
      ops: [
        makeTaskOp({
          hlc: initHlc,
          entityId: taskId,
          fields: ['id', 'projectId', 'title', 'sortKey', 'createdAt', 'updatedAt'],
          row: {
            id: taskId,
            projectId,
            title: 'initial',
            sortKey: 'i',
            createdAt: baseMs - 10_000,
            updatedAt: baseMs - 10_000,
          },
        }),
      ],
    },
    user.token,
  );
  assert.equal(initRes.status, 200);
  const seqBefore = initRes.data.serverSeq;

  // Part 1: 20 concurrent requests updating the SAME task field with distinct HLCs,
  // placing the highest HLC in the middle so lower-HLC requests race both before and after it.
  const count = 20;
  const shuffledIndices = [
    ...Array.from({ length: 5 }, (_, i) => i),
    19,
    ...Array.from({ length: 14 }, (_, i) => i + 5),
  ];
  const sameFieldOps = shuffledIndices.map((rank) => {
    const hlc = makeHlc(baseMs, rank + 1, `dev-${String(rank).padStart(2, '0')}`);
    return {
      rank,
      hlc,
      expectedTitle: `title-${rank}`,
      op: makeTaskOp({
        hlc,
        entityId: taskId,
        fields: ['title'],
        row: { id: taskId, title: `title-${rank}` },
      }),
    };
  });

  const sameFieldResponses = await Promise.all(
    sameFieldOps.map((item) =>
      postJson(baseUrl, '/sync/push', { deviceId: user.deviceId, ops: [item.op] }, user.token),
    ),
  );

  const winningSeqs = [];
  for (let i = 0; i < sameFieldResponses.length; i += 1) {
    const res = sameFieldResponses[i];
    const item = sameFieldOps[i];
    assert.equal(res.status, 200);
    assert.equal(res.data.results[0].status, 'applied');
    if (res.data.results[0].clocks.title === item.hlc) {
      winningSeqs.push(res.data.serverSeq);
    }
  }

  assert(winningSeqs.length >= 1, 'At least the highest HLC must win');
  assert.equal(
    new Set(winningSeqs).size,
    winningSeqs.length,
    `Duplicate serverSeq among winning concurrent updates: ${JSON.stringify(winningSeqs)}`,
  );

  // Pull back taskA and assert the highest HLC (rank 19) won
  const pullAfterSameField = await getJson(
    baseUrl,
    `/sync/pull?since=${seqBefore}&limit=500`,
    user.token,
  );
  assert.equal(pullAfterSameField.status, 200);
  const pulledTask = pullAfterSameField.data.rows.find((r) => r.row.id === taskId);
  assert(pulledTask, 'Expected updated task in pull');
  assert.equal(
    pulledTask.row.title,
    'title-19',
    `Expected highest HLC value 'title-19', got '${pulledTask.row.title}'`,
  );

  // Part 2: 20 concurrent requests each applying a distinct change -> 20 unique strictly increasing serverSeqs
  const seqBeforeDistinct = pullAfterSameField.data.cursor;
  const distinctTasks = Array.from({ length: count }, (_, i) => {
    const id = randomUUID();
    const hlc = makeHlc(baseMs + 1, i, user.deviceId);
    return {
      id,
      op: makeTaskOp({
        hlc,
        entityId: id,
        fields: ['id', 'projectId', 'title', 'sortKey', 'createdAt', 'updatedAt'],
        row: {
          id,
          projectId,
          title: `concurrent-${i}`,
          sortKey: 'i',
          createdAt: baseMs,
          updatedAt: baseMs,
        },
      }),
    };
  });

  const distinctResponses = await Promise.all(
    distinctTasks.map((t) =>
      postJson(baseUrl, '/sync/push', { deviceId: user.deviceId, ops: [t.op] }, user.token),
    ),
  );
  const distinctSeqs = distinctResponses.map((r) => {
    assert.equal(r.status, 200);
    assert.equal(r.data.results[0].status, 'applied');
    return r.data.serverSeq;
  });

  assert.equal(
    new Set(distinctSeqs).size,
    count,
    `Expected ${count} unique serverSeqs, got collisions: ${JSON.stringify(distinctSeqs)}`,
  );

  const pullDistinct = await getJson(
    baseUrl,
    `/sync/pull?since=${seqBeforeDistinct}&limit=500`,
    user.token,
  );
  assert.equal(pullDistinct.status, 200);
  assert.equal(pullDistinct.data.rows.length, count, 'No lost updates allowed');
  const pulledSeqs = pullDistinct.data.rows.map((r) => r.serverSeq);
  for (let i = 1; i < pulledSeqs.length; i += 1) {
    assert(pulledSeqs[i] > pulledSeqs[i - 1], 'serverSeq must be strictly increasing');
  }
}

async function runReplayScenario({ baseUrl, jwks }) {
  const user = await createUserToken(baseUrl, jwks);
  const taskId = randomUUID();
  const projectId = randomUUID();
  const opId = randomUUID();
  const now = Date.now();
  const hlc = makeHlc(now, 0, user.deviceId);

  const op = makeTaskOp({
    opId,
    hlc,
    entityId: taskId,
    fields: ['id', 'projectId', 'title', 'sortKey', 'createdAt', 'updatedAt'],
    row: {
      id: taskId,
      projectId,
      title: 'Once Only',
      sortKey: 'i',
      createdAt: now,
      updatedAt: now,
    },
  });

  const first = await postJson(baseUrl, '/sync/push', { deviceId: user.deviceId, ops: [op] }, user.token);
  assert.equal(first.status, 200);
  assert.equal(first.data.results[0].status, 'applied');
  const seq1 = first.data.serverSeq;

  const replay = await postJson(baseUrl, '/sync/push', { deviceId: user.deviceId, ops: [op] }, user.token);
  assert.equal(replay.status, 200);
  assert.equal(replay.data.results[0].status, 'applied');
  assert.equal(replay.data.serverSeq, seq1, 'Replay must not increment serverSeq');
  assert.equal(replay.data.results[0].row.title, 'Once Only');

  const pull = await getJson(baseUrl, '/sync/pull?since=0&limit=500', user.token);
  assert.equal(pull.status, 200);
  assert.equal(pull.data.rows.length, 1);
  assert.equal(pull.data.rows[0].serverSeq, seq1);
}

async function runPagingScenario({ baseUrl, jwks }) {
  const user = await createUserToken(baseUrl, jwks);
  const projectId = randomUUID();
  const now = Date.now();
  const totalRows = 65;

  const ops = Array.from({ length: totalRows }, (_, i) => {
    const id = randomUUID();
    return makeTaskOp({
      hlc: makeHlc(now, i, user.deviceId),
      entityId: id,
      fields: ['id', 'projectId', 'title', 'sortKey', 'createdAt', 'updatedAt'],
      row: {
        id,
        projectId,
        title: `Task ${i}`,
        sortKey: 'i',
        createdAt: now,
        updatedAt: now,
      },
    });
  });

  const push = await postJson(baseUrl, '/sync/push', { deviceId: user.deviceId, ops }, user.token);
  assert.equal(push.status, 200);
  assert.equal(push.data.results.length, totalRows);

  let cursor = 0;
  let hasMore = true;
  const receivedIds = [];
  let pages = 0;

  while (hasMore) {
    pages += 1;
    const pull = await getJson(baseUrl, `/sync/pull?since=${cursor}&limit=7`, user.token);
    assert.equal(pull.status, 200);
    assert(pull.data.rows.length <= 7);
    if (pull.data.rows.length > 0) {
      assert.equal(pull.data.cursor, pull.data.rows[pull.data.rows.length - 1].serverSeq);
      assert(pull.data.cursor > cursor);
    }
    for (const r of pull.data.rows) {
      receivedIds.push(r.row.id);
    }
    cursor = pull.data.cursor;
    hasMore = pull.data.hasMore;
    assert(pages < 30, 'Too many pages; possible infinite loop');
  }

  assert.equal(receivedIds.length, totalRows, 'Must receive every row across paged pulls');
  assert.equal(new Set(receivedIds).size, totalRows, 'Must receive every row exactly once');
}

async function runAuthScenario({ baseUrl, jwks }) {
  // 1. Unauthenticated push / pull -> 401
  const unauthPush = await postJson(baseUrl, '/sync/push', { deviceId: 'd1', ops: [] });
  assert.equal(unauthPush.status, 401);

  const unauthPull = await getJson(baseUrl, '/sync/pull?since=0');
  assert.equal(unauthPull.status, 401);

  const badAuthPull = await getJson(baseUrl, '/sync/pull?since=0', 'not-a-valid-jwt');
  assert.equal(badAuthPull.status, 401);

  // 2. User A creates a row; User B cannot overwrite it and cannot pull it
  const userA = await createUserToken(baseUrl, jwks);
  const userB = await createUserToken(baseUrl, jwks);
  const taskId = randomUUID();
  const projectId = randomUUID();
  const now = Date.now();

  const pushA = await postJson(
    baseUrl,
    '/sync/push',
    {
      deviceId: userA.deviceId,
      ops: [
        makeTaskOp({
          hlc: makeHlc(now, 0, userA.deviceId),
          entityId: taskId,
          fields: ['id', 'projectId', 'title', 'sortKey', 'createdAt', 'updatedAt'],
          row: {
            id: taskId,
            projectId,
            title: 'User A Secret',
            sortKey: 'i',
            createdAt: now,
            updatedAt: now,
          },
        }),
      ],
    },
    userA.token,
  );
  assert.equal(pushA.status, 200);
  assert.equal(pushA.data.results[0].status, 'applied');

  const pushB = await postJson(
    baseUrl,
    '/sync/push',
    {
      deviceId: userB.deviceId,
      ops: [
        makeTaskOp({
          hlc: makeHlc(now + 1000, 0, userB.deviceId),
          entityId: taskId,
          fields: ['title'],
          row: { id: taskId, title: 'Hijacked by B' },
        }),
      ],
    },
    userB.token,
  );
  assert.equal(pushB.status, 200);
  assert.equal(pushB.data.results[0].status, 'rejected');
  assert.equal(typeof pushB.data.results[0].reason, 'string');
  assert.equal(pushB.data.results[0].row, null);

  const pullB = await getJson(baseUrl, '/sync/pull?since=0&limit=500', userB.token);
  assert.equal(pullB.status, 200);
  assert.equal(
    pullB.data.rows.some((r) => r.row.id === taskId),
    false,
    'User B must not see User A row in pull',
  );

  const pullA = await getJson(baseUrl, '/sync/pull?since=0&limit=500', userA.token);
  assert.equal(pullA.status, 200);
  const rowA = pullA.data.rows.find((r) => r.row.id === taskId);
  assert(rowA);
  assert.equal(rowA.row.title, 'User A Secret');
}

const SCENARIOS = {
  fixture: runFixtureScenario,
  lww: runLwwScenario,
  concurrency: runConcurrencyScenario,
  replay: runReplayScenario,
  paging: runPagingScenario,
  auth: runAuthScenario,
};

async function main() {
  const only = parseOnlyArg(process.argv.slice(2));
  if (only !== null && !(only in SCENARIOS)) {
    throw new Error(
      `Unknown scenario '${only}'. Expected one of: ${Object.keys(SCENARIOS).join(', ')}`,
    );
  }

  const jwks = await startJwksServer();
  const devPort = await getFreePort();
  const baseUrl = `http://127.0.0.1:${devPort}`;

  const env = {
    ...process.env,
    JWT_SECRET: 'e2e-test-jwt-secret-must-be-at-least-32-bytes',
    APPLE_AUDIENCE: 'com.audichuang.daydo',
    APPLE_JWKS_URL: `${jwks.baseUrl}/apple/keys`,
    GOOGLE_AUDIENCE: 'daydo-ios-e2e-client-id',
    GOOGLE_JWKS_URL: `${jwks.baseUrl}/apple/keys`,
  };

  let devChild = null;
  const logs = [];
  const appendLog = (chunk) => {
    logs.push(chunk.toString());
    if (logs.length > 200) logs.shift();
  };

  const cleanup = () => {
    killProcessTree(devChild);
  };
  process.on('SIGINT', cleanup);
  process.on('SIGTERM', cleanup);

  try {
    const migrateRes = spawnSync(
      path.join(serverDir, 'node_modules/.bin/void'),
      ['db', 'migrate'],
      { cwd: serverDir, env, encoding: 'utf8' },
    );
    assert.equal(
      migrateRes.status,
      0,
      `void db migrate failed:\n${migrateRes.stdout}\n${migrateRes.stderr}`,
    );

    devChild = spawn(
      path.join(serverDir, 'node_modules/.bin/vite'),
      ['--port', String(devPort), '--host', '127.0.0.1', '--strictPort'],
      {
        cwd: serverDir,
        env,
        detached: true,
        stdio: ['ignore', 'pipe', 'pipe'],
      },
    );
    devChild.stdout.on('data', appendLog);
    devChild.stderr.on('data', appendLog);

    await waitForHealth(baseUrl, devChild, () => logs.join(''));

    const toRun = only ? [only] : Object.keys(SCENARIOS);
    for (const name of toRun) {
      await SCENARIOS[name]({ baseUrl, jwks });
      console.log(`e2e-sync: scenario '${name}' passed`);
    }
  } finally {
    process.off('SIGINT', cleanup);
    process.off('SIGTERM', cleanup);
    killProcessTree(devChild);
    await jwks.close();
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
