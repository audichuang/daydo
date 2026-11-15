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
    scope: `u:${login.data.user.id}`,
    token: login.data.accessToken,
    deviceId,
  };
}

function makeHlc(ms, counter, deviceId) {
  return `${String(ms).padStart(13, '0')}:${String(counter).padStart(4, '0')}:${deviceId.toLowerCase()}`;
}

function makeProjectOp({ opId = randomUUID(), hlc, projectId, ownerId, name = 'Test List', now }) {
  return {
    opId,
    hlc,
    entity: 'project',
    entityId: projectId,
    op: 'upsert',
    fields: [
      'id',
      'name',
      'viewMode',
      'kind',
      'isInbox',
      'ownerId',
      'sortKey',
      'showInSmart',
      'notifyMode',
      'createdAt',
      'updatedAt',
    ],
    row: {
      id: projectId,
      name,
      viewMode: 'list',
      kind: 'task',
      isInbox: false,
      ownerId,
      sortKey: 'i',
      showInSmart: 'all',
      notifyMode: 'all',
      createdAt: now,
      updatedAt: now,
    },
  };
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

function fullTaskCreateOp({ opId = randomUUID(), hlc, taskId, projectId, title, now }) {
  return makeTaskOp({
    opId,
    hlc,
    entityId: taskId,
    fields: [
      'id',
      'projectId',
      'title',
      'content',
      'priority',
      'status',
      'reminders',
      'tags',
      'sortKey',
      'createdAt',
      'updatedAt',
    ],
    row: {
      id: taskId,
      projectId,
      title,
      content: '',
      priority: 0,
      status: 0,
      reminders: [],
      tags: [],
      sortKey: 'i',
      createdAt: now,
      updatedAt: now,
    },
  });
}

async function pullSync(baseUrl, token, body = { cursors: {} }) {
  return postJson(baseUrl, '/sync/pull', body, token);
}

function getScopeSlice(pullData, scope) {
  const slice = pullData.scopes.find((s) => s.scope === scope);
  assert(slice, `Expected scope '${scope}' in pull response: ${JSON.stringify(pullData.scopes)}`);
  return slice;
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

/** Compute expected final row state from spec/fixtures/sync-ops.json (excluding projectMember/projectInvite). */
function computeFixtureExpectedState(ops) {
  const rows = new Map();
  for (const op of ops) {
    if (op.entity === 'projectMember' || op.entity === 'projectInvite') {
      continue;
    }
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
      if (op.entity === 'member' && f === 'isMe') {
        entry.row.isMe = op.row.isMe === true;
        continue;
      }
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
  const fixtureRaw = readFileSync(fixturePath, 'utf8');
  const fixture = JSON.parse(fixtureRaw);
  const user = await createUserToken(
    baseUrl,
    jwks,
    `e2e-sync-fixture-${sha256Hex(fixtureRaw).slice(0, 12)}`,
  );

  const pushRes = await postJson(
    baseUrl,
    '/sync/push',
    { deviceId: user.deviceId, ops: fixture.ops },
    user.token,
  );
  assert.equal(pushRes.status, 200, `Fixture push failed: ${JSON.stringify(pushRes.data)}`);
  assert.equal(pushRes.data.results.length, fixture.ops.length);
  for (let i = 0; i < fixture.ops.length; i += 1) {
    const op = fixture.ops[i];
    const r = pushRes.data.results[i];
    if (op.entity === 'projectMember' || op.entity === 'projectInvite') {
      assert.equal(r.status, 'rejected', `Expected rejected for ${op.entity} ${r.opId}`);
    } else {
      assert.equal(r.status, 'applied', `Expected applied for ${op.entity} ${r.opId}, got ${JSON.stringify(r)}`);
    }
  }

  // Verify member row in push response computes isMe boolean
  const memberResult = pushRes.data.results[0];
  assert.equal(memberResult.row.isMe, true, 'self member row must have isMe === true');

  // Pull all rows for the fixture user via POST /sync/pull
  const pullRes = await pullSync(baseUrl, user.token, { cursors: {}, limit: 500 });
  assert.equal(pullRes.status, 200);
  assert.deepEqual(pullRes.data.members, []);
  assert.equal(pullRes.data.memberships.length, 5);
  for (const m of pullRes.data.memberships) {
    assert.equal(m.scope, user.scope);
    assert.equal(m.role, 'owner');
  }

  const slice = getScopeSlice(pullRes.data, user.scope);
  assert.equal(slice.hasMore, false);

  const expected = computeFixtureExpectedState(fixture.ops);
  const pulledByKey = new Map();
  for (const item of slice.rows) {
    const eid = item.entity === 'tag' ? item.row.name : item.row.id;
    pulledByKey.set(`${item.entity}:${eid}`, item);
  }

  assert.equal(pulledByKey.size, expected.size, 'Pulled row count should match fixture entity count');

  for (const [key, exp] of expected) {
    const got = pulledByKey.get(key);
    assert(got, `Missing pulled row for ${key}`);
    if (got.entity === 'member') {
      assert.equal(typeof got.row.isMe, 'boolean', `Pulled member row ${key} must include boolean isMe`);
    }

    if (exp.purged) {
      assert.equal(typeof got.row.purgedAt, 'number', `Expected purgedAt on ${key}`);
      const { purgedAt: _purgedAt, ...rowWithoutPurged } = got.row;
      assert.deepEqual(rowWithoutPurged, exp.row, `Purged row fields mismatch for ${key}`);
    } else {
      assert.equal('purgedAt' in got.row, false, `Non-purged row ${key} must omit purgedAt`);
      assert.deepEqual(got.row, exp.row, `Row mismatch for ${key}`);
    }
  }

  // Verify backfill returns only that project's rows (project, tasks, checklistItems)
  const travelProjectOp = fixture.ops.find(
    (op) => op.entity === 'project' && op.row?.name === '旅行計畫',
  );
  assert(travelProjectOp, 'Missing 旅行計畫 project in fixture');
  const travelProjectId = travelProjectOp.entityId;
  const projectPull = await pullSync(baseUrl, user.token, {
    cursors: { [user.scope]: 0 },
    backfill: [travelProjectId],
    limit: 500,
  });
  assert.equal(projectPull.status, 200);
  const backfillSlice = getScopeSlice(projectPull.data, user.scope);
  const projectEntities = new Set(backfillSlice.rows.map((r) => r.entity));
  assert.equal(projectEntities.has('member'), false);
  assert.equal(projectEntities.has('tag'), false);
  assert.equal(projectEntities.has('projectMember'), false);
  assert.equal(projectEntities.has('projectInvite'), false);
  assert.equal(backfillSlice.rows.length, 6); // 1 project + 3 tasks + 2 checklistItems
}

async function runLwwScenario({ baseUrl, jwks }) {
  const user = await createUserToken(baseUrl, jwks);
  const taskId = randomUUID();
  const projectId = randomUUID();
  const baseMs = Date.now();
  const projectHlc = makeHlc(baseMs - 1000, 0, user.deviceId);
  const olderHlc = makeHlc(baseMs, 1, user.deviceId);
  const newerHlc = makeHlc(baseMs, 5, user.deviceId);

  const pushNewer = await postJson(
    baseUrl,
    '/sync/push',
    {
      deviceId: user.deviceId,
      ops: [
        makeProjectOp({ hlc: projectHlc, projectId, ownerId: user.userId, now: baseMs }),
        fullTaskCreateOp({
          hlc: newerHlc,
          taskId,
          projectId,
          title: 'Newer Title',
          now: baseMs,
        }),
      ],
    },
    user.token,
  );
  assert.equal(pushNewer.status, 200);
  assert.equal(pushNewer.data.results[0].status, 'applied');
  assert.equal(pushNewer.data.results[1].status, 'applied');
  assert.equal(pushNewer.data.results[1].row.title, 'Newer Title');

  const pullAfterFirst = await pullSync(baseUrl, user.token, { cursors: {} });
  assert.equal(pullAfterFirst.status, 200);
  const seqAfterFirst = getScopeSlice(pullAfterFirst.data, user.scope).cursor;

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

  const pullAfterOlder = await pullSync(baseUrl, user.token, {
    cursors: { [user.scope]: seqAfterFirst },
  });
  assert.equal(pullAfterOlder.status, 200);
  const sliceAfterOlder = getScopeSlice(pullAfterOlder.data, user.scope);
  assert.equal(sliceAfterOlder.rows.length, 0, 'Losing LWW op must not advance serverSeq');
  assert.equal(sliceAfterOlder.cursor, seqAfterFirst);
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
        makeProjectOp({ hlc: initHlc, projectId, ownerId: user.userId, now: baseMs - 10_000 }),
        fullTaskCreateOp({
          hlc: makeHlc(baseMs - 9000, 0, user.deviceId),
          taskId,
          projectId,
          title: 'initial',
          now: baseMs - 9000,
        }),
      ],
    },
    user.token,
  );
  assert.equal(initRes.status, 200);
  assert.equal(initRes.data.results[0].status, 'applied');
  assert.equal(initRes.data.results[1].status, 'applied');

  const initPull = await pullSync(baseUrl, user.token, { cursors: {} });
  assert.equal(initPull.status, 200);
  const seqBefore = getScopeSlice(initPull.data, user.scope).cursor;

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

  for (const res of sameFieldResponses) {
    assert.equal(res.status, 200);
    assert.equal(res.data.results[0].status, 'applied');
  }

  // Pull back taskA and assert the highest HLC (rank 19) won
  const pullAfterSameField = await pullSync(baseUrl, user.token, {
    cursors: { [user.scope]: seqBefore },
    limit: 500,
  });
  assert.equal(pullAfterSameField.status, 200);
  const sliceAfterSameField = getScopeSlice(pullAfterSameField.data, user.scope);
  const pulledTask = sliceAfterSameField.rows.find((r) => r.row?.id === taskId);
  assert(pulledTask, 'Expected updated task in pull');
  assert.equal(
    pulledTask.row.title,
    'title-19',
    `Expected highest HLC value 'title-19', got '${pulledTask.row.title}'`,
  );

  // Part 2: 20 concurrent requests each creating a distinct task -> 20 unique strictly increasing serverSeqs
  const seqBeforeDistinct = sliceAfterSameField.cursor;
  const distinctTasks = Array.from({ length: count }, (_, i) => {
    const id = randomUUID();
    const hlc = makeHlc(baseMs + 1, i, user.deviceId);
    return {
      id,
      op: fullTaskCreateOp({
        hlc,
        taskId: id,
        projectId,
        title: `concurrent-${i}`,
        now: baseMs,
      }),
    };
  });

  const distinctResponses = await Promise.all(
    distinctTasks.map((t) =>
      postJson(baseUrl, '/sync/push', { deviceId: user.deviceId, ops: [t.op] }, user.token),
    ),
  );
  for (const r of distinctResponses) {
    assert.equal(r.status, 200);
    assert.equal(r.data.results[0].status, 'applied');
  }

  const pullDistinct = await pullSync(baseUrl, user.token, {
    cursors: { [user.scope]: seqBeforeDistinct },
    limit: 500,
  });
  assert.equal(pullDistinct.status, 200);
  const distinctSlice = getScopeSlice(pullDistinct.data, user.scope);
  assert.equal(distinctSlice.rows.length, count, 'No lost updates allowed');
  const pulledSeqs = distinctSlice.rows.map((r) => r.serverSeq);
  assert.equal(
    new Set(pulledSeqs).size,
    count,
    `Expected ${count} unique serverSeqs, got collisions: ${JSON.stringify(pulledSeqs)}`,
  );
  for (let i = 1; i < pulledSeqs.length; i += 1) {
    assert(pulledSeqs[i] > pulledSeqs[i - 1], 'serverSeq must be strictly increasing');
  }
  assert.equal(distinctSlice.cursor, seqBeforeDistinct + count);
}

