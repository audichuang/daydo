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
});
