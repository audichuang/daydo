// M16: ICS MCP tools (spec/mcp.md 8, 9) and the production cron (9.5), against a real ScopeObject
// and the in-memory ICS store.
import { eq } from 'drizzle-orm';
import { afterEach, describe, expect, it, vi } from 'vitest';
import * as schema from '../db/schema';
import { acceptInvite, createInvite } from '../src/sharing';
import { MemoryIcsStore } from './helpers/memoryIcsStore';
import { runIcsCron } from '../src/ics/cron';
import { handleToolCall, HINTS, TOOL_DEFS } from '../src/mcp/registry';
import type { ToolContext } from '../src/mcp/toolkit';
import { NO_DATA_MESSAGE } from '../src/serverops/writer';
import { createScopeWorld } from './helpers/scopeWorld';
import { deviceOp, NOW_ISH, projectRow } from './helpers/serverHarness';

const FEED_URL = 'https://calendar.example/feed.ics';
const SECRET_URL = 'https://calendar.example/private-token-123/feed.ics';

// The default sync window is 90 days ahead, so events sit 10 days from now.
const SOON = new Date(Date.now() + 10 * 86_400_000).toISOString().slice(0, 10).replaceAll('-', '');
const event = (uid: string, day = SOON) =>
  ['BEGIN:VEVENT', `UID:${uid}`, `SUMMARY:${uid}`, `DTSTART:${day}T010000Z`, `DTEND:${day}T020000Z`, 'END:VEVENT'].join('\r\n');
const calendar = (...events: string[]) => ['BEGIN:VCALENDAR', 'VERSION:2.0', ...events, 'END:VCALENDAR'].join('\r\n');

function createHarness() {
  const { db, clock, getScopeStub, push, pull } = createScopeWorld();
  const store = new MemoryIcsStore();
  const feeds = new Map<string, string>();
  const fetched: string[] = [];
  const fakeFetch = (async (url: string | URL | Request) => {
    const key = String(url);
    fetched.push(key);
    const body = feeds.get(key);
    if (body === undefined) throw new Error('network down');
    return new Response(body, { status: 200 });
  }) as typeof fetch;
  feeds.set(FEED_URL, calendar(event('a')));
  let seq = 0;
  const deviceHlc = () => `${Date.now() - 60_000}:${String(seq++ % 10000).padStart(4, '0')}:dev-a`;
  const devicePush = (userId: string, ops: unknown[]) => push(userId, 'dev-a', ops);
  const engineDeps = { store, db, getScopeStub, clock, fetchOptions: { fetch: fakeFetch } };
  const ctx = (userId: string): ToolContext => ({
    userId,
    clientId: 'client-1',
    services: { db, getScopeStub, ics: { store, clock, fetchOptions: { fetch: fakeFetch } } },
  });
  return {
    db,
    store,
    feeds,
    fetched,
    engineDeps,
    ctx,
    deviceHlc,
    devicePush,
    pull: (userId: string) => pull(userId, { limit: 1000 }),
    getScopeStub,
  };
}

type Harness = ReturnType<typeof createHarness>;

// Not the shared seedUser: this seeds an extra list `p-<userId>` (the ICS tools' target project) and
// skips the inbox for an account without a member id; the tests assert on both.
async function seedUser(h: Harness, userId: string, memberId: string | null) {
  await h.db.insert(schema.user).values({
    id: userId, name: userId, initial: userId[0], color: '#007AFF', avatarUrl: null, createdAt: NOW_ISH,
  });
  if (memberId) {
    await h.db.update(schema.user).set({ meMemberId: memberId }).where(eq(schema.user.id, userId));
    const res = await h.devicePush(userId, [
      deviceOp(h, 'project', projectRow(`inbox-${userId}`, { isInbox: true, ownerId: memberId })),
      deviceOp(h, 'project', projectRow(`p-${userId}`, { ownerId: memberId })),
    ]);
    expect(res.results.map((r) => r.status)).toEqual(['applied', 'applied']);
  }
}

async function call(h: Harness, userId: string, name: string, args: Record<string, unknown> = {}) {
  const res = await handleToolCall(name, args, h.ctx(userId));
  const textBlock = res.content.find((c) => c.type === 'text');
  const text = textBlock?.text ?? '';
  return { isError: res.isError === true, text, json: res.isError ? null : (JSON.parse(text) as unknown) };
}