async function runReplayScenario({ baseUrl, jwks }) {
  const user = await createUserToken(baseUrl, jwks);
  const taskId = randomUUID();
  const projectId = randomUUID();
  const opId = randomUUID();
  const now = Date.now();

  const op = fullTaskCreateOp({
    opId,
    hlc: makeHlc(now, 1, user.deviceId),
    taskId,
    projectId,
    title: 'Once Only',
    now,
  });

  const first = await postJson(
    baseUrl,
    '/sync/push',
    {
      deviceId: user.deviceId,
      ops: [makeProjectOp({ hlc: makeHlc(now, 0, user.deviceId), projectId, ownerId: user.userId, now }), op],
    },
    user.token,
  );
  assert.equal(first.status, 200);
  assert.equal(first.data.results[0].status, 'applied');
  assert.equal(first.data.results[1].status, 'applied');

  const pull1 = await pullSync(baseUrl, user.token, { cursors: {} });
  assert.equal(pull1.status, 200);
  const slice1 = getScopeSlice(pull1.data, user.scope);
  assert.equal(slice1.rows.length, 2);
  const taskRow1 = slice1.rows.find((r) => r.entity === 'task' && r.row?.id === taskId);
  assert(taskRow1);
  const seq1 = slice1.cursor;

  const replay = await postJson(baseUrl, '/sync/push', { deviceId: user.deviceId, ops: [op] }, user.token);
  assert.equal(replay.status, 200);
  assert.equal(replay.data.results[0].status, 'applied');
  assert.equal(replay.data.results[0].row.title, 'Once Only');

  const pullAfterReplay = await pullSync(baseUrl, user.token, {
    cursors: { [user.scope]: seq1 },
  });
  assert.equal(pullAfterReplay.status, 200);
  const sliceAfterReplay = getScopeSlice(pullAfterReplay.data, user.scope);
  assert.equal(sliceAfterReplay.rows.length, 0, 'Replay must not increment serverSeq');
  assert.equal(sliceAfterReplay.cursor, seq1);

  const fullPull = await pullSync(baseUrl, user.token, { cursors: {} });
  assert.equal(fullPull.status, 200);
  const fullSlice = getScopeSlice(fullPull.data, user.scope);
  assert.equal(fullSlice.rows.length, 2);
  const fullTask = fullSlice.rows.find((r) => r.entity === 'task' && r.row?.id === taskId);
  assert.equal(fullTask.serverSeq, taskRow1.serverSeq);
}

