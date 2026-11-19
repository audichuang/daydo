import { execFile, execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { createServer } from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';
import { and, eq } from 'drizzle-orm';
import type { CloudContext } from 'void';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import * as schema from '../db/schema';
import { signAccessToken } from '../src/auth/crypto';
import { createSessionForIdentity } from '../src/auth/session';
import { acceptInvite, createInvite } from '../src/sharing';
import { resolveMemberId } from '../src/sync/entities';
import { createScopeWorld, type ScopeWorld } from './helpers/scopeWorld';
import { deviceOp, NOW_ISH, projectRow, taskRow } from './helpers/serverHarness';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const SECRET = 'relocation-route-test-jwt-secret-at-least-32-bytes';

const testEnv: {
  JWT_SECRET: string;
  SCOPE_ADMIN_TOKEN?: string;
} = {
  JWT_SECRET: SECRET,
};

vi.mock('void', () => ({
  defineHandler: (handler: unknown) => handler,
  defineMiddleware: (middleware: unknown) => middleware,
}));
vi.mock('void/env', () => ({ env: testEnv }));

let world: ScopeWorld | null = null;
const legacyScopeGets: string[] = [];

vi.mock('../durable-objects/scope', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../durable-objects/scope')>();
  const mocked = {
    ...actual.default,
    get: (scope: string) => {
      legacyScopeGets.push(scope);
      return world!.getScopeStub(scope);
    },
  };
  return { ...actual, default: mocked, Scope: mocked };
});

const { productionAppDeps } = await import('../src/deps');
const { POST: postAdmin } = await import('../routes/admin/scope-relocation');
const { POST: postPush } = await import('../routes/sync/push');
const { POST: postPull } = await import('../routes/sync/pull');
const { GET: getInvite } = await import('../routes/invites/[code]/index');
const { POST: postAcceptInvite } = await import('../routes/invites/[code]/accept');
const { PUT: putAttachment, GET: getAttachment } = await import(
  '../routes/attachments/[id]/content'
);
const { POST: postRefresh } = await import('../routes/auth/refresh');

type RouteFn = (c: CloudContext) => Promise<Response>;

interface NativeCall {
  name: string;
  options?: DurableObjectNamespaceGetDurableObjectOptions;
}

function makeNativeNamespace(calls: NativeCall[]) {
  return {
    idFromName(name: string) {
      return { toString: () => name } as unknown as DurableObjectId;
    },
    get(id: DurableObjectId, options?: DurableObjectNamespaceGetDurableObjectOptions) {
      const name = id.toString();
      calls.push({ name, options });
      return world!.getPhysicalScopeStub(name);
    },
  };
}

function makeContext(opts: {
  method?: string;
  url?: string;
  headers?: Record<string, string>;
  body?: unknown;
  rawBody?: BodyInit | null;
  params?: Record<string, string>;
  envOverrides?: Record<string, unknown>;
}): CloudContext {
  const method = opts.method ?? 'POST';
  const url = opts.url ?? 'https://api.daydoapp.com/';
  const headers = new Headers(opts.headers);
  let requestBody: BodyInit | null | undefined;
  if (opts.rawBody !== undefined) {
    requestBody = opts.rawBody;
  } else if (opts.body !== undefined) {
    if (!headers.has('Content-Type')) headers.set('Content-Type', 'application/json');
    requestBody = JSON.stringify(opts.body);
  }
  const raw = new Request(url, { method, headers, body: method === 'GET' ? undefined : requestBody });
  const env = {
    DB: world!.d1,
    STORAGE: world!.storage,
    SCOPE: makeNativeNamespace([]),
    ...opts.envOverrides,
  };
  const vars = new Map<string, unknown>();
  return {
    env,
    set: (k: string, v: unknown) => {
      vars.set(k, v);
    },
    get: (k: string) => vars.get(k),
    req: {
      raw,
      url: raw.url,
      header: (name: string) => raw.headers.get(name) ?? undefined,
      param: (name: string) => opts.params?.[name],
      json: () => raw.json(),
    },
    json: (data: unknown, status = 200) =>
      new Response(JSON.stringify(data), {
        status,
        headers: { 'Content-Type': 'application/json' },
      }),
  } as unknown as CloudContext;
}