const addArgs = (extra: Record<string, unknown> = {}) => ({ name: 'Work', url: FEED_URL, project_id: 'p-u-a', ...extra });

async function tasksOf(h: Harness, userId: string) {
  const out: Record<string, unknown>[] = [];
  for (const s of (await h.pull(userId)).scopes) {
    for (const r of s.rows) if (r.entity === 'task' && !('gone' in r)) out.push(r.row as Record<string, unknown>);
  }
  return out;
}

describe('M16 registry', () => {
  it('registers the five ICS tools with the spec hints and open-world flags', () => {
    const byName = Object.fromEntries(TOOL_DEFS.map((t) => [t.name, t]));
    expect(HINTS.add_ics_source).toBe('write');
    expect(HINTS.list_ics_sources).toBe('read');
    expect(HINTS.remove_ics_source).toBe('destructive');
    expect(HINTS.sync_ics_now).toBe('destructive');
    expect(HINTS.get_ics_sync_status).toBe('read');
    expect(byName.add_ics_source!.annotations).toMatchObject({ readOnlyHint: false, destructiveHint: false, openWorldHint: true });
    expect(byName.list_ics_sources!.annotations).toEqual({ readOnlyHint: true, openWorldHint: false });
    expect(byName.remove_ics_source!.annotations).toMatchObject({ destructiveHint: true, openWorldHint: false });
    expect(byName.sync_ics_now!.annotations).toMatchObject({ destructiveHint: true, openWorldHint: true });
    expect(byName.get_ics_sync_status!.annotations.readOnlyHint).toBe(true);
    expect(byName.sync_ics_now!.description).toMatch(/at least 5/);
    expect(byName.sync_ics_now!.description).toMatch(/more than half/);
    expect(byName.remove_ics_source!.inputSchema.properties.source_id!.type).toBe('integer');
  });
});