async function runPagingScenario({ baseUrl, jwks }) {
  const user = await createUserToken(baseUrl, jwks);
  const projectId = randomUUID();
  const now = Date.now();
  const taskCount = 64;
  const totalRows = taskCount + 1; // 1 project + 64 tasks = 65 rows

  const ops = [
    makeProjectOp({ hlc: makeHlc(now, 0, user.deviceId), projectId, ownerId: user.userId, now }),
    ...Array.from({ length: taskCount }, (_, i) => {
      const id = randomUUID();
      return fullTaskCreateOp({
        hlc: makeHlc(now, i + 1, user.deviceId),
        taskId: id,
        projectId,
        title: `Task ${i}`,
        now,
      });
    }),
  ];

  const push = await postJson(baseUrl, '/sync/push', { deviceId: user.deviceId, ops }, user.token);
  assert.equal(push.status, 200);
  assert.equal(push.data.results.length, totalRows);

  let cursor = 0;
  let hasMore = true;
  const receivedIds = [];
  let pages = 0;

  while (hasMore) {
    pages += 1;
    const pull = await pullSync(baseUrl, user.token, {
      cursors: { [user.scope]: cursor },
      limit: 7,
    });
    assert.equal(pull.status, 200);
    const slice = getScopeSlice(pull.data, user.scope);
    assert(slice.rows.length <= 7);
    if (slice.rows.length > 0) {
      assert.equal(slice.cursor, slice.rows[slice.rows.length - 1].serverSeq);
      assert(slice.cursor > cursor);
    }
    for (const r of slice.rows) {
      receivedIds.push(r.row.id);
    }
    cursor = slice.cursor;
    hasMore = slice.hasMore;
    assert(pages < 30, 'Too many pages; possible infinite loop');
  }

  assert.equal(receivedIds.length, totalRows, 'Must receive every row across paged pulls');
  assert.equal(new Set(receivedIds).size, totalRows, 'Must receive every row exactly once');
}

