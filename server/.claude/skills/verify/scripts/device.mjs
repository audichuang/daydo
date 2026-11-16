#!/usr/bin/env node
// Acts as a DayDo device against DAYDO_API (default https://daydo-api.audichuang.app).
//   node device.mjs login            email start → code (Gmail or dev mail) → verify; saves session
//   node device.mjs bootstrap        first-login data like the App: me member + inbox (skips if present)
//   node device.mjs seed [--n 60]    project "verify-seed" with N tasks; skipped if it already exists
//   node device.mjs pull [--label x] summary of verify-seed (+ evidence pull-<label>.json)
//   node device.mjs find --title <t> [--status 0|2]   exit 0 only if the task exists (with that status)
//   node device.mjs delete-probes    soft-deletes live "verify-probe*" tasks in verify-seed
//   node device.mjs status           session summary without tokens
// Session (tokens, deviceId) lives in <stateDir>/session.<host>.json (0600); evidence in the run dir.
import fs from 'node:fs';
import { getCode } from './mail-code.mjs';
import {
  apiRequest,
  cfg,
  die,
  evidence,
  hlc,
  parseArgs,
  readJson,
  saveEvidence,
  sessionFile,
  uuidv7,
  writeJson,
} from './lib.mjs';

// ---------------------------------------------------------------------------
// Session

function loadSession() {
  const s = readJson(sessionFile());
  if (!s?.refreshToken) die(`no device session for ${cfg.api}; run: node device.mjs login`, 2);
  return s;
}

function saveSession(s) {
  writeJson(sessionFile(), s);
}

async function refresh(s) {
  const res = await apiRequest('POST', '/auth/refresh', { refreshToken: s.refreshToken });
  if (res.status !== 200) die(`refresh failed: ${res.status} ${JSON.stringify(res.data)} (run login again)`, 2);
  Object.assign(s, {
    accessToken: res.data.accessToken,
    refreshToken: res.data.refreshToken,
    accessIssuedAt: Date.now(),
    hasData: res.data.hasData,
    meMemberId: res.data.meMemberId,
    inboxProjectId: res.data.inboxProjectId,
  });
  // Refresh tokens rotate: persist before anything else can fail.
  saveSession(s);
}

/** Authenticated call; refreshes once on 401 or when the 1 h access token is near expiry. */
async function call(s, route, body) {
  if (!s.accessToken || Date.now() - (s.accessIssuedAt ?? 0) > 50 * 60_000) await refresh(s);
  let res = await apiRequest('POST', route, body, s.accessToken);
  if (res.status === 401) {
    await refresh(s);
    res = await apiRequest('POST', route, body, s.accessToken);
  }
  return res;
}

async function login() {
  const prev = readJson(sessionFile(), {});
  const deviceId = prev.deviceId ?? uuidv7();
  const since = Date.now();
  const start = await apiRequest('POST', '/auth/email/start', { email: cfg.email, deviceId });
  evidence('device.log', { step: 'email/start', status: start.status, body: start.data });
  if (start.status !== 202) die(`email start: ${start.status} ${JSON.stringify(start.data)}`);
  const code = await getCode({ email: cfg.email, since });
  const res = await apiRequest('POST', '/auth/email/verify', { email: cfg.email, code, deviceId });
  if (res.status !== 200) die(`email verify: ${res.status} ${JSON.stringify(res.data)}`);
  const d = res.data;
  const s = {
    email: cfg.email,
    api: cfg.api,
    deviceId,
    userId: d.user.id,
    accessToken: d.accessToken,
    refreshToken: d.refreshToken,
    accessIssuedAt: Date.now(),
    isNewAccount: d.isNewAccount,
    hasData: d.hasData,
    meMemberId: d.meMemberId,
    inboxProjectId: d.inboxProjectId,
  };
  saveSession(s);
  const summary = { step: 'email/verify', status: 200, userId: s.userId, isNewAccount: d.isNewAccount, hasData: d.hasData, meMemberId: d.meMemberId, inboxProjectId: d.inboxProjectId };
  evidence('device.log', summary);
  console.log(JSON.stringify(summary));
}

// ---------------------------------------------------------------------------
// Sync

let counter = 0;
function nextHlc(s, minMs = 0) {
  return hlc(Math.max(Date.now(), minMs), counter++ % 10000, s.deviceId);
}

