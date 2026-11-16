import { readdirSync, readFileSync, statSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const serverDir = path.resolve(__dirname, '..');

function collectTsFiles(dirs: string[]): string[] {
  const out: string[] = [];
  const walk = (absDir: string): void => {
    for (const entry of readdirSync(absDir)) {
      const abs = path.join(absDir, entry);
      if (statSync(abs).isDirectory()) {
        walk(abs);
      } else if (entry.endsWith('.ts')) {
        out.push(path.relative(serverDir, abs).replace(/\\/g, '/'));
      }
    }
  };
  for (const dir of dirs) {
    walk(path.join(serverDir, dir));
  }
  return out.sort();
}

function matchingFiles(dirs: string[], pattern: RegExp): string[] {
  return collectTsFiles(dirs).filter((rel) => {
    const content = readFileSync(path.join(serverDir, rel), 'utf8');
    return pattern.test(content);
  });
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

// The owner-or-editor write rule: 'owner' and 'editor' compared in one boolean chain, either
// polarity and order, across line breaks. A three-way role parse (… || x === 'viewer') is not it.
const OPERAND = String.raw`[\w$.\[\]'"]+`;
const NOT_VIEWER = String.raw`(?!\s*(?:\|\||&&)\s*${OPERAND}\s*(?:===|!==)\s*'viewer')`;
const WRITE_ROLE_PAIR = new RegExp(
  [
    String.raw`(?:===|!==)\s*'owner'\s*(?:\|\||&&)\s*${OPERAND}\s*(?:===|!==)\s*'editor'${NOT_VIEWER}`,
    String.raw`(?:===|!==)\s*'editor'\s*(?:\|\||&&)\s*${OPERAND}\s*(?:===|!==)\s*'owner'${NOT_VIEWER}`,
  ].join('|'),
);

describe('architecture guards', () => {
  it('updatedAt bump and duplicated value helpers stay centralized in writer/values', () => {
    expect(matchingFiles(['src'], /Math\.max\((now|nowMs|Date\.now\(\)), *Number\(/)).toEqual([
      'src/serverops/writer.ts',
    ]);
    expect(matchingFiles(['src'], /\bconst (bump|isNil|sameValue|SCHEDULE_KEYS)\b/)).toEqual([]);
  });

  it("'u:' scope prefix literal only appears in src/sync/scopeName.ts", () => {
    expect(matchingFiles(['src', 'routes', 'crons', 'durable-objects'], /'u:'|`u:/)).toEqual([
      'src/sync/scopeName.ts',
    ]);
  });

  it('validateSyncOp is only defined in entities.ts and called in envelope.ts', () => {
    expect(matchingFiles(['src', 'routes', 'crons', 'durable-objects'], /\bvalidateSyncOp\(/)).toEqual([
      'src/sync/entities.ts',
      'src/sync/envelope.ts',
    ]);
  });

  it('src/scope/** contains no async or await', () => {
    expect(matchingFiles(['src/scope'], /\b(async|await)\b/)).toEqual([]);
  });

  it('transactionSync only appears in durable-objects/scope.ts', () => {
    expect(matchingFiles(['src'], /\btransactionSync\b/)).toEqual([]);
    expect(matchingFiles(['src', 'routes', 'crons', 'durable-objects'], /\btransactionSync\b/)).toEqual([
      'durable-objects/scope.ts',
    ]);
  });

  it('only src/membership/** value-imports the membership ledger tables (alias or relative path)', () => {
    const importers = ledgerValueImporters(['src', 'routes', 'crons', 'middleware', 'durable-objects']);
    expect(importers.filter((rel) => !rel.startsWith('src/membership/'))).toEqual([]);
    // The matcher must still see the legitimate importers, or the check above proves nothing.
    expect(importers.length).toBeGreaterThan(0);
  });

  it('serializePublicRow is only defined in entities.ts and called in src/scope/rowView.ts', () => {
    expect(matchingFiles(['src', 'routes', 'crons', 'durable-objects'], /\bserializePublicRow\(/)).toEqual([
      'src/scope/rowView.ts',
      'src/sync/entities.ts',
    ]);
  });

  it("the owner-or-editor write role check only appears in src/sync/access.ts", () => {
    expect(matchingFiles(['src', 'routes', 'crons', 'middleware', 'durable-objects'], WRITE_ROLE_PAIR)).toEqual([
      'src/sync/access.ts',
    ]);
  });
});