async function runAuthScenario({ baseUrl, jwks }) {
  // 1. Unauthenticated push / pull -> 401
  const unauthPush = await postJson(baseUrl, '/sync/push', { deviceId: 'd1', ops: [] });
  assert.equal(unauthPush.status, 401);

  const unauthPull = await pullSync(baseUrl, undefined, { cursors: {} });
  assert.equal(unauthPull.status, 401);

  const badAuthPull = await pullSync(baseUrl, 'not-a-valid-jwt', { cursors: {} });
  assert.equal(badAuthPull.status, 401);

  // 2. User A creates a project + task; User B cannot overwrite or pull it
  const userA = await createUserToken(baseUrl, jwks);
  const userB = await createUserToken(baseUrl, jwks);
  const taskId = randomUUID();
  const projectId = randomUUID();
  const now = Date.now();

  const userAOpId = randomUUID();
  const pushA = await postJson(
    baseUrl,
    '/sync/push',
    {
      deviceId: userA.deviceId,
      ops: [
        makeProjectOp({
          hlc: makeHlc(now, 0, userA.deviceId),
          projectId,
          ownerId: userA.userId,
          now,
        }),
        fullTaskCreateOp({
          opId: userAOpId,
          hlc: makeHlc(now, 1, userA.deviceId),
          taskId,
          projectId,
          title: 'User A Secret',
          now,
        }),
      ],
    },
    userA.token,
  );
  assert.equal(pushA.status, 200);
  assert.equal(pushA.data.results[0].status, 'applied');
  assert.equal(pushA.data.results[1].status, 'applied');

  // User A pushes a validation-failing op on their own existing row -> rejected with current row & clocks.
  const userABadOp = makeTaskOp({
    hlc: makeHlc(now + 500, 0, userA.deviceId),
    entityId: taskId,
    fields: ['title'],
    row: { id: taskId, title: null },
  });
  const pushABad = await postJson(
    baseUrl,
    '/sync/push',
    { deviceId: userA.deviceId, ops: [userABadOp] },
    userA.token,
  );
  assert.equal(pushABad.status, 200);
  assert.equal(pushABad.data.results[0].status, 'rejected');
  assert.deepEqual(pushABad.data.results[0].row, pushA.data.results[1].row);
  assert.deepEqual(pushABad.data.results[0].clocks, pushA.data.results[1].clocks);

  const replayABad = await postJson(
    baseUrl,
    '/sync/push',
    { deviceId: userA.deviceId, ops: [userABadOp] },
    userA.token,
  );
  assert.equal(replayABad.status, 200);
  assert.equal(replayABad.data.results[0].status, 'rejected');
  assert.equal(replayABad.data.results[0].reason, pushABad.data.results[0].reason);
  assert.deepEqual(replayABad.data.results[0].row, pushA.data.results[1].row);
  assert.deepEqual(replayABad.data.results[0].clocks, pushA.data.results[1].clocks);

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
  assert.deepEqual(pushB.data.results[0].clocks, {});
  assert.equal(pushB.data.results[0].gone, true);

  // Cross-user validation-failing op or opId collision must still return row: null, clocks: {}
  const pushBCrossBad = await postJson(
    baseUrl,
    '/sync/push',
    {
      deviceId: userB.deviceId,
      ops: [
        makeTaskOp({
          hlc: makeHlc(now + 1001, 0, userB.deviceId),
          entityId: taskId,
          fields: ['title'],
          row: { id: taskId, title: null },
        }),
        makeTaskOp({
          opId: userAOpId,
          hlc: makeHlc(now + 1002, 0, userB.deviceId),
          entityId: taskId,
          fields: ['title'],
          row: { id: taskId, title: 'Probe' },
        }),
      ],
    },
    userB.token,
  );
  assert.equal(pushBCrossBad.status, 200);
  assert.equal(pushBCrossBad.data.results[0].status, 'rejected');
  assert.equal(pushBCrossBad.data.results[0].row, null);
  assert.deepEqual(pushBCrossBad.data.results[0].clocks, {});
  assert.equal(pushBCrossBad.data.results[0].gone, true);
  assert.equal(pushBCrossBad.data.results[1].status, 'rejected');
  assert.equal(pushBCrossBad.data.results[1].row, null);
  assert.deepEqual(pushBCrossBad.data.results[1].clocks, {});

  const pullB = await pullSync(baseUrl, userB.token, { cursors: {} });
  assert.equal(pullB.status, 200);
  assert.equal(pullB.data.memberships.length, 0);
  for (const s of pullB.data.scopes) {
    assert.equal(
      s.rows.some((r) => r.row?.id === taskId || r.row?.id === projectId),
      false,
      'User B must not see User A rows in pull',
    );
  }

  const pullA = await pullSync(baseUrl, userA.token, { cursors: {} });
  assert.equal(pullA.status, 200);
  const sliceA = getScopeSlice(pullA.data, userA.scope);
  const rowA = sliceA.rows.find((r) => r.row?.id === taskId);
  assert(rowA);
  assert.equal(rowA.row.title, 'User A Secret');
}