beforeEach(() => {
  world = createScopeWorld();
  legacyScopeGets.length = 0;
  delete testEnv.SCOPE_ADMIN_TOKEN;
});

describe('productionAppDeps logical -> physical routing', () => {
  it('routes mapped scopes via native SCOPE with locationHint apac-ne and keeps unmapped scopes on Scope.get', () => {
    const nativeCalls: NativeCall[] = [];
    const deps = productionAppDeps({
      DB: world!.d1,
      SCOPE: makeNativeNamespace(nativeCalls),
      SCOPE_PHYSICAL_NAMES: JSON.stringify({ 'u:alice': 'u:alice:nrt1' }),
    });

    deps.getScopeStub('u:alice');
    expect(nativeCalls).toEqual([{ name: 'u:alice:nrt1', options: { locationHint: 'apac-ne' } }]);
    expect(legacyScopeGets).toEqual([]);

    deps.getScopeStub('u:bob');
    expect(legacyScopeGets).toEqual(['u:bob']);
    expect(nativeCalls).toHaveLength(1);

    deps.getPhysicalScopeStub('u:charlie:nrt2');
    expect(nativeCalls[1]).toEqual({ name: 'u:charlie:nrt2', options: { locationHint: 'apac-ne' } });
  });

  it('falls back to identity routing on bad SCOPE_PHYSICAL_NAMES and logs once per bad value', () => {
    const errorSpy = vi.spyOn(console, 'error').mockImplementation(() => {});
    try {
      const badValues = ['{not-json', '["u:a"]', '{"u:a":123}', '{"u:a":""}'];
      for (const bad of badValues) {
        errorSpy.mockClear();
        const nativeCalls: NativeCall[] = [];
        const deps1 = productionAppDeps({
          DB: world!.d1,
          SCOPE: makeNativeNamespace(nativeCalls),
          SCOPE_PHYSICAL_NAMES: bad,
        });
        const deps2 = productionAppDeps({
          DB: world!.d1,
          SCOPE: makeNativeNamespace(nativeCalls),
          SCOPE_PHYSICAL_NAMES: bad,
        });
        deps1.getScopeStub('u:a');
        deps2.getScopeStub('u:a');
        expect(nativeCalls).toEqual([]);
        expect(errorSpy).toHaveBeenCalledTimes(1);
      }
    } finally {
      errorSpy.mockRestore();
    }
  });
});

