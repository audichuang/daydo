// Read-only latency probe against production: times App-style POST /sync/pull for one user.
// Usage: JWT_SECRET=... CF_ACCESS_CLIENT_ID=... CF_ACCESS_CLIENT_SECRET=... node scripts/measure-latency.mjs <userId> [rounds]
// It signs a 10-minute App access token for <userId> and only ever pulls; it never pushes.
import { SignJWT } from 'jose';

const baseUrl = (process.env.BASE_URL ?? 'https://api.daydoapp.com').replace(/\/+$/, '');
const [userId, roundsArg = '25'] = process.argv.slice(2);
const { JWT_SECRET, CF_ACCESS_CLIENT_ID, CF_ACCESS_CLIENT_SECRET } = process.env;
if (!userId || !JWT_SECRET || !CF_ACCESS_CLIENT_ID || !CF_ACCESS_CLIENT_SECRET) {
  console.error('Usage: JWT_SECRET, CF_ACCESS_CLIENT_ID, CF_ACCESS_CLIENT_SECRET in env; node scripts/measure-latency.mjs <userId> [rounds]');
  process.exit(1);
}

const token = await new SignJWT({})
  .setProtectedHeader({ alg: 'HS256' })
  .setSubject(userId)
  .setIssuedAt()
  .setExpirationTime('10m')
  .sign(new TextEncoder().encode(JWT_SECRET));
const access = { 'CF-Access-Client-Id': CF_ACCESS_CLIENT_ID, 'CF-Access-Client-Secret': CF_ACCESS_CLIENT_SECRET };
const headers = { ...access, authorization: `Bearer ${token}`, 'content-type': 'application/json' };
// A backfill of a project the user cannot see runs the same D1 queries as a pull but calls no Scope.
const NO_SCOPE_BACKFILL = ['00000000-0000-7000-8000-000000000000'];

async function pull(body) {
  const started = performance.now();
  const res = await fetch(`${baseUrl}/sync/pull`, { method: 'POST', headers, body: JSON.stringify(body) });
  const text = await res.text();
  const ms = performance.now() - started;
  if (res.status !== 200) throw new Error(`POST /sync/pull -> ${res.status}: ${text.slice(0, 200)}`);
  return { ms, body: JSON.parse(text), bytes: text.length };
}

async function health() {
  const started = performance.now();
  const res = await fetch(`${baseUrl}/health`, { headers: access });
  await res.text();
  return performance.now() - started;
}

const median = (values) => Math.round([...values].sort((a, b) => a - b)[values.length >> 1]);

// Full pull at different page sizes: pages, total rows (must match across sizes) and per-page cost.
let cursors = {};
for (const limit of [200, 500, 1000]) {
  const next = {};
  const pages = [];
  let total = 0;
  let rows = 0;
  for (let page = 0; page < 100; page += 1) {
    const r = await pull({ cursors: next, limit });
    total += r.ms;
    pages.push([Math.round(r.ms), r.bytes]);
    for (const s of r.body.scopes) {
      next[s.scope] = s.cursor;
      rows += s.rows.length;
    }
    if (!r.body.scopes.some((s) => s.hasMore)) break;
  }
  cursors = next;
  console.log(`full pull limit=${limit}: pages=${pages.length} rows=${rows} total=${Math.round(total)}ms per page [ms, bytes]=${JSON.stringify(pages)}`);
}

// Interleaved on one warm connection: network floor, D1-only pull, incremental pull.
await health();
await pull({ cursors });
const floor = [];
const d1Only = [];
const incremental = [];
for (let i = 0; i < Number(roundsArg); i += 1) {
  floor.push(await health());
  d1Only.push((await pull({ cursors, backfill: NO_SCOPE_BACKFILL })).ms);
  incremental.push((await pull({ cursors })).ms);
}
const [h, d, p] = [median(floor), median(d1Only), median(incremental)];
console.log(`p50 health=${h} d1-only=${d} pull=${p} ms => server ~${p - h}, D1 ~${d - h}, Scope ~${p - d}`);
