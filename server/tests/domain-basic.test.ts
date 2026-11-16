import { readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import { after, before, between, isGeneratedKeyValid, uniqueProjectKey } from '../src/domain/sortKey';
import { normalizeTags } from '../src/domain/tags';
import {
  canonicalReminder,
  formatReminder,
  parseReminder,
  parseReminderCsv,
} from '../src/domain/reminders';
import { uuidv5, uuidv7 } from '../src/domain/uuid';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const fixturePath = path.resolve(__dirname, '../../spec/fixtures/sync-ops.json');

describe('uuid', () => {
  it('uuidv5 matches the Swift vector', async () => {
    expect(await uuidv5('01a1dd5b-fc89-75e1-b4c4-fb62891e2107|2026-11-15|1140')).toBe(
      'cc64dbd5-1983-5448-8442-0fba63492416',
    );
  });

  it('uuidv5 ids in the sync fixture are reproduced', async () => {
    const text = readFileSync(fixturePath, 'utf8');
    expect(text).toContain('cc64dbd5-1983-5448-8442-0fba63492416');
    expect(await uuidv5('01a1dd5b-fc89-75e1-b4c4-fb62891e2107|2026-11-15|1140')).toBe(
      'cc64dbd5-1983-5448-8442-0fba63492416',
    );
  });

  it('uuidv7 encodes timestamp, version and variant', () => {
    const id = uuidv7(0x01a1dd5bfc89);
    expect(id).toMatch(/^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
    expect(id.replace(/-/g, '').slice(0, 12)).toBe('01a1dd5bfc89');
    expect(uuidv7()).not.toBe(uuidv7());
  });
});

describe('sortKey', () => {
  it('after chain', () => {
    const chain = ['i'];
    for (let i = 0; i < 8; i++) chain.push(after(chain[chain.length - 1]!));
    expect(chain).toEqual(['i', 'r', 'v', 'x', 'y', 'z', 'zi', 'zr', 'zv']);
  });

  it('before chain', () => {
    const chain = ['9'];
    for (let i = 0; i < 7; i++) chain.push(before(chain[chain.length - 1]!));
    expect(chain).toEqual(['9', '4', '2', '1', '0i', '09', '04', '02']);
  });

  it('between vectors including the known quirk', () => {
    expect(between('i', 'r')).toBe('m');
    expect(between('i', 'j')).toBe('ii');
    expect(between('i', 'i0')).toBe('i0i');
  });

  it('throws when a >= b', () => {
    expect(() => between('b', 'a')).toThrow();
    expect(() => between('a', 'a')).toThrow();
  });

  it('isGeneratedKeyValid rejects trailing 0 and bad chars', () => {
    expect(isGeneratedKeyValid('i')).toBe(true);
    expect(isGeneratedKeyValid('i0i')).toBe(true);
    expect(isGeneratedKeyValid('i0')).toBe(false);
    expect(isGeneratedKeyValid('')).toBe(false);
    expect(isGeneratedKeyValid('I1')).toBe(false);
  });

  it('uniqueProjectKey appends 2 chars, last never 0', () => {
    for (const r of [0, 0.5, 0.999999]) {
      const key = uniqueProjectKey('i', () => r);
      expect(key.startsWith('r')).toBe(true);
      expect(key).toHaveLength(3);
      expect(key.endsWith('0')).toBe(false);
      expect(isGeneratedKeyValid(key)).toBe(true);
    }
    expect(uniqueProjectKey('i', () => 0)).toBe('r01');
    expect(uniqueProjectKey(null)).toHaveLength(3);
    expect(uniqueProjectKey('i', Math.random).endsWith('0')).toBe(false);
  });
});

describe('tags', () => {
  it('trims, strips # at both ends, lowercases, dedupes', () => {
    expect(normalizeTags([' #Work ', 'work', '##Home#', '', '#', 'WORK'])).toEqual(['work', 'home']);
  });
});

describe('reminders', () => {
  it('canonical output', () => {
    expect(canonicalReminder('-PT24H')).toBe('TRIGGER:-P1D');
    expect(canonicalReminder('TRIGGER:PT0S')).toBe('TRIGGER:PT0S');
    expect(canonicalReminder('trigger:-pt15m')).toBe('TRIGGER:-PT15M');
    expect(canonicalReminder('TRIGGER:P0DT9H0M0S')).toBe('TRIGGER:PT9H');
    expect(canonicalReminder('P1W')).toBe('TRIGGER:P7D');
    expect(canonicalReminder('+PT90M')).toBe('TRIGGER:PT1H30M');
  });

  it('parse and format are inverse', () => {
    expect(parseReminder('TRIGGER:-P1DT2H')).toBe(-93600);
    expect(formatReminder(-93600)).toBe('TRIGGER:-P1DT2H');
    expect(formatReminder(0)).toBe('TRIGGER:PT0S');
  });

  it('rejects invalid triggers', () => {
    for (const bad of ['', 'abc', 'PT15', 'P1H', 'PTM', 'PT1X', '-']) {
      expect(parseReminder(bad)).toBeNull();
      expect(() => canonicalReminder(bad)).toThrow(/Invalid reminder trigger/);
    }
  });

  it('rejects offsets beyond a year, which would overflow the App\'s Int arithmetic', () => {
    expect(parseReminder('-P366D')).toBe(-366 * 86400);
    expect(parseReminder('P52W')).toBe(52 * 7 * 86400);
    for (const bad of ['-P999999999999999D', 'P367D', 'P53W', 'PT8785H', 'P366DT1S', '-PT99999999999999999999S']) {
      expect(parseReminder(bad), bad).toBeNull();
      expect(() => parseReminderCsv(bad), bad).toThrow(/Invalid reminder trigger/);
    }
  });

  it('comma string input', () => {
    expect(parseReminderCsv('-PT24H, PT0S,, -PT15M ')).toEqual([
      'TRIGGER:-P1D',
      'TRIGGER:PT0S',
      'TRIGGER:-PT15M',
    ]);
    expect(parseReminderCsv('')).toEqual([]);
    expect(() => parseReminderCsv('PT0S,bogus')).toThrow();
  });
});