describe('POST /admin/scope-relocation', () => {
  const admin = postAdmin as unknown as RouteFn;

  it('returns 404 when SCOPE_ADMIN_TOKEN is unset or Authorization header is missing/wrong', async () => {
    const req = (headers?: Record<string, string>) =>
      admin(makeContext({ headers, body: { action: 'status', physical: 'u:u-a' } }));

    // Secret unset -> 404 even with Bearer header
    expect((await req({ Authorization: 'Bearer anything' })).status).toBe(404);

    // Secret set, missing/malformed/wrong token -> 404
    testEnv.SCOPE_ADMIN_TOKEN = 'super-secret-admin-token';
    expect((await req()).status).toBe(404);
    expect((await req({ Authorization: 'Basic abc' })).status).toBe(404);
    expect((await req({ Authorization: 'Bearer wrong-token' })).status).toBe(404);
  });

  it('executes status, freeze, begin-import, export, import, digest, finish-import, and unfreeze with valid token', async () => {
    testEnv.SCOPE_ADMIN_TOKEN = 'super-secret-admin-token';
    const auth = { Authorization: 'Bearer super-secret-admin-token' };
    const call = async (body: Record<string, unknown>) => {
      const res = await admin(makeContext({ headers: auth, body }));
      return { status: res.status, json: (await res.json()) as Record<string, any> };
    };

    // Seed a row on u:u-a
    await world!.db.insert(schema.user).values({
      id: 'u-a', name: 'A', initial: 'A', color: '#007AFF', avatarUrl: null, createdAt: NOW_ISH,
    });
    const hlc = `${Date.now()}:0000:dev-a`;
    await world!.push('u-a', 'dev-a', [
      deviceOp({ deviceHlc: () => hlc }, 'project', projectRow('p1', { isInbox: true })),
    ]);

    const st = await call({ action: 'status', physical: 'u:u-a' });
    expect(st.status).toBe(200);
    expect(st.json.state).toBe('live');
    expect(st.json.tables.project).toBe(1);

    // Export before freeze -> 409
    expect((await call({ action: 'export', physical: 'u:u-a', table: 'project' })).status).toBe(409);
    // Unknown action -> 400
    expect((await call({ action: 'nuke', physical: 'u:u-a' })).status).toBe(400);

    // purge-frozen: needs expectMaxServerSeq (400) and a frozen DO (409)
    expect((await call({ action: 'purge-frozen', physical: 'u:u-a' })).status).toBe(400);
    expect((await call({ action: 'purge-frozen', physical: 'u:u-a', expectMaxServerSeq: st.json.maxServerSeq })).status).toBe(409);
    expect((await call({ action: 'status', physical: 'u:u-a' })).json.tables.project).toBe(1);

    // Freeze old, begin-import new, copy, verify digest, finish-import
    expect((await call({ action: 'freeze', physical: 'u:u-a' })).status).toBe(200);
    expect((await call({ action: 'begin-import', physical: 'u:u-a:nrt1' })).status).toBe(200);

    for (const table of Object.keys(st.json.tables)) {
      const exp = await call({ action: 'export', physical: 'u:u-a', table, afterRowid: 0 });
      expect(exp.status).toBe(200);
      if (exp.json.rows.length > 0) {
        const imp = await call({
          action: 'import',
          physical: 'u:u-a:nrt1',
          table,
          rows: exp.json.rows,
        });
        expect(imp.status).toBe(200);
      }
    }

    const oldDig = await call({ action: 'digest', physical: 'u:u-a' });
    const newDig = await call({ action: 'digest', physical: 'u:u-a:nrt1' });
    expect(newDig.json.tables).toEqual(oldDig.json.tables);

    // Missing expectDigest -> 400; mismatched expectDigest -> 409; matching -> 200
    expect((await call({ action: 'finish-import', physical: 'u:u-a:nrt1' })).status).toBe(400);
    expect(
      (
        await call({
          action: 'finish-import',
          physical: 'u:u-a:nrt1',
          expectDigest: { ...oldDig.json.tables, project: { count: 99, sha256: 'bad' } },
        })
      ).status,
    ).toBe(409);
    expect((await call({ action: 'status', physical: 'u:u-a:nrt1' })).json.state).toBe('importing');

    expect(
      (
        await call({
          action: 'finish-import',
          physical: 'u:u-a:nrt1',
          expectDigest: oldDig.json.tables,
        })
      ).status,
    ).toBe(200);
    expect((await call({ action: 'unfreeze', physical: 'u:u-a' })).status).toBe(200);
  });
});

