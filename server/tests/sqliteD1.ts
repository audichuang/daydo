import { readdirSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { DatabaseSync, type SQLInputValue } from 'node:sqlite';
import { fileURLToPath } from 'node:url';
import { drizzle } from 'drizzle-orm/d1';
import * as schema from '../db/schema';
import type { AppDb } from '../src/sync/push';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const migrationsDir = path.resolve(__dirname, '../db/migrations');

interface BoundD1Statement {
  all: () => Promise<{ results: Array<Record<string, unknown>>; success: true; meta: Record<string, unknown> }>;
  raw: () => Promise<unknown[][]>;
  run: () => Promise<{ results: []; success: true; meta: Record<string, unknown> }>;
  first: (col?: string) => Promise<unknown>;
}

function makeBound(sqlite: DatabaseSync, query: string, params: SQLInputValue[]): BoundD1Statement {
  const execAll = (): Array<Record<string, unknown>> => {
    const stmt = sqlite.prepare(query);
    return stmt.all(...params) as Array<Record<string, unknown>>;
  };

  return {
    async all() {
      const results = execAll();
      return { results, success: true, meta: {} };
    },
    async raw() {
      const stmt = sqlite.prepare(query);
      stmt.setReturnArrays(true);
      try {
        return stmt.all(...params) as unknown as unknown[][];
      } finally {
        stmt.setReturnArrays(false);
      }
    },
    async run() {
      const stmt = sqlite.prepare(query);
      stmt.run(...params);
      return { results: [], success: true, meta: {} };
    },
    async first(col?: string) {
      const rows = execAll();
      if (rows.length === 0) return null;
      return col ? rows[0][col] : rows[0];
    },
  };
}

export function createTestD1(): { sqlite: DatabaseSync; d1: D1Database; db: AppDb } {
  const sqlite = new DatabaseSync(':memory:');
  sqlite.exec('PRAGMA foreign_keys = ON;');

  const files = readdirSync(migrationsDir)
    .filter((f) => f.endsWith('.sql'))
    .sort();
  for (const file of files) {
    const sqlText = readFileSync(path.join(migrationsDir, file), 'utf8');
    for (const chunk of sqlText.split('--> statement-breakpoint')) {
      const trimmed = chunk.trim();
      if (trimmed.length > 0) {
        sqlite.exec(trimmed);
      }
    }
  }

  const sessionObj = {
    prepare(query: string) {
      return {
        bind(...params: SQLInputValue[]) {
          return makeBound(sqlite, query, params);
        },
        all: () => makeBound(sqlite, query, []).all(),
        raw: () => makeBound(sqlite, query, []).raw(),
        run: () => makeBound(sqlite, query, []).run(),
        first: (col?: string) => makeBound(sqlite, query, []).first(col),
      };
    },
    async batch(statements: BoundD1Statement[]) {
      sqlite.exec('BEGIN IMMEDIATE');
      try {
        const results = [];
        for (const stmt of statements) {
          results.push(await stmt.all());
        }
        sqlite.exec('COMMIT');
        return results;
      } catch (err) {
        sqlite.exec('ROLLBACK');
        throw err;
      }
    },
    async exec(sqlText: string) {
      sqlite.exec(sqlText);
      return { count: 0, duration: 0 };
    },
  };

  const d1 = {
    ...sessionObj,
    withSession() {
      return sessionObj;
    },
  } as unknown as D1Database;

  const db = drizzle(d1, { schema }) as unknown as AppDb;
  return { sqlite, d1, db };
}

export function createTestDoState(): { sqlite: DatabaseSync; ctx: DurableObjectState } {
  const sqlite = new DatabaseSync(':memory:');
  let txnDepth = 0;

  const sql = {
    exec(query: string, ...params: SQLInputValue[]) {
      const trimmed = query.trim();
      if (!trimmed.includes('?') && params.length === 0 && trimmed.includes(';')) {
        sqlite.exec(trimmed);
        return {
          toArray: () => [],
          one: () => {
            throw new Error('Expected 1 row, got 0');
          },
          [Symbol.iterator]: () => [][Symbol.iterator](),
        };
      }
      const stmt = sqlite.prepare(trimmed);
      const rows = stmt.all(...params) as Array<Record<string, unknown>>;
      return {
        toArray: () => rows,
        one: () => {
          if (rows.length !== 1) {
            throw new Error(`Expected 1 row, got ${rows.length}`);
          }
          return rows[0];
        },
        [Symbol.iterator]: () => rows[Symbol.iterator](),
      };
    },
  };

  const storage = {
    sql,
    transactionSync<T>(fn: () => T): T {
      const isOuter = txnDepth === 0;
      txnDepth += 1;
      if (isOuter) {
        sqlite.exec('BEGIN IMMEDIATE');
      }
      try {
        const res = fn();
        if (isOuter) {
          sqlite.exec('COMMIT');
        }
        return res;
      } catch (err) {
        if (isOuter) {
          sqlite.exec('ROLLBACK');
        }
        throw err;
      } finally {
        txnDepth -= 1;
      }
    },
  };

  return {
    sqlite,
    ctx: { storage } as unknown as DurableObjectState,
  };
}