async function runIdRaceScenario({ baseUrl, jwks }) {
  const userA = await createUserToken(baseUrl, jwks);
  const userB = await createUserToken(baseUrl, jwks);
  const projectA = randomUUID();
  const projectB = randomUUID();
  const sharedTaskId = randomUUID();
  const now = Date.now();

  const initA = await postJson(
    baseUrl,
    '/sync/push',
    {
      deviceId: userA.deviceId,
      ops: [makeProjectOp({ hlc: makeHlc(now, 0, userA.deviceId), projectId: projectA, ownerId: userA.userId, now })],
    },
    userA.token,
  );
  const initB = await postJson(
    baseUrl,
    '/sync/push',
    {
      deviceId: userB.deviceId,
      ops: [makeProjectOp({ hlc: makeHlc(now, 0, userB.deviceId), projectId: projectB, ownerId: userB.userId, now })],
    },
    userB.token,
  );
  assert.equal(initA.status, 200);
  assert.equal(initB.status, 200);

  const [resA, resB] = await Promise.all([
    postJson(
      baseUrl,
      '/sync/push',
      {
        deviceId: userA.deviceId,
        ops: [
          fullTaskCreateOp({
            hlc: makeHlc(now + 10, 0, userA.deviceId),
            taskId: sharedTaskId,
            projectId: projectA,
            title: 'From A',
            now,
          }),
        ],
      },
      userA.token,
    ),
    postJson(
      baseUrl,
      '/sync/push',
      {
        deviceId: userB.deviceId,
        ops: [
          fullTaskCreateOp({
            hlc: makeHlc(now + 10, 0, userB.deviceId),
            taskId: sharedTaskId,
            projectId: projectB,
            title: 'From B',
            now,
          }),
        ],
      },
      userB.token,
    ),
  ]);

  assert.equal(resA.status, 200);
  assert.equal(resB.status, 200);
  const rA = resA.data.results[0];
  const rB = resB.data.results[0];
  const appliedCount = [rA, rB].filter((r) => r.status === 'applied').length;
  const rejectedCount = [rA, rB].filter((r) => r.status === 'rejected').length;
  assert.equal(appliedCount, 1, `Expected 1 winner, got ${JSON.stringify([rA, rB])}`);
  assert.equal(rejectedCount, 1, `Expected 1 loser, got ${JSON.stringify([rA, rB])}`);

  const winner = rA.status === 'applied' ? userA : userB;
  const loser = rA.status === 'applied' ? userB : userA;
  const loserResult = rA.status === 'applied' ? rB : rA;
  assert.equal(loserResult.reason, 'id-in-other-scope');
  assert.equal(loserResult.row, null);

  const pullWinner = await pullSync(baseUrl, winner.token, { cursors: {} });
  const pullLoser = await pullSync(baseUrl, loser.token, { cursors: {} });
  const winnerRows = getScopeSlice(pullWinner.data, winner.scope).rows;
  const loserRows = getScopeSlice(pullLoser.data, loser.scope).rows;
  assert(winnerRows.some((r) => r.row?.id === sharedTaskId), 'Winner must see task in pull');
  assert.equal(
    loserRows.some((r) => r.row?.id === sharedTaskId),
    false,
    'Loser must not see task in pull',
  );
}