describe('HTTP 503 mapping and frozen invite projection healing', () => {
  it('returns HTTP 503 JSON for sync, invite info, attachment, and auth routes when the target Scope is relocating', async () => {
    const db = world!.db;
    await db.insert(schema.user).values([
      { id: 'u-a', name: 'Alice', initial: 'A', color: '#007AFF', avatarUrl: null, createdAt: NOW_ISH },
      { id: 'u-b', name: 'Bob', initial: 'B', color: '#34C759', avatarUrl: null, createdAt: NOW_ISH },
      { id: 'u-c', name: 'Cara', initial: 'C', color: '#FF9500', avatarUrl: null, createdAt: NOW_ISH },
    ]);
    await db.insert(schema.identity).values({
      provider: 'apple',
      sub: 'sub-a',
      userId: 'u-a',
      email: null,
    });

    let seq = 0;
    const deviceHlc = () => `${Date.now()}:${String(seq++).padStart(4, '0')}:dev-a`;
    await world!.push('u-a', 'dev-a', [
      deviceOp({ deviceHlc }, 'project', projectRow('p1', { isInbox: true })),
      deviceOp({ deviceHlc }, 'task', taskRow('t1', 'p1')),
      deviceOp({ deviceHlc }, 'attachment', {
        id: 'att-1',
        taskId: 't1',
        fileName: 'a.txt',
        size: 5,
        mimeType: 'text/plain',
        createdAt: NOW_ISH,
        updatedAt: NOW_ISH,
      }),
    ]);

    const inv = await createInvite(db, { userId: 'u-a', projectId: 'p1', role: 'editor' });
    await acceptInvite(db, { code: inv.code, userId: 'u-b', getScopeStub: world!.getScopeStub });

    const session = await createSessionForIdentity(db as never, {
      provider: 'apple',
      sub: 'sub-a',
      email: null,
      deviceId: 'dev-a',
      jwtSecret: SECRET,
      getScopeStub: world!.getScopeStub,
    });
    const tokenA = await signAccessToken('u-a', SECRET);
    const tokenC = await signAccessToken('u-c', SECRET);
    const authA = { Authorization: `Bearer ${tokenA}` };
    const authC = { Authorization: `Bearer ${tokenC}` };

    // --- Frozen u:u-a ---
    await world!.getPhysicalScopeStub('u:u-a').setRelocationState({ state: 'frozen', expect: 'live' });

    // POST /sync/push -> 503
    const pushRes = await (postPush as unknown as RouteFn)(
      makeContext({
        headers: authA,
        body: { deviceId: 'dev-a', ops: [deviceOp({ deviceHlc }, 'task', taskRow('t2', 'p1'))] },
      }),
    );
    expect(pushRes.status).toBe(503);
    expect(((await pushRes.json()) as { error: string }).error).toMatch(/relocating/i);

    // POST /sync/pull while frozen -> still 200
    const pullFrozen = await (postPull as unknown as RouteFn)(
      makeContext({ headers: authA, body: { cursors: {} } }),
    );
    expect(pullFrozen.status).toBe(200);

    // --- Importing target mapped to u:u-a ---
    await world!.getPhysicalScopeStub('u:u-a:nrt1').setRelocationState({ state: 'importing', expect: 'live' });
    world!.physicalNames.set('u:u-a', 'u:u-a:nrt1');

    // POST /sync/pull -> 503
    const pullImp = await (postPull as unknown as RouteFn)(
      makeContext({ headers: authA, body: { cursors: {} } }),
    );
    expect(pullImp.status).toBe(503);

    // GET /invites/:code -> 503 (reads Scope before any D1 commit)
    const getInvRes = await (getInvite as unknown as RouteFn)(
      makeContext({ method: 'GET', headers: authC, params: { code: inv.code } }),
    );
    expect(getInvRes.status).toBe(503);

    // PUT & GET /attachments/:id/content -> 503
    const putAttRes = await (putAttachment as unknown as RouteFn)(
      makeContext({
        method: 'PUT',
        headers: { ...authA, 'Content-Type': 'text/plain', 'Content-Length': '5' },
        rawBody: 'hello',
        params: { id: 'att-1' },
      }),
    );
    expect(putAttRes.status).toBe(503);

    const getAttRes = await (getAttachment as unknown as RouteFn)(
      makeContext({ method: 'GET', headers: authA, params: { id: 'att-1' } }),
    );
    expect(getAttRes.status).toBe(503);

    // POST /auth/refresh -> 503 (getInboxProjectId on importing scope)
    const refreshRes = await (postRefresh as unknown as RouteFn)(
      makeContext({ body: { refreshToken: session.refreshToken } }),
    );
    expect(refreshRes.status).toBe(503);
  });

  it('succeeds on invite accept while home scope is frozen, commits D1 membership, and heals projection on pull after unfreeze', async () => {
    const db = world!.db;
    await db.insert(schema.user).values([
      { id: 'u-a', name: 'Alice', initial: 'A', color: '#007AFF', avatarUrl: null, createdAt: NOW_ISH },
      { id: 'u-c', name: 'Cara', initial: 'C', color: '#FF9500', avatarUrl: null, createdAt: NOW_ISH },
    ]);
    await world!.push('u-a', 'dev-a', [
      deviceOp({ deviceHlc: () => `${Date.now()}:0000:dev-a` }, 'project', projectRow('p1')),
    ]);
    const inv = await createInvite(db, { userId: 'u-a', projectId: 'p1', role: 'editor' });

    const homeStub = world!.getPhysicalScopeStub('u:u-a');
    await homeStub.setRelocationState({ state: 'frozen', expect: 'live' });
    const beforeDigest = (await homeStub.digest()).tables;

    const tokenC = await signAccessToken('u-c', SECRET);
    const acceptRes = await (postAcceptInvite as unknown as RouteFn)(
      makeContext({ headers: { Authorization: `Bearer ${tokenC}` }, params: { code: inv.code } }),
    );
    expect(acceptRes.status).toBe(200);
    expect(await acceptRes.json()).toEqual({ projectId: 'p1', scope: 'u:u-a', role: 'editor' });

    // D1 membership was committed, and the frozen DO was NOT written
    const d1Memberships = await db
      .select({ role: schema.projectMembership.role })
      .from(schema.projectMembership)
      .where(and(eq(schema.projectMembership.projectId, 'p1'), eq(schema.projectMembership.userId, 'u-c')));
    expect(d1Memberships).toEqual([{ role: 'editor' }]);
    expect((await homeStub.relocationStatus()).tables.projectMember).toBe(0);
    expect((await homeStub.digest()).tables).toEqual(beforeDigest);

    // After unfreezing, a pull projects the membership into the home DO
    await homeStub.setRelocationState({ state: 'live', expect: 'frozen' });
    const pullRes = await (postPull as unknown as RouteFn)(
      makeContext({ headers: { Authorization: `Bearer ${tokenC}` }, body: { cursors: {} } }),
    );
    expect(pullRes.status).toBe(200);
    const pullBody = (await pullRes.json()) as {
      scopes: Array<{ scope: string; rows: Array<{ entity: string; row?: Record<string, unknown> }> }>;
    };
    const projected = pullBody.scopes
      .find((s) => s.scope === 'u:u-a')
      ?.rows.filter((r) => r.entity === 'projectMember' && r.row?.memberId === resolveMemberId('u-c', null));
    expect(projected).toHaveLength(1);
    expect(projected?.[0].row?.role).toBe('editor');
  });
});