async function push(s, ops, { allowRejected = () => false } = {}) {
  const results = [];
  for (let i = 0; i < ops.length; i += 50) {
    const batch = ops.slice(i, i + 50);
    const res = await call(s, '/sync/push', { deviceId: s.deviceId, ops: batch });
    if (res.status !== 200) die(`push: ${res.status} ${JSON.stringify(res.data)}`);
    res.data.results.forEach((r, j) => {
      if (r.status !== 'applied' && !allowRejected(batch[j], r)) die(`op not applied: ${batch[j].entity} ${JSON.stringify(r)}`);
      results.push({ op: batch[j], result: r });
    });
  }
  return results;
}

/** Every visible row (all scopes, all pages), latest per entity id. */
async function pullAll(s) {
  const cursors = {};
  const rows = new Map();
  let memberships = [];
  for (let page = 0; page < 100; page += 1) {
    const res = await call(s, '/sync/pull', { cursors, limit: 1000 });
    if (res.status !== 200) die(`pull: ${res.status} ${JSON.stringify(res.data)}`);
    memberships = res.data.memberships;
    let more = false;
    for (const scope of res.data.scopes) {
      for (const r of scope.rows) {
        const id = r.gone ? r.entityId : (r.row.id ?? r.row.name ?? `${r.row.projectId}:${r.row.memberId}`);
        rows.set(`${r.entity}/${id}`, r);
      }
      cursors[scope.scope] = scope.cursor;
      more ||= scope.hasMore;
    }
    if (!more) return { rows: [...rows.values()], memberships };
  }
  die('pull did not finish within 100 pages');
}

const absent = (row, ...f) => f.every((k) => row[k] === undefined || row[k] === null);

/** Mirrors the MCP snapshot rules (liveProjects / liveTasks / open = status 0). */
function view(pulled) {
  const live = (e) => pulled.rows.filter((r) => !r.gone && r.entity === e).map((r) => ({ ...r.row, _clocks: r.clocks }));
  const projects = live('project').filter((p) => absent(p, 'deletedAt', 'purgedAt', 'archivedAt'));
  const seed = projects.find((p) => p.name === cfg.seedProject) ?? null;
  const inbox = projects.find((p) => p.isInbox === true) ?? null;
  const allTasks = live('task').filter((t) => seed && t.projectId === seed.id);
  const liveTasks = allTasks.filter((t) => absent(t, 'deletedAt', 'purgedAt'));
  const items = live('checklistItem').filter((c) => liveTasks.some((t) => t.id === c.taskId) && absent(c, 'deletedAt', 'purgedAt'));
  return {
    seed,
    inbox,
    liveTasks,
    summary: {
      projectId: seed?.id ?? null,
      inboxProjectId: inbox?.id ?? null,
      projects: projects.map((p) => p.name),
      tasks: liveTasks.length,
      active: liveTasks.filter((t) => Number(t.status ?? 0) === 0).length,
      completed: liveTasks.filter((t) => Number(t.status) === 2).length,
      deleted: allTasks.length - liveTasks.length,
      repeating: liveTasks.filter((t) => t.repeatRule).length,
      allDay: liveTasks.filter((t) => t.startDay && absent(t, 'startMinute')).length,
      timed: liveTasks.filter((t) => !absent(t, 'startMinute')).length,
      checklistItems: items.length,
      probes: liveTasks.filter((t) => String(t.title).startsWith(cfg.probePrefix)).map((t) => ({ id: t.id, title: t.title, status: t.status })),
    },
  };
}

function stripClocks(row) {
  const { _clocks, ...rest } = row;
  return rest;
}

function op(s, entity, row, { fields, minMs } = {}) {
  return {
    opId: uuidv7(),
    hlc: nextHlc(s, minMs),
    entity,
    entityId: row.id,
    op: 'upsert',
    fields: fields ?? Object.keys(row),
    row,
  };
}

async function bootstrap() {
  const s = loadSession();
  const v = view(await pullAll(s));
  const now = Date.now();
  const ops = [];
  let memberId = s.meMemberId;
  if (!memberId) {
    memberId = uuidv7();
    const name = s.email.split('@')[0].slice(0, 30);
    ops.push(op(s, 'member', { id: memberId, name, initial: name.slice(0, 1).toUpperCase(), color: '#9BB8FF', isMe: true, createdAt: now, updatedAt: now }));
  }
  let inboxId = v.inbox?.id ?? null;
  if (!inboxId) {
    inboxId = uuidv7();
    // Same shape as the App's bootstrap inbox (spec/fixtures/sync-ops.json).
    ops.push(op(s, 'project', { id: inboxId, name: '收件匣', icon: 'inbox', viewMode: 'list', kind: 'TASK', isInbox: true, ownerId: memberId, sortKey: 'i', showInSmart: 'all', notifyMode: 'all', createdAt: now, updatedAt: now }));
  }
  if (ops.length) await push(s, ops);
  await refresh(s); // re-reads meMemberId / inboxProjectId / hasData from the server
  const summary = { step: 'bootstrap', pushed: ops.map((o) => o.entity), hasData: s.hasData, meMemberId: s.meMemberId, inboxProjectId: s.inboxProjectId };
  evidence('device.log', summary);
  if (!s.hasData || !s.meMemberId) die(`bootstrap incomplete: ${JSON.stringify(summary)}`);
  console.log(JSON.stringify(summary));
}