async function runUnknownRowScenario({ baseUrl, jwks }) {
  const user = await createUserToken(baseUrl, jwks);
  const projectId = randomUUID();
  const unknownTaskId = randomUUID();
  const now = Date.now();

  const init = await postJson(
    baseUrl,
    '/sync/push',
    {
      deviceId: user.deviceId,
      ops: [makeProjectOp({ hlc: makeHlc(now, 0, user.deviceId), projectId, ownerId: user.userId, now })],
    },
    user.token,
  );
  assert.equal(init.status, 200);
  const pull1 = await pullSync(baseUrl, user.token, { cursors: {} });
  const seqBefore = getScopeSlice(pull1.data, user.scope).cursor;

  const partialRes = await postJson(
    baseUrl,
    '/sync/push',
    {
      deviceId: user.deviceId,
      ops: [
        makeTaskOp({
          hlc: makeHlc(now + 10, 0, user.deviceId),
          entityId: unknownTaskId,
          fields: ['title', 'updatedAt'],
          row: { id: unknownTaskId, title: 'Ghost Task', updatedAt: now + 10 },
        }),
      ],
    },
    user.token,
  );
  assert.equal(partialRes.status, 200);
  assert.equal(partialRes.data.results[0].status, 'rejected');
  assert.equal(partialRes.data.results[0].reason, 'unknown-row');
  assert.equal(partialRes.data.results[0].row, null);

  const pullAfter = await pullSync(baseUrl, user.token, {
    cursors: { [user.scope]: seqBefore },
  });
  const sliceAfter = getScopeSlice(pullAfter.data, user.scope);
  assert.equal(sliceAfter.rows.length, 0);
  assert.equal(sliceAfter.cursor, seqBefore);

  const fullPull = await pullSync(baseUrl, user.token, { cursors: {} });
  const fullSlice = getScopeSlice(fullPull.data, user.scope);
  assert.equal(fullSlice.rows.some((r) => r.row?.id === unknownTaskId), false);
}

