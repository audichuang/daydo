import { readdirSync, readFileSync, statSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import { TOOL_DEFS } from '../src/mcp/registry';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const serverDir = path.resolve(__dirname, '..');

/** Server-relative .ts paths under each target; a target may be a directory or a single file. */
function collectTsFiles(targets: string[]): string[] {
  const out: string[] = [];
  const visit = (abs: string): void => {
    if (statSync(abs).isDirectory()) {
      for (const entry of readdirSync(abs)) visit(path.join(abs, entry));
    } else if (abs.endsWith('.ts')) {
      out.push(path.relative(serverDir, abs).replace(/\\/g, '/'));
    }
  };
  for (const target of targets) visit(path.join(serverDir, target));
  return out.sort();
}

function matchingFiles(targets: string[], pattern: RegExp): string[] {
  return collectTsFiles(targets).filter((rel) => pattern.test(readFileSync(path.join(serverDir, rel), 'utf8')));
}

const LEDGER_TABLES = new Set(['projectMembership', 'listScopes', 'purgedProject']);

/**
 * Files with a value import (or re-export) of a membership ledger table from the schema, by alias
 * (`@schema`) or relative path (`../db/schema`). Type-only imports and specifiers are ignored; a
 * value namespace import counts, since it reaches every table.
 */
function ledgerValueImporters(dirs: string[]): string[] {
  const statement = /\b(import|export)\s+(?!type\b)([^;]*?)\s+from\s+['"]([^'"]+)['"]/g;
  return collectTsFiles(dirs).filter((rel) => {
    const content = readFileSync(path.join(serverDir, rel), 'utf8');
    for (const [, , clause, source] of content.matchAll(statement)) {
      if (source !== '@schema' && !/(^|\/)db\/schema$/.test(source)) continue;
      if (/^\*\s+as\s/.test(clause.trim())) return true;
      const named = /\{([^}]*)\}/.exec(clause);
      if (!named) continue;
      for (const spec of named[1].split(',')) {
        const parts = spec.trim().split(/\s+/);
        if (parts[0] === 'type') continue;
        if (LEDGER_TABLES.has(parts[0])) return true;
      }
    }
    return false;
  });
}

// The owner-or-editor write rule: 'owner' and 'editor' compared in adjacent terms of one boolean
// chain, either polarity and order, across line breaks, whatever the role read is (variable,
// index, call, optional chain). A three-way role parse (… || x === 'viewer') is not it.
const NEXT_TERM = String.raw`\s*(?:\|\||&&)[^;{}|&]*?(?:===|!==)\s*`;
const NOT_VIEWER = String.raw`(?!${NEXT_TERM}'viewer')`;
const WRITE_ROLE_PAIR = new RegExp(
  [
    String.raw`(?:===|!==)\s*'owner'${NEXT_TERM}'editor'${NOT_VIEWER}`,
    String.raw`(?:===|!==)\s*'editor'${NEXT_TERM}'owner'${NOT_VIEWER}`,
  ].join('|'),
);

// The owner-only entity triple ('member', 'folder', 'tag') compared inline, listed in an array,
// or enumerated as a type union. ENTITY_NAMES in entities.ts has 'project' between 'folder' and 'tag'.
const OWNER_ONLY_TRIPLE = new RegExp(
  [
    String.raw`(?:===|!==)\s*'member'${NEXT_TERM}'folder'${NEXT_TERM}'tag'`,
    String.raw`'member'\s*[,|]\s*'folder'\s*[,|]\s*'tag'`,
  ].join('|'),
);

// Owner role comparison (`=== 'owner'` / `!== 'owner'`), excluding three-way role parsers
// (`x === 'owner' || x === 'editor' || x === 'viewer'` and `x === 'owner' ? 'owner' : ...`).
const OWNER_ROLE_CHECK = new RegExp(
  String.raw`(?:===|!==)\s*'owner'(?!\s*(?:\|\|[^;{}|&]*?===\s*'editor'\s*\|\|[^;{}|&]*?===\s*'viewer'|\?\s*'owner'))`,
);