// ---------------------------------------------------------------------------
// Seed

function taipeiToday() {
  return new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Taipei' }).format(new Date());
}

function addDays(day, n) {
  const d = new Date(`${day}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() + n);
  return d.toISOString().slice(0, 10);
}

/** N ascending fractional keys that never end in "0" (spec/mcp.md 7 sortKey rule). */
function sortKeys(n) {
  const keys = [];
  for (let i = 1; keys.length < n; i += 1) {
    const k = `i${i.toString(36).padStart(3, '0')}`;
    if (!k.endsWith('0')) keys.push(k);
  }
  return keys;
}

const TASK_FIELDS = ['id', 'projectId', 'title', 'content', 'priority', 'status', 'startDay', 'startMinute', 'endDay', 'endMinute', 'timeZone', 'reminders', 'repeatRule', 'tags', 'sortKey', 'completedAt', 'createdAt', 'updatedAt'];

function seedTasks(s, projectId, n) {
  const now = Date.now();
  const today = taipeiToday();
  const keys = sortKeys(n);
  const ops = [];
  const counts = { tasks: 0, active: 0, completed: 0, repeating: 0, allDay: 0, timed: 0, checklistItems: 0 };
  for (let i = 0; i < n; i += 1) {
    const day = addDays(today, i % 30);
    const repeat = i % 15 === 3 ? 'RRULE:FREQ=WEEKLY' : i % 20 === 7 ? 'RRULE:FREQ=DAILY' : null;
    const completed = i % 10 === 9; // never overlaps the repeating indexes
    const allDay = i % 6 < 2;
    const row = {
      id: uuidv7(),
      projectId,
      title: `${cfg.seedProject} #${String(i + 1).padStart(3, '0')}`,
      content: `seeded by verify (${i % 6 < 2 ? 'all-day' : 'timed'})`,
      priority: [0, 1, 3, 5][i % 4],
      status: completed ? 2 : 0,
      startDay: day,
      reminders: [],
      tags: [],
      sortKey: keys[i],
      createdAt: now,
      updatedAt: now,
    };
    if (allDay) {
      // All-day: date only, floating (no timeZone), like the App.
    } else {
      row.startMinute = 9 * 60 + (i % 9) * 60;
      row.timeZone = 'Asia/Taipei';
      if (i % 6 !== 5) {
        row.endDay = day;
        row.endMinute = row.startMinute + 30;
      }
      if (i % 4 === 2) row.reminders = ['TRIGGER:-PT15M'];
    }
    if (repeat) row.repeatRule = repeat;
    if (completed) row.completedAt = now;
    ops.push(op(s, 'task', row, { fields: TASK_FIELDS }));
    counts.tasks += 1;
    counts[completed ? 'completed' : 'active'] += 1;
    if (repeat) counts.repeating += 1;
    counts[allDay ? 'allDay' : 'timed'] += 1;
    if (i % 7 === 2) {
      ['步驟一', '步驟二', '步驟三'].forEach((title, j) => {
        ops.push(op(s, 'checklistItem', { id: uuidv7(), taskId: row.id, title, status: j === 0 ? 1 : 0, sortKey: ['i', 'r', 'v'][j], createdAt: now, updatedAt: now }));
        counts.checklistItems += 1;
      });
    }
  }
  return { ops, counts };
}