describe('M16 add_ics_source', () => {
  it('stores the source with defaults and lists it with the url', async () => {
    const h = createHarness();
    await seedUser(h, 'u-a', 'm-a');
    const added = await call(h, 'u-a', 'add_ics_source', addArgs({ timezone: 'Asia/Tokyo', filter: { future_days: 30, past_days: 0, exclude_keywords: ['x'] } }));
    expect(added.isError).toBe(false);
    expect(added.json).toMatchObject({
      name: 'Work', url: FEED_URL, projectId: 'p-u-a', enabled: true, syncIntervalSec: 900, timezone: 'Asia/Tokyo',
      filter: { futureDays: 30, pastDays: 0, excludeKeywords: ['x'] },
    });
    const list = await call(h, 'u-a', 'list_ics_sources');
    expect(list.json).toEqual([expect.objectContaining({ url: FEED_URL, name: 'Work' })]);
    expect(h.fetched).toEqual([]);
  });

  it.each([
    ['unknown filter key', { filter: { future_day: 3 } }, /Unknown filter key/],
    ['future_days 0', { filter: { future_days: 0 } }, /future_days/],
    ['future_days 3651', { filter: { future_days: 3651 } }, /future_days/],
    ['past_days -1', { filter: { past_days: -1 } }, /past_days/],
    ['past_days 3651', { filter: { past_days: 3651 } }, /past_days/],
    ['interval 299', { sync_interval_sec: 299 }, /sync_interval_sec/],
    ['bad timezone', { timezone: 'Mars/Base' }, /timezone/],
    ['offset timezone', { timezone: '+08:00' }, /timezone/],
    ['private url', { url: 'https://127.0.0.1/feed.ics' }, /not allowed/],
    ['http url', { url: 'http://calendar.example/feed.ics' }, /./],
    ['unknown project', { project_id: 'nope' }, /Unknown project_id/],
  ])('rejects %s and stores nothing', async (_label, extra, message) => {
    const h = createHarness();
    await seedUser(h, 'u-a', 'm-a');
    const res = await call(h, 'u-a', 'add_ics_source', addArgs(extra));
    expect(res.isError).toBe(true);
    expect(res.text).toMatch(message);
    expect(await h.store.listSources('u-a')).toEqual([]);
  });

  it('accepts interval 300 and future_days 3650', async () => {
    const h = createHarness();
    await seedUser(h, 'u-a', 'm-a');
    const res = await call(h, 'u-a', 'add_ics_source', addArgs({ sync_interval_sec: 300, filter: { future_days: 3650 } }));
    expect(res.json).toMatchObject({ syncIntervalSec: 300, filter: { futureDays: 3650 } });
  });

  it('refuses a list the caller cannot write and an account without data', async () => {
    const h = createHarness();
    await seedUser(h, 'u-a', 'm-a');
    await seedUser(h, 'u-b', null);
    const viewer = await call(h, 'u-b', 'add_ics_source', addArgs());
    expect(viewer.isError).toBe(true);
    expect(viewer.text).toBe(`Error: ${NO_DATA_MESSAGE}`);
    // u-a's project is invisible to u-b.
    await seedUser(h, 'u-c', 'm-c');
    const other = await call(h, 'u-c', 'add_ics_source', addArgs());
    expect(other.isError).toBe(true);
    expect(other.text).toMatch(/Unknown project_id/);
  });

  it('refuses a read-only (viewer) list', async () => {
    const h = createHarness();
    await seedUser(h, 'u-a', 'm-a');
    await seedUser(h, 'u-c', 'm-c');
    const invite = await createInvite(h.db, { userId: 'u-a', projectId: 'p-u-a', role: 'viewer', nowMs: Date.now() });
    await acceptInvite(h.db, { code: invite.code, userId: 'u-c', getScopeStub: h.getScopeStub, nowMs: Date.now() });
    const res = await call(h, 'u-c', 'add_ics_source', addArgs());
    expect(res.isError).toBe(true);
    expect(res.text).toMatch(/read-only/);
  });

  it('treats an archived list as unknown, for the owner and for a viewer', async () => {
    const h = createHarness();
    await seedUser(h, 'u-a', 'm-a');
    await seedUser(h, 'u-c', 'm-c');
    const invite = await createInvite(h.db, { userId: 'u-a', projectId: 'p-u-a', role: 'viewer', nowMs: Date.now() });
    await acceptInvite(h.db, { code: invite.code, userId: 'u-c', getScopeStub: h.getScopeStub, nowMs: Date.now() });
    const archived = await h.devicePush('u-a', [{ ...deviceOp(h, 'project', { id: 'p-u-a', archivedAt: NOW_ISH }), fields: ['archivedAt'] }]);
    expect(archived.results[0]?.status).toBe('applied');
    for (const userId of ['u-a', 'u-c']) {
      const res = await call(h, userId, 'add_ics_source', addArgs());
      expect(res.isError, userId).toBe(true);
      expect(res.text, userId).toMatch(/Unknown project_id/);
    }
    expect(await h.store.listSources('u-a')).toEqual([]);
  });
});

describe('M16 list, remove, status', () => {
  it('only shows and removes the caller own sources; remove keeps the synced tasks', async () => {
    const h = createHarness();
    await seedUser(h, 'u-a', 'm-a');
    await seedUser(h, 'u-c', 'm-c');
    const added = (await call(h, 'u-a', 'add_ics_source', addArgs())).json as { id: number };
    expect((await call(h, 'u-c', 'list_ics_sources')).json).toEqual([]);
    const foreign = await call(h, 'u-c', 'remove_ics_source', { source_id: added.id });
    expect(foreign.isError).toBe(true);
    expect(await h.store.listSources('u-a')).toHaveLength(1);

    await call(h, 'u-a', 'sync_ics_now', { source_id: added.id });
    expect(await tasksOf(h, 'u-a')).toHaveLength(1);
    const removed = await call(h, 'u-a', 'remove_ics_source', { source_id: added.id });
    expect(removed.json).toEqual({ removed: added.id });
    expect(await h.store.listSources('u-a')).toEqual([]);
    expect(await tasksOf(h, 'u-a')).toHaveLength(1);
    expect((await call(h, 'u-a', 'remove_ics_source', { source_id: added.id })).isError).toBe(true);
  });

  it('get_ics_sync_status returns lastStats as a string and the mapping count', async () => {
    const h = createHarness();
    await seedUser(h, 'u-a', 'm-a');
    const added = (await call(h, 'u-a', 'add_ics_source', addArgs())).json as { id: number };
    const before = (await call(h, 'u-a', 'get_ics_sync_status')).json;
    expect(before).toEqual([{ id: added.id, name: 'Work', enabled: true, lastSyncAt: null, lastStatus: null, lastStats: null, mappingCount: 0 }]);
    await call(h, 'u-a', 'sync_ics_now', { source_id: added.id });
    const [status] = (await call(h, 'u-a', 'get_ics_sync_status', { source_id: added.id })).json as Array<Record<string, unknown>>;
    expect(status).toMatchObject({ id: added.id, lastStatus: 'success', mappingCount: 1 });
    expect(typeof status!.lastStats).toBe('string');
    expect(JSON.parse(status!.lastStats as string)).toMatchObject({ created: 1 });
    expect((await call(h, 'u-a', 'get_ics_sync_status', { source_id: 9999 })).json).toEqual([]);
  });
});

