import { readdirSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import { TOOL_DEFS } from '../src/mcp/registry';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const featuresDir = path.resolve(__dirname, '../.claude/skills/verify/features');

describe('verify skill feature coverage', () => {
  it('documents every registered MCP tool in verify/features/*.md', () => {
    const featureFiles = readdirSync(featuresDir)
      .filter((name) => name.endsWith('.md') && name !== 'README.md')
      .sort();
    expect(featureFiles.length).toBeGreaterThan(0);

    const combined = featureFiles
      .map((name) => readFileSync(path.join(featuresDir, name), 'utf8'))
      .join('\n');

    const missing = TOOL_DEFS.map((t) => t.name).filter(
      (name) => !new RegExp(`\\b${name}\\b`).test(combined),
    );
    expect(missing).toEqual([]);
  });
});