describe('scripts/relocate-scope.mjs CLI safety and end-to-end flow', () => {
  const scriptPath = path.resolve(__dirname, '../scripts/relocate-scope.mjs');
  const execFileAsync = promisify(execFile);

  it('exits cleanly on --help and exits non-zero without env vars when no subcommand is given', () => {
    const helpOut = execFileSync(process.execPath, [scriptPath, '--help'], { encoding: 'utf8' });
    expect(helpOut).toContain('nothing runs without an explicit subcommand');

    let status = 0;
    try {
      execFileSync(process.execPath, [scriptPath], { encoding: 'utf8', stdio: 'pipe' });
    } catch (err: any) {
      status = err.status;
    }
    expect(status).toBe(2);
  });

  it('drives status, freeze, copy (empty check, 1M maxChars, backup, digest), and verified finish against POST /admin/scope-relocation', async () => {
    testEnv.SCOPE_ADMIN_TOKEN = 'driver-test-token';
    const admin = postAdmin as unknown as RouteFn;

    await world!.db.insert(schema.user).values({
      id: 'u-a', name: 'A', initial: 'A', color: '#007AFF', avatarUrl: null, createdAt: NOW_ISH,
    });
    const hlc = `${Date.now()}:0000:dev-a`;
    await world!.push('u-a', 'dev-a', [
      deviceOp({ deviceHlc: () => hlc }, 'project', projectRow('p1', { isInbox: true })),
      deviceOp({ deviceHlc: () => `${Date.now()}:0001:dev-a` }, 'task', taskRow('t1', 'p1')),
    ]);

    const seenAccessHeaders: Array<{ id: string | undefined; secret: string | undefined }> = [];
    const seenPayloads: Array<Record<string, any>> = [];
    const server = createServer((req, res) => {
      void (async () => {
        const chunks: Buffer[] = [];
        for await (const c of req) chunks.push(c as Buffer);
        seenAccessHeaders.push({
          id: req.headers['cf-access-client-id'] as string | undefined,
          secret: req.headers['cf-access-client-secret'] as string | undefined,
        });
        const rawBody = Buffer.concat(chunks).toString('utf8');
        seenPayloads.push(JSON.parse(rawBody));
        const response = await admin(
          makeContext({
            method: req.method ?? 'POST',
            url: `http://127.0.0.1${req.url ?? '/'}`,
            headers: {
              authorization: String(req.headers.authorization ?? ''),
              'content-type': String(req.headers['content-type'] ?? 'application/json'),
            },
            rawBody,
          }),
        );
        res.statusCode = response.status;
        res.setHeader('Content-Type', 'application/json');
        res.end(await response.text());
      })();
    });

    await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
    const addr = server.address();
    const port = typeof addr === 'object' && addr ? addr.port : 0;
    const backupDir = mkdtempSync(path.join(os.tmpdir(), 'daydo-relocate-test-'));

    const runDriver = (cliArgs: string[]) =>
      execFileAsync(process.execPath, [scriptPath, ...cliArgs], {
        env: {
          ...process.env,
          BASE_URL: `http://127.0.0.1:${port}`,
          SCOPE_ADMIN_TOKEN: 'driver-test-token',
          CF_ACCESS_CLIENT_ID: 'cf-id',
          CF_ACCESS_CLIENT_SECRET: 'cf-secret',
        },
      });

    try {
      // copy refuses before freeze
      await expect(runDriver(['copy', 'u:u-a', 'u:u-a:nrt1', backupDir])).rejects.toThrow();

      // copy refuses an empty frozen source before calling begin-import on target
      await runDriver(['freeze', 'u:empty']);
      await expect(runDriver(['copy', 'u:empty', 'u:empty:nrt1', backupDir])).rejects.toThrow(/empty/i);
      expect((await world!.getPhysicalScopeStub('u:empty:nrt1').relocationStatus()).state).toBe('live');

      const statusRes = await runDriver(['status', 'u:u-a']);
      expect(JSON.parse(statusRes.stdout).state).toBe('live');

      await runDriver(['freeze', 'u:u-a']);

      // finish refuses a partially imported target without calling finish-import
      const partialStub = world!.getPhysicalScopeStub('u:u-a:partial');
      await partialStub.setRelocationState({ state: 'importing', expect: 'live' });
      seenPayloads.length = 0;
      await expect(runDriver(['finish', 'u:u-a', 'u:u-a:partial'])).rejects.toThrow();
      expect(seenPayloads.some((p) => p.action === 'finish-import')).toBe(false);
      expect((await partialStub.relocationStatus()).state).toBe('importing');

      // Full copy prints source counts + maxServerSeq and exports with maxChars: 1_000_000
      seenPayloads.length = 0;
      const copyRes = await runDriver(['copy', 'u:u-a', 'u:u-a:nrt1', backupDir]);
      expect(copyRes.stdout).toContain('maxServerSeq=');
      expect(copyRes.stdout).toContain('table digests match');
      const exportPayloads = seenPayloads.filter((p) => p.action === 'export');
      expect(exportPayloads.length).toBeGreaterThan(0);
      for (const p of exportPayloads) {
        expect(p.maxChars).toBe(1_000_000);
      }

      // Backup files written
      const taskLines = readFileSync(path.join(backupDir, 'task.jsonl'), 'utf8')
        .trim()
        .split('\n')
        .map((l) => JSON.parse(l));
      expect(taskLines).toHaveLength(1);
      expect(taskLines[0].values.id).toBe('t1');

      // New DO stays in importing until explicit `finish <old> <new>`
      expect((await world!.getPhysicalScopeStub('u:u-a:nrt1').relocationStatus()).state).toBe(
        'importing',
      );
      seenPayloads.length = 0;
      await runDriver(['finish', 'u:u-a', 'u:u-a:nrt1']);
      const finishCall = seenPayloads.find((p) => p.action === 'finish-import');
      expect(finishCall?.expectDigest).toEqual((await world!.getPhysicalScopeStub('u:u-a').digest()).tables);
      expect((await world!.getPhysicalScopeStub('u:u-a:nrt1').relocationStatus()).state).toBe(
        'live',
      );

      // Every request carried Cloudflare Access headers
      expect(seenAccessHeaders.length).toBeGreaterThan(5);
      for (const h of seenAccessHeaders) {
        expect(h).toEqual({ id: 'cf-id', secret: 'cf-secret' });
      }
    } finally {
      server.close();
      rmSync(backupDir, { recursive: true, force: true });
    }
  });
});