interface Guard {
  name: string;
  /** Directories or files scanned (server-relative). */
  dirs: string[];
  /** Must not carry the `g` or `y` flag: `.test` would become stateful. */
  pattern: RegExp;
  /** Exactly the files allowed to match. Ratchet: entries may only be removed, never added. */
  allow: string[];
  /**
   * Snippets that violate the rule, one per alternative of the pattern; proves none is hollow.
   * When narrowing a pattern (adding an exclusion), keep a sample of every form the old pattern caught:
   * a lookbehind exclusion once let calls through that the previous version blocked.
   */
  bad: string[];
  /** Optional snippets that must NOT trigger the rule; proves exclusions/word boundaries work. */
  good?: string[];
}

const ALL = ['src', 'routes', 'crons', 'durable-objects'];

const GUARDS: Guard[] = [
  {
    name: 'updatedAt bump stays in serverops/writer.ts',
    dirs: ['src'],
    pattern: /Math\.max\((now|nowMs|Date\.now\(\)|systemNow\(\)|nowOf\(ctx\)), *Number\(/,
    allow: ['src/serverops/writer.ts'],
    bad: [
      'const updatedAt = Math.max(nowMs, Number(row.updatedAt) + 1);',
      'const updatedAt = Math.max(now, Number(row.updatedAt) + 1);',
      'const updatedAt = Math.max(Date.now(), Number(row.updatedAt) + 1);',
      'const updatedAt = Math.max(systemNow(), Number(row.updatedAt) + 1);',
      'const updatedAt = Math.max(nowOf(ctx), Number(row.updatedAt) + 1);',
    ],
  },
  {
    name: 'value helpers are not redefined outside serverops/values.ts',
    dirs: ['src'],
    pattern: /\bconst (bump|isNil|sameValue|SCHEDULE_KEYS)\b/,
    allow: [],
    bad: [
      'const isNil = (v: unknown) => v == null;',
      'const bump = (n: number) => n + 1;',
      'const sameValue = Object.is;',
      "const SCHEDULE_KEYS = ['dueAt'];",
    ],
  },
  {
    name: "'u:' scope prefix literal only in src/sync/scopeName.ts",
    dirs: ALL,
    pattern: /['"`]u:/,
    allow: ['src/sync/scopeName.ts'],
    bad: ["const scope = 'u:' + userId;", 'const scope = "u:" + userId;', 'const scope = `u:${userId}`;'],
  },
  {
    name: 'validateSyncOp is called only in envelope.ts (the definition is excluded)',
    dirs: ALL,
    pattern: /(?<!function )\bvalidateSyncOp\(/,
    allow: ['src/sync/envelope.ts'],
    bad: ['const parsed = validateSyncOp(op);', 'return envelopeOf(raw, validateSyncOp(raw));'],
  },
  {
    name: 'src/scope/** contains no async or await',
    dirs: ['src/scope'],
    pattern: /\b(async|await)\b/,
    allow: [],
    bad: ['export async function load() {}', 'const row = await fetchRow();'],
  },
  {
    name: 'transactionSync only in durable-objects/scope.ts',
    dirs: ALL,
    pattern: /\btransactionSync\b/,
    allow: ['durable-objects/scope.ts'],
    bad: ['this.ctx.storage.transactionSync(() => push());'],
  },
  {
    name: 'serializePublicRow is called only in src/scope/rowView.ts (the definition is excluded)',
    dirs: ALL,
    pattern: /(?<!function )\bserializePublicRow\(/,
    allow: ['src/scope/rowView.ts'],
    bad: ['return serializePublicRow(row);', 'const out = rows.map((r) => serializePublicRow(r));'],
  },
  {
    name: 'fixed push reject reason literals only in src/sync/rejectReason.ts',
    dirs: ['src', 'durable-objects'],
    pattern:
      /['"`](id-in-other-scope|unknown-row|Project is purged|Malformed op|Child taskId cannot be changed|Project deletion must be purged via D1)['"`]/,
    allow: ['src/sync/rejectReason.ts'],
    bad: [
      "results[i] = rejectedResult(opId, 'id-in-other-scope');",
      'rejectOp(op.opId, "unknown-row", op.entity, op.entityId);',
      "const PROJECT_PURGED = 'Project is purged';",
      "results[i] = rejectedResult(rawOpId, 'Malformed op');",
      "return deny('Child taskId cannot be changed');",
      "return deny('Project deletion must be purged via D1');",
    ],
    good: [
      'results[i] = rejectedResult(opId, REJECT_REASON.ID_IN_OTHER_SCOPE);',
      'if (denial === REJECT_REASON.PROJECT_PURGED) return deny(denial);',
      '// a row homed in another scope as a foreign create (id-in-other-scope).',
    ],
  },
  {
    name: "'Forbidden' literal in sync and scope only in src/sync/rejectReason.ts",
    dirs: ['src/sync', 'src/scope'],
    pattern: /['"`]Forbidden['"`]/,
    allow: ['src/sync/rejectReason.ts'],
    bad: [
      "if (!isScopeOwner) return deny('Forbidden');",
      'const denial = "Forbidden";',
      'const denial = `Forbidden`;',
    ],
    good: [
      'if (!isScopeOwner) return deny(REJECT_REASON.FORBIDDEN);',
      '// A list created or claimed earlier in this batch has no D1 role yet; that only waives Forbidden.',
    ],
  },
  {
    name: "status: 'rejected' object literals only in rejectedResult builder and src/serverops/writer.ts",
    dirs: ['src', 'durable-objects'],
    pattern: /\bstatus\s*:\s*['"`]rejected['"`]/,
    allow: ['src/serverops/writer.ts', 'src/sync/rejectReason.ts'],
    bad: [
      "results[i] = { opId, status: 'rejected', reason: 'x', row: null, clocks: {} };",
      'return { opId, status: "rejected", reason, row: null, clocks: {} };',
    ],
    good: [
      "if (seen.status === 'rejected') return;",
      "status: 'applied' | 'rejected';",
      'results[i] = rejectedResult(rawOpId, REJECT_REASON.ID_IN_OTHER_SCOPE);',
    ],
  },
  {
    name: 'owner-or-editor write role check only in src/sync/access.ts',
    dirs: ['src', 'routes', 'crons', 'middleware', 'durable-objects'],
    pattern: WRITE_ROLE_PAIR,
    allow: ['src/sync/access.ts'],
    bad: [
      "if (member.role !== 'owner' &&\n    member.role !== 'editor') return deny();",
      "if (member.role === 'editor' || member.role === 'owner') return ok();",
    ],
  },
  {
    name: 'owner-only entity triple (member, folder, tag) only in src/sync/access.ts',
    dirs: ['src', 'routes', 'crons', 'middleware', 'durable-objects'],
    pattern: OWNER_ONLY_TRIPLE,
    allow: ['src/sync/access.ts'],
    bad: [
      "if (op.entity === 'member' || op.entity === 'folder' || op.entity === 'tag') return;",
      "if (entity !== 'member' && entity !== 'folder' && entity !== 'tag') return;",
      "const CREATOR_ONLY = ['member', 'folder', 'tag'];",
      "type ListEntity = Exclude<EntityName, 'member' | 'folder' | 'tag'>;",
    ],
    good: [
      "if (isOwnerOnlyEntity(op.entity)) return;",
      "const ALL = ['member', 'folder', 'project', 'tag'];",
      "if (op.entity === 'member') return;",
    ],
  },
  {
    name: 'no single-entry fake memberships map in src (use roleCanWrite / isOwner)',
    dirs: ['src'],
    pattern: /\bmemberships\s*:\s*\{\s*\[/,
    allow: [],
    bad: [
      'listWriteDenial(id, { memberships: { [id]: role }, purgedSet: NO_PURGED });',
      'const access = { memberships: { [projectId]: role }, purgedSet };',
    ],
    good: [
      'const access: ListAccess = { memberships: input.memberships, purgedSet };',
      "if (!roleCanWrite(role)) return jsonError(403, 'Forbidden');",
    ],
  },
  {
    name: "owner role comparison (=== / !== 'owner') only in src/sync/access.ts and allow-listed files",
    dirs: ['src', 'routes', 'crons', 'middleware', 'durable-objects'],
    pattern: OWNER_ROLE_CHECK,
    allow: [
      // Single source of truth for role checks.
      'src/sync/access.ts',
      // D1 decoder classifying removed owner rows into removedOwnerProjects (not an access check).
      'src/membership/statements.ts',
      // Owner-only sharing checks (:80, :240, :281, :337 — excluded from SRV-2) and target-member
      // invariants (:288, :351 — owner cannot be demoted or removed, not requester access checks).
      'src/sharing/index.ts',
      // D1 planner routing owner project deletes (:154 — src/sync/push/** untouched in SRV-2).
      'src/sync/push/plan.ts',
    ],
    bad: [
      "if (snapshot.memberships.get(id) !== 'owner') throw new Error('denied');",
      "const isOwner = roleOf(access.memberships, op.entityId) === 'owner';",
      "if (role === 'owner' || role === 'editor') return true;",
    ],
    good: [
      "const ok = role === 'owner' || role === 'editor' || role === 'viewer';",
      "const r = raw === 'owner' ? 'owner' : raw === 'editor' ? 'editor' : 'viewer';",
      "if (!canManageLifecycle(snapshot, id)) throw new Error('denied');",
    ],
  },
  {
    name: 'no randomUUID in data layers (ids are client-side or UUIDv7)',
    dirs: ['src/serverops', 'src/mcp', 'src/sync', 'src/scope', 'src/domain', 'src/sharing', 'src/ics', 'src/membership'],
    pattern: /\brandomUUID\b/,
    // The ICS sync lease token is not a data id.
    allow: ['src/ics/engine.ts'],
    bad: ['const id = crypto.randomUUID();', "import { randomUUID } from 'node:crypto';"],
  },
  {
    name: 'routes/** do not query the database directly',
    dirs: ['routes'],
    // Any receiver (db, primaryDb, database, ...) calling a query method, or any env.DB use:
    // routes pass c.env to productionAppDeps (src/deps.ts) and never touch the binding.
    pattern: /\.(select|insert|update|delete|batch|run|prepare)\(|\.DB\b|\.STORAGE\b/,
    allow: [],
    bad: [
      'const rows = await db.select().from(user);',
      "const database = createDb(c.env.DB, { session: 'first-primary' }); database.run(sql);",
      "await c.env.DB.prepare('DELETE FROM user').run();",
      'const raw = c.env.DB;',
      'const bucket = c.env.STORAGE;',
      'handle(deps(c.env.DB));',
    ],
  },
  {
    name: 'src/membership/statements.ts contains no async or await',
    dirs: ['src/membership/statements.ts'],
    pattern: /\b(async|await)\b/,
    allow: [],
    bad: ['const rows = await db.select();', 'export async function load() {}', 'const row = await fetchRow();'],
  },
  {
    name: 'src/mcp and src/ics do not call getScopeStub (they write via serverops)',
    dirs: ['src/mcp', 'src/ics'],
    pattern: /\bgetScopeStub\(/,
    allow: [],
    bad: ["const stub = services.getScopeStub(scope);"],
  },
  {
    name: 'src/mcp/tools/** do not call writeOrThrow or pushIntents (writes go through the session module)',
    dirs: ['src/mcp/tools'],
    pattern: /\b(writeOrThrow|pushIntents)\(/,
    allow: [],
    bad: [
      'await writeOrThrow(deps, snapshot, intents, { nowMs: now });',
      'const outcomes = await pushIntents(deps, snapshot, intents, { nowMs: now });',
    ],
    good: [
      'await session.write(intents);',
      'const session = await openWriteSession(ctx);',
      "import { WriteError, WriteValidationError } from '../../serverops/writer';",
    ],
  },
  {
    name: 'Date.now only in src/clock.ts and the listed wall-clock readers',
    dirs: ['src', 'routes', 'crons', 'middleware', 'durable-objects'],
    pattern: /\bDate\.now\b|\bnew Date\(\s*\)/,
    // Ratchet: starts as the 23 files that matched when the guard widened, then only shrinks.
    allow: [
      'durable-objects/scope.ts',
      'src/clock.ts',
      'src/ics/engine.ts',
      'src/ics/parser.ts',
      'src/mail/mailer.ts',
      'src/mcp/protocol.ts',
      'src/scope/push.ts',
      'src/serverops/writer.ts',
      'src/sync/push.ts',
    ],
    bad: ['const nowMs = Date.now();', 'this.now = options.now ?? Date.now;', 'const d = new Date();'],
  },
  {
    name: 'systemNow() is only the default of an injectable time',
    dirs: ['src', 'routes', 'crons', 'middleware', 'durable-objects'],
    pattern: /(?<!\?\?\s*)\bsystemNow\(\)/,
    allow: [],
    bad: ['const now = systemNow();', 'expiresAt: systemNow() + TTL_MS,'],
  },
  {
    name: 'createDb( is called only in src/deps.ts',
    dirs: ['src', 'routes', 'crons', 'middleware', 'durable-objects'],
    pattern: /\bcreateDb\(/,
    allow: ['src/deps.ts'],
    bad: ["const db = createDb(c.env.DB, { session: 'first-primary' });"],
  },
  {
    name: 'createStorage( and void/storage are used only in src/deps.ts',
    dirs: ['src', 'routes', 'crons', 'middleware', 'durable-objects'],
    pattern: /\bcreateStorage\(|from ['"]void\/storage['"]/,
    allow: ['src/deps.ts'],
    bad: [
      'const bucket = createStorage(c.env.STORAGE);',
      "import { storage } from 'void/storage';",
    ],
  },
  {
    name: 'Scope.get( is called only in src/deps.ts',
    dirs: ['src', 'routes', 'crons', 'middleware', 'durable-objects'],
    pattern: /\bScope\.get\(/,
    allow: ['src/deps.ts'],
    bad: ['getScopeStub: (scope) => Scope.get(scope),'],
  },
  {
    name: 'native SCOPE namespace (idFromName / .SCOPE) is used only in src/deps.ts',
    dirs: ['src', 'routes', 'crons', 'middleware', 'durable-objects'],
    pattern: /\bidFromName\(|\.SCOPE\b/,
    allow: ['src/deps.ts'],
    bad: [
      "const id = c.env.SCOPE.idFromName('u:1');",
      'const stub = ns.get(ns.idFromName(name));',
      'const ns = bindings.SCOPE;',
    ],
    good: [
      'const raw = env.SCOPE_PHYSICAL_NAMES;',
      'const token = env.SCOPE_ADMIN_TOKEN;',
      'const stub = deps.getPhysicalScopeStub(physical);',
    ],
  },
  {
    // Frozen: config reads stay at the routes/middleware edge; src/ grows no new hidden env dependency.
    name: 'void/env is imported in src only by the two auth edge files',
    dirs: ['src', 'crons', 'durable-objects'],
    pattern: /from ['"]void\/env['"]/,
    allow: ['src/auth/access.ts', 'src/auth/middleware.ts'],
    bad: ["import { env } from 'void/env';"],
  },
  {
    // Row builders are defined once, in tests/helpers/serverHarness.ts (the only definition site, so it is
    // allowed). The only local copy is mcp-ics's seedUser, which seeds a different shape the tests assert on.
    // Function, const/let/var and export forms are all caught, so a wrapper arrow cannot hide a copy.
    name: 'test row builders are defined only in tests/helpers',
    dirs: ['tests'],
    pattern: new RegExp(
      [
        String.raw`^(export )?(async )?function (projectRow|taskRow|deviceOp|seedUser|seedBasic)\b`,
        String.raw`^(export )?(const|let|var) (projectRow|taskRow|deviceOp|seedUser|seedBasic)\b`,
      ].join('|'),
      'm',
    ),
    allow: ['tests/helpers/serverHarness.ts', 'tests/mcp-ics.test.ts'],
    bad: [
      'function projectRow(id: string) {',
      'function taskRow(id: string, projectId: string) {',
      'function deviceOp(h: Harness, entity: string) {',
      'async function seedUser(h: Harness, userId: string) {',
      'async function seedBasic(h: Harness) {',
      'export function taskRow() {}',
      'const projectRow = () => 1;',
      'let deviceOp = makeOp;',
    ],
  },
  {
    // The bad samples are built by concatenation: this file is scanned too, and a literal sample
    // would match its own guard.
    // task-writes keeps one case on a pinned clock: its device edit is stamped FIX_NOW + 10 and must
    // still beat the server's own HLC, which only works when the HLC wall clock is FIX_NOW too.
    name: 'no fake timers in tests',
    dirs: ['tests'],
    pattern: /\buseFakeTimers\b|\bsetSystemTime\b/,
    allow: ['tests/task-writes.test.ts'],
    bad: ['vi.use' + 'FakeTimers();', 'vi.set' + 'SystemTime(0);'],
  },
  {
    // Same concatenation trick as above. scope.test.ts fixes the wall clock on purpose: it tests that
    // the DO's serverTime stays monotonic, which is the HLC wall clock and cannot be injected.
    name: 'Date.now is spied only where the HLC wall clock is under test',
    dirs: ['tests'],
    pattern: /spyOn\(\s*Date\b/,
    allow: ['tests/scope.test.ts'],
    bad: ['vi.spy' + "On(Date, 'now');"],
  },
];

/** Tool names in the first column of the spec/mcp.md section 8 table. */
function specToolNames(): string[] {
  const spec = readFileSync(path.resolve(serverDir, '../spec/mcp.md'), 'utf8');
  const section = /^## 8\. .*$([\s\S]*?)^## 9\. /m.exec(spec);
  if (!section) throw new Error('spec/mcp.md section 8 not found');
  return [...section[1].matchAll(/^\| `([a-z_]+)` \|/gm)].map((m) => m[1]).sort();
}

describe('architecture guards', () => {
  it.each(GUARDS)('$name', ({ dirs, pattern, allow, bad, good }) => {
    expect(pattern.global || pattern.sticky, 'stateful regex flags').toBe(false);
    expect(bad.length, 'no bad samples').toBeGreaterThan(0);
    for (const sample of bad) expect(pattern.test(sample), `pattern misses bad sample: ${sample}`).toBe(true);
    for (const sample of good ?? []) expect(pattern.test(sample), `pattern falsely matches good sample: ${sample}`).toBe(false);
    expect(matchingFiles(dirs, pattern)).toEqual([...allow].sort());
  });

  it('only src/membership/** value-imports the membership ledger tables (alias or relative path)', () => {
    const importers = ledgerValueImporters(['src', 'routes', 'crons', 'middleware', 'durable-objects']);
    expect(importers.filter((rel) => !rel.startsWith('src/membership/'))).toEqual([]);
    // The matcher must still see the legitimate importers, or the check above proves nothing.
    expect(importers.length).toBeGreaterThan(0);
  });

  it('spec/mcp.md section 8 lists exactly the registered MCP tools', () => {
    const specNames = specToolNames();
    expect(specNames.length).toBeGreaterThan(0);
    expect(specNames).toEqual(TOOL_DEFS.map((t) => t.name).sort());
  });

  it('src/mcp/tools/attachments.ts and src/attachments/content.ts share canReadAttachment', () => {
    const accessMod = readFileSync(path.join(serverDir, 'src/attachments/access.ts'), 'utf8');
    expect(accessMod).toMatch(/export function canReadAttachment\b/);
    for (const rel of ['src/attachments/content.ts', 'src/mcp/tools/attachments.ts']) {
      const src = readFileSync(path.join(serverDir, rel), 'utf8');
      expect(src, `${rel} must import canReadAttachment`).toMatch(
        /import\s*\{[^}]*\bcanReadAttachment\b[^}]*\}\s*from\s*['"][^'"]*attachments\/access['"]|import\s*\{[^}]*\bcanReadAttachment\b[^}]*\}\s*from\s*['"]\.\/access['"]/,
      );
      expect(src, `${rel} must call canReadAttachment`).toMatch(/\bcanReadAttachment\(/);
    }
  });
});