async function seed(n) {
  const s = loadSession();
  if (!s.meMemberId) die('no me member yet; run: node device.mjs bootstrap', 2);
  const before = view(await pullAll(s));
  if (before.seed) {
    const out = { step: 'seed', skipped: true, reason: `${cfg.seedProject} exists`, ...before.summary };
    evidence('device.log', out);
    saveEvidence('seed.json', out);
    console.log(JSON.stringify(out));
    return;
  }
  const now = Date.now();
  const projectId = uuidv7();
  const suffix = Math.random().toString(36).slice(2, 3) + '123456789abcdefghijklmnopqrstuvwxyz'[Math.floor(Math.random() * 35)];
  const project = { id: projectId, name: cfg.seedProject, color: '#5BB98C', viewMode: 'list', kind: 'TASK', isInbox: false, ownerId: s.meMemberId, sortKey: `z${suffix}`, showInSmart: 'all', notifyMode: 'all', createdAt: now, updatedAt: now };
  const { ops, counts } = seedTasks(s, projectId, n);
  await push(s, [op(s, 'project', project), ...ops]);
  const after = view(await pullAll(s));
  const out = { step: 'seed', skipped: false, requested: n, pushed: counts, pulled: after.summary };
  evidence('device.log', { step: 'seed', pushedOps: ops.length + 1 });
  saveEvidence('seed.json', out);
  if (after.summary.active !== counts.active || after.summary.tasks !== counts.tasks) die(`seed mismatch: ${JSON.stringify(out)}`);
  console.log(JSON.stringify(out));
}

// ---------------------------------------------------------------------------
// Read-back and cleanup

async function pullSummary(label) {
  const s = loadSession();
  const v = view(await pullAll(s));
  saveEvidence(`pull-${label}.json`, v.summary);
  console.log(JSON.stringify(v.summary));
}

async function find(title, status) {
  const s = loadSession();
  const v = view(await pullAll(s));
  const t = v.liveTasks.find((x) => x.title === title);
  const out = t
    ? { found: true, id: t.id, title: t.title, projectId: t.projectId, status: t.status, completedAt: t.completedAt ?? null, updatedAt: t.updatedAt }
    : { found: false, title };
  evidence('device.log', { step: 'find', ...out });
  console.log(JSON.stringify(out));
  if (!t) process.exit(1);
  if (status !== undefined && Number(t.status) !== Number(status)) die(`status ${t.status}, expected ${status}`);
  if (Number(status) === 2 && !t.completedAt) die('status 2 without completedAt');
}

async function deleteProbes() {
  const s = loadSession();
  const v = view(await pullAll(s));
  const probes = v.liveTasks.filter((t) => String(t.title).startsWith(cfg.probePrefix));
  if (!probes.length) {
    console.log(JSON.stringify({ step: 'delete-probes', deleted: 0 }));
    return;
  }
  const now = Date.now();
  const ops = probes.map((t) => {
    // Win LWW: the HLC must be newer than every clock on the row (MCP writes use server clocks).
    const maxMs = Math.max(0, ...Object.values(t._clocks ?? {}).map((c) => Number(String(c).slice(0, 13))));
    const row = { ...stripClocks(t), deletedAt: now, updatedAt: Math.max(now, Number(t.updatedAt ?? 0) + 1) };
    return op(s, 'task', row, { fields: ['deletedAt', 'updatedAt'], minMs: maxMs + 1 });
  });
  const results = await push(s, ops);
  const notApplied = results.filter((r) => !r.result.row?.deletedAt).map((r) => r.op.entityId);
  const out = { step: 'delete-probes', deleted: results.length - notApplied.length, notApplied };
  evidence('device.log', out);
  console.log(JSON.stringify(out));
  if (notApplied.length) process.exit(1);
}

function status() {
  const s = readJson(sessionFile());
  if (!s) {
    console.log(JSON.stringify({ session: false, file: sessionFile() }));
    return;
  }
  console.log(JSON.stringify({ session: true, file: sessionFile(), api: s.api, email: s.email, userId: s.userId, deviceId: s.deviceId, hasData: s.hasData, meMemberId: s.meMemberId, inboxProjectId: s.inboxProjectId }));
}

const a = parseArgs(process.argv.slice(2));
const cmd = a._[0];
try {
  if (cmd === 'login') await login();
  else if (cmd === 'bootstrap') await bootstrap();
  else if (cmd === 'seed') await seed(Number(a.n ?? 60));
  else if (cmd === 'pull') await pullSummary(a.label ?? 'latest');
  else if (cmd === 'find') await find(a.title ?? die('--title required', 2), a.status);
  else if (cmd === 'delete-probes') await deleteProbes();
  else if (cmd === 'status') status();
  else if (cmd === 'forget') {
    fs.rmSync(sessionFile(), { force: true });
    console.log(JSON.stringify({ forgot: sessionFile() }));
  } else die('usage: device.mjs login|bootstrap|seed [--n N]|pull [--label L]|find --title T [--status S]|delete-probes|status|forget', 2);
} catch (e) {
  die(e.stack ?? String(e));
}
