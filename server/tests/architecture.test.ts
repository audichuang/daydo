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

interface Guard {
  name: string;
  /** Directories or files scanned (server-relative). */
  dirs: string[];
  /** Must not carry the `g` or `y` flag: `.test` would become stateful. */
  pattern: RegExp;
  /** Exactly the files allowed to match. Ratchet: entries may only be removed, never added. */
  allow: string[];
  /** A snippet that violates the rule; proves the pattern is not hollow. */
  bad: string;
}

const ALL = ['src', 'routes', 'crons', 'durable-objects'];

const GUARDS: Guard[] = [
  {
    name: 'updatedAt bump stays in serverops/writer.ts',
    dirs: ['src'],
    pattern: /Math\.max\((now|nowMs|Date\.now\(\)), *Number\(/,
    allow: ['src/serverops/writer.ts'],
    bad: 'const updatedAt = Math.max(nowMs, Number(row.updatedAt) + 1);',
  },
  {
    name: 'value helpers are not redefined outside serverops/values.ts',
    dirs: ['src'],
    pattern: /\bconst (bump|isNil|sameValue|SCHEDULE_KEYS)\b/,
    allow: [],
    bad: 'const isNil = (v: unknown) => v == null;',
  },
  {
    name: "'u:' scope prefix literal only in src/sync/scopeName.ts",
    dirs: ALL,
    pattern: /'u:'|`u:/,
    allow: ['src/sync/scopeName.ts'],
    bad: "const scope = 'u:' + userId;",
  },
  {
    name: 'validateSyncOp only defined in entities.ts and called in envelope.ts',
    dirs: ALL,
    pattern: /\bvalidateSyncOp\(/,
    allow: ['src/sync/entities.ts', 'src/sync/envelope.ts'],
    bad: 'const parsed = validateSyncOp(op);',
  },
  {
    name: 'src/scope/** contains no async or await',
    dirs: ['src/scope'],
    pattern: /\b(async|await)\b/,
    allow: [],
    bad: 'export async function load() {}',
  },
  {
    name: 'transactionSync only in durable-objects/scope.ts',
    dirs: ALL,
    pattern: /\btransactionSync\b/,
    allow: ['durable-objects/scope.ts'],
    bad: 'this.ctx.storage.transactionSync(() => push());',
  },
  {
    name: 'serializePublicRow only defined in entities.ts and called in src/scope/rowView.ts',
    dirs: ALL,
    pattern: /\bserializePublicRow\(/,
    allow: ['src/scope/rowView.ts', 'src/sync/entities.ts'],
    bad: 'return serializePublicRow(row);',
  },
  {
    name: 'owner-or-editor write role check only in src/sync/access.ts',
    dirs: ['src', 'routes', 'crons', 'middleware', 'durable-objects'],
    pattern: WRITE_ROLE_PAIR,
    allow: ['src/sync/access.ts'],
    bad: "if (member.role !== 'owner' &&\n    member.role !== 'editor') return deny();",
  },
  {
    name: 'no randomUUID in data layers (ids are client-side or UUIDv7)',
    dirs: ['src/serverops', 'src/mcp', 'src/sync', 'src/scope', 'src/domain', 'src/sharing'],
    pattern: /\brandomUUID\b/,
    allow: [],
    bad: 'const id = crypto.randomUUID();',
  },
  {
    name: 'routes/** do not query the database directly',
    dirs: ['routes'],
    pattern: /\bdb\.(select|insert|update|delete|batch|run|query)\b/,
    allow: [],
    bad: 'const rows = await db.select().from(user);',
  },
  {
    name: 'src/membership/statements.ts contains no async or await',
    dirs: ['src/membership/statements.ts'],
    pattern: /\b(async|await)\b/,
    allow: [],
    bad: 'const rows = await db.select();',
  },
  {
    name: 'src/mcp and src/ics do not call getScopeStub (they write via serverops)',
    dirs: ['src/mcp', 'src/ics'],
    pattern: /\bgetScopeStub\(/,
    allow: [],
    bad: "const stub = services.getScopeStub('u:1');",
  },
  {
    name: 'Date.now() in domain, serverops and scope stays in its frozen files',
    dirs: ['src/domain', 'src/serverops', 'src/scope'],
    pattern: /\bDate\.now\(\)/,
    allow: ['src/domain/uuid.ts', 'src/scope/push.ts', 'src/serverops/writer.ts'],
    bad: 'const nowMs = Date.now();',
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
  it.each(GUARDS)('$name', ({ dirs, pattern, allow, bad }) => {
    expect(pattern.global || pattern.sticky, 'stateful regex flags').toBe(false);
    expect(pattern.test(bad), 'pattern does not match its bad sample').toBe(true);
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
});