describe('M16 sync_ics_now', () => {
  it('syncs one source and a second device pulls the task', async () => {
    const h = createHarness();
    await seedUser(h, 'u-a', 'm-a');
    const added = (await call(h, 'u-a', 'add_ics_source', addArgs())).json as { id: number };
    const res = await call(h, 'u-a', 'sync_ics_now', { source_id: added.id, include_changes: true });
    expect(res.json).toMatchObject({ created: 1, errors: 0, changes: [expect.objectContaining({ action: 'create' })] });
    const tasks = await tasksOf(h, 'u-a');
    expect(tasks).toMatchObject([{ title: 'a', projectId: 'p-u-a' }]);
  });

  it('dry_run writes nothing', async () => {
    const h = createHarness();
    await seedUser(h, 'u-a', 'm-a');
    const added = (await call(h, 'u-a', 'add_ics_source', addArgs())).json as { id: number };
    const res = await call(h, 'u-a', 'sync_ics_now', { source_id: added.id, dry_run: true });
    expect(res.json).toMatchObject({ dryRun: true, created: 1 });
    expect(await tasksOf(h, 'u-a')).toEqual([]);
  });

  it('allow_mass_delete requires source_id and booleans must be booleans', async () => {
    const h = createHarness();
    await seedUser(h, 'u-a', 'm-a');
    const noId = await call(h, 'u-a', 'sync_ics_now', { allow_mass_delete: true });
    expect(noId.isError).toBe(true);
    expect(noId.text).toMatch(/requires source_id/);
    const bad = await call(h, 'u-a', 'sync_ics_now', { dry_run: 'yes' });
    expect(bad.isError).toBe(true);
    expect(bad.text).toMatch(/dry_run must be a boolean/);
  });

  it('allow_mass_delete overrides the guard that otherwise refuses the pass', async () => {
    const h = createHarness();
    await seedUser(h, 'u-a', 'm-a');
    const ids = ['a', 'b', 'c', 'd', 'e', 'f'];
    h.feeds.set(FEED_URL, calendar(...ids.map((id) => event(id))));
    const added = (await call(h, 'u-a', 'add_ics_source', addArgs())).json as { id: number };
    expect((await call(h, 'u-a', 'sync_ics_now', { source_id: added.id })).json).toMatchObject({ created: 6 });
    h.feeds.set(FEED_URL, calendar(event('a')));
    const refused = await call(h, 'u-a', 'sync_ics_now', { source_id: added.id });
    expect(refused.json).toMatchObject({ deleted: 0 });
    expect((await tasksOf(h, 'u-a')).filter((t) => t.deletedAt == null)).toHaveLength(6);
    const forced = await call(h, 'u-a', 'sync_ics_now', { source_id: added.id, allow_mass_delete: true });
    expect(forced.json).toMatchObject({ deleted: 5 });
    expect((await tasksOf(h, 'u-a')).filter((t) => t.deletedAt == null)).toHaveLength(1);
  });

  it('unknown or foreign source_id is an error', async () => {
    const h = createHarness();
    await seedUser(h, 'u-a', 'm-a');
    await seedUser(h, 'u-c', 'm-c');
    const added = (await call(h, 'u-a', 'add_ics_source', addArgs())).json as { id: number };
    expect((await call(h, 'u-a', 'sync_ics_now', { source_id: 999 })).isError).toBe(true);
    expect((await call(h, 'u-c', 'sync_ics_now', { source_id: added.id })).isError).toBe(true);
    expect(h.fetched).toEqual([]);
  });

  it('without source_id syncs only the caller own due sources', async () => {
    const h = createHarness();
    await seedUser(h, 'u-a', 'm-a');
    await seedUser(h, 'u-c', 'm-c');
    await call(h, 'u-a', 'add_ics_source', addArgs());
    await call(h, 'u-c', 'add_ics_source', addArgs({ project_id: 'p-u-c' }));
    const res = await call(h, 'u-a', 'sync_ics_now');
    expect(res.json).toEqual([expect.objectContaining({ created: 1 })]);
    expect(await tasksOf(h, 'u-c')).toEqual([]);
  });
});