async function runMoveTaskScenario({ baseUrl, jwks }) {
  const user = await createUserToken(baseUrl, jwks);
  const project1 = randomUUID();
  const project2 = randomUUID();
  const taskId = randomUUID();
  const itemId = randomUUID();
  const attId = randomUUID();
  const commentId = randomUUID();
  const now = Date.now();

  const init = await postJson(
    baseUrl,
    '/sync/push',
    {
      deviceId: user.deviceId,
      ops: [
        makeProjectOp({ hlc: makeHlc(now, 0, user.deviceId), projectId: project1, ownerId: user.userId, name: 'List 1', now }),
        makeProjectOp({ hlc: makeHlc(now, 1, user.deviceId), projectId: project2, ownerId: user.userId, name: 'List 2', now }),
        fullTaskCreateOp({ hlc: makeHlc(now, 2, user.deviceId), taskId, projectId: project1, title: 'Movable', now }),
        {
          opId: randomUUID(),
          hlc: makeHlc(now, 3, user.deviceId),
          entity: 'checklistItem',
          entityId: itemId,
          op: 'upsert',
          fields: ['id', 'taskId', 'title', 'status', 'sortKey', 'createdAt', 'updatedAt'],
          row: {
            id: itemId,
            taskId,
            title: 'Subitem',
            status: 0,
            sortKey: 'i',
            createdAt: now,
            updatedAt: now,
          },
        },
        {
          opId: randomUUID(),
          hlc: makeHlc(now, 4, user.deviceId),
          entity: 'attachment',
          entityId: attId,
          op: 'upsert',
          fields: ['id', 'taskId', 'fileName', 'size', 'mimeType', 'createdAt', 'updatedAt'],
          row: {
            id: attId,
            taskId,
            fileName: 'doc.pdf',
            size: 1024,
            mimeType: 'application/pdf',
            createdAt: now,
            updatedAt: now,
          },
        },
        {
          opId: randomUUID(),
          hlc: makeHlc(now, 5, user.deviceId),
          entity: 'comment',
          entityId: commentId,
          op: 'upsert',
          fields: ['id', 'taskId', 'authorId', 'body', 'createdAt', 'updatedAt'],
          row: {
            id: commentId,
            taskId,
            authorId: user.userId,
            body: 'Note',
            createdAt: now,
            updatedAt: now,
          },
        },
      ],
    },
    user.token,
  );
  assert.equal(init.status, 200);
  for (const r of init.data.results) {
    assert.equal(r.status, 'applied', `Unexpected reject on setup: ${JSON.stringify(r)}`);
  }

  const beforePull = await pullSync(baseUrl, user.token, { cursors: {} });
  const beforeSlice = getScopeSlice(beforePull.data, user.scope);
  const cursorBeforeMove = beforeSlice.cursor;

  const moveRes = await postJson(
    baseUrl,
    '/sync/push',
    {
      deviceId: user.deviceId,
      ops: [
        makeTaskOp({
          hlc: makeHlc(now + 100, 0, user.deviceId),
          entityId: taskId,
          fields: ['projectId', 'updatedAt'],
          row: { id: taskId, projectId: project2, updatedAt: now + 100 },
        }),
      ],
    },
    user.token,
  );
  assert.equal(moveRes.status, 200);
  assert.equal(moveRes.data.results[0].status, 'applied');
  assert.equal(moveRes.data.results[0].row.projectId, project2);

  const afterPull = await pullSync(baseUrl, user.token, {
    cursors: { [user.scope]: cursorBeforeMove },
  });
  assert.equal(afterPull.status, 200);
  const afterSlice = getScopeSlice(afterPull.data, user.scope);
  const pulledIds = new Set(afterSlice.rows.map((r) => r.row?.id));
  assert.equal(afterSlice.rows.length, 4, `Expected task + 3 children, got ${afterSlice.rows.length}`);
  for (const id of [taskId, itemId, attId, commentId]) {
    assert(pulledIds.has(id), `Expected ${id} in incremental pull after move`);
  }
  for (const r of afterSlice.rows) {
    assert(r.serverSeq > cursorBeforeMove, `Expected serverSeq > ${cursorBeforeMove}`);
  }
  const movedTask = afterSlice.rows.find((r) => r.row?.id === taskId);
  assert.equal(movedTask.row.projectId, project2);
}