describe('M16 cron', () => {
  afterEach(() => vi.restoreAllMocks());

  const env = { DB: undefined as unknown as D1Database };

  async function addDirect(h: Harness, userId: string, n: number, url = FEED_URL) {
    const out: number[] = [];
    for (let i = 0; i < n; i++) out.push((await h.store.addSource(userId, { name: `S${i}`, url, projectId: `p-${userId}` })).id);
    return out;
  }

  it('syncs due sources, at most 5 per run, the rest on the next run', async () => {
    const h = createHarness();
    await seedUser(h, 'u-a', 'm-a');
    await addDirect(h, 'u-a', 7);
    vi.spyOn(console, 'log').mockImplementation(() => undefined);
    await runIcsCron(env, h.engineDeps);
    expect(h.fetched).toHaveLength(5);
    await runIcsCron(env, h.engineDeps);
    expect(h.fetched).toHaveLength(7);
    await runIcsCron(env, h.engineDeps);
    expect(h.fetched).toHaveLength(7);
  });

  it('never passes allowMassDelete: a truncated feed deletes nothing', async () => {
    const h = createHarness();
    await seedUser(h, 'u-a', 'm-a');
    h.feeds.set(FEED_URL, calendar(...['a', 'b', 'c', 'd', 'e', 'f'].map((id) => event(id))));
    const [id] = await addDirect(h, 'u-a', 1);
    vi.spyOn(console, 'log').mockImplementation(() => undefined);
    await runIcsCron(env, h.engineDeps);
    expect((await tasksOf(h, 'u-a')).filter((t) => t.deletedAt == null)).toHaveLength(6);
    // Make it due again, then empty the feed.
    await h.store.setSourceSync('u-a', id!, { lastSyncAt: 0, lastStatus: 'success', lastStats: '{}' });
    h.feeds.set(FEED_URL, calendar());
    await expect(runIcsCron(env, h.engineDeps)).resolves.toBeUndefined();
    expect((await tasksOf(h, 'u-a')).filter((t) => t.deletedAt == null)).toHaveLength(6);
    expect((await h.store.getSource('u-a', id!))?.lastStatus).not.toBe('success');
  });

  it('logs one ics.sync line per source without the url, and a failing source does not fail the run', async () => {
    const h = createHarness();
    await seedUser(h, 'u-a', 'm-a');
    const log = vi.spyOn(console, 'log').mockImplementation(() => undefined);
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => undefined);
    const [ok] = await addDirect(h, 'u-a', 1);
    const [broken] = await addDirect(h, 'u-a', 1, SECRET_URL);
    await expect(runIcsCron(env, h.engineDeps)).resolves.toBeUndefined();
    const lines = [...log.mock.calls, ...warn.mock.calls].map((c) => String(c[0])).filter((l) => l.includes('ics.sync'));
    expect(lines).toHaveLength(2);
    for (const line of lines) {
      expect(line).not.toContain('calendar.example');
      expect(line).not.toContain('private-token');
    }
    const parsed = lines.map((l) => JSON.parse(l) as Record<string, unknown>);
    expect(parsed.map((p) => p.source_id).sort()).toEqual([ok, broken].sort());
    expect(parsed.every((p) => p.event === 'ics.sync')).toBe(true);
    expect((await h.store.getSource('u-a', broken!))?.lastStatus).toBe('error');
    expect((await h.store.getSource('u-a', ok!))?.lastStatus).toBe('success');
  });

  it('throws when the due query itself fails', async () => {
    const h = createHarness();
    vi.spyOn(h.store, 'dueSources').mockRejectedValue(new Error('d1 down'));
    await expect(runIcsCron(env, h.engineDeps)).rejects.toThrow('d1 down');
  });
});