async function runChildTaskIdScenario({ baseUrl, jwks }) {
  const user = await createUserToken(baseUrl, jwks);
  const projectId = randomUUID();
  const task1 = randomUUID();
  const task2 = randomUUID();
  const itemId = randomUUID();
  const now = Date.now();

  const setup = await postJson(
    baseUrl,
    '/sync/push',
    {
      deviceId: user.deviceId,
      ops: [
        makeProjectOp({ hlc: makeHlc(now, 0, user.deviceId), projectId, ownerId: user.userId, now }),
        fullTaskCreateOp({ hlc: makeHlc(now, 1, user.deviceId), taskId: task1, projectId, title: 'Task 1', now }),
        fullTaskCreateOp({ hlc: makeHlc(now, 2, user.deviceId), taskId: task2, projectId, title: 'Task 2', now }),
        {
          opId: randomUUID(),
          hlc: makeHlc(now, 3, user.deviceId),
          entity: 'checklistItem',
          entityId: itemId,
          op: 'upsert',
          fields: ['id', 'taskId', 'title', 'status', 'sortKey', 'createdAt', 'updatedAt'],
          row: {
            id: itemId,
            taskId: task1,
            title: 'Item',
            status: 0,
            sortKey: 'i',
            createdAt: now,
            updatedAt: now,
          },
        },
      ],
    },
    user.token,
  );
  assert.equal(setup.status, 200);
  for (const r of setup.data.results) {
    assert.equal(r.status, 'applied');
  }

  const moveChild = await postJson(
    baseUrl,
    '/sync/push',
    {
      deviceId: user.deviceId,
      ops: [
        {
          opId: randomUUID(),
          hlc: makeHlc(now + 100, 0, user.deviceId),
          entity: 'checklistItem',
          entityId: itemId,
          op: 'upsert',
          fields: ['taskId', 'updatedAt'],
          row: { id: itemId, taskId: task2, updatedAt: now + 100 },
        },
      ],
    },
    user.token,
  );
  assert.equal(moveChild.status, 200);
  assert.equal(moveChild.data.results[0].status, 'rejected');
  assert.equal(moveChild.data.results[0].row?.id, itemId);
  assert.equal(moveChild.data.results[0].row?.taskId, task1);
  assert.equal(typeof moveChild.data.results[0].clocks.taskId, 'string');

  const pull = await pullSync(baseUrl, user.token, { cursors: {} });
  const itemRow = getScopeSlice(pull.data, user.scope).rows.find((r) => r.row?.id === itemId);
  assert(itemRow);
  assert.equal(itemRow.row.taskId, task1);
}

const SCENARIOS = {
  fixture: runFixtureScenario,
  lww: runLwwScenario,
  concurrency: runConcurrencyScenario,
  replay: runReplayScenario,
  paging: runPagingScenario,
  auth: runAuthScenario,
  id_race: runIdRaceScenario,
  unknown_row: runUnknownRowScenario,
  move_task: runMoveTaskScenario,
  child_task_id: runChildTaskIdScenario,
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
