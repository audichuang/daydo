import type { DatabaseSync } from 'node:sqlite';
import { afterEach, describe, expect, it, vi } from 'vitest';
import type { DatabaseClient } from '../src/auth/session';
import {
  CODE_RETENTION_MS,
  EMAIL_CODE_RETENTION_MS,
  PENDING_RETENTION_MS,
  REFRESH_RETENTION_MS,
  cleanupExpiredOAuth,
  isCleanupTick,
  runOAuthCleanup,
} from '../src/oauth/cleanup';
import { createTestD1 } from './sqliteD1';

const NOW = Date.UTC(2027, 0, 15, 10, 0, 0);
const DAY = 24 * 60 * 60 * 1000;

function setup() {
  const { db, sqlite } = createTestD1();
  return { sqlite, database: db as unknown as DatabaseClient };
}

function insertPending(sqlite: DatabaseSync, id: string, expiresAt: number, consumedAt: number | null = null) {
  sqlite
    .prepare(
      `INSERT INTO oauthPending (id, clientId, redirectUri, codeChallenge, scope, bindHash, provider, nonce, createdAt, expiresAt, consumedAt)
       VALUES (?, 'c', 'https://a.example/cb', 'cc', 'mcp', 'b', '', 'n', ?, ?, ?)`,
    )
    .run(id, expiresAt - 600_000, expiresAt, consumedAt);
}

function insertCode(sqlite: DatabaseSync, codeHash: string, expiresAt: number, usedAt: number | null = null) {
  sqlite
    .prepare(
      `INSERT INTO oauthCode (codeHash, clientId, redirectUri, codeChallenge, scope, userId, familyId, expiresAt, usedAt)
       VALUES (?, 'c', 'https://a.example/cb', 'cc', 'mcp', 'u', 'f', ?, ?)`,
    )
    .run(codeHash, expiresAt, usedAt);
}

function insertRefresh(sqlite: DatabaseSync, refreshHash: string, expiresAt: number, revokedAt: number | null = null) {
  sqlite
    .prepare(
      `INSERT INTO oauthRefresh (refreshHash, familyId, userId, clientId, scope, createdAt, expiresAt, revokedAt)
       VALUES (?, 'f', 'u', 'c', 'mcp', ?, ?, ?)`,
    )
    .run(refreshHash, expiresAt - 30 * DAY, expiresAt, revokedAt);
}

function insertEmailCode(sqlite: DatabaseSync, id: string, expiresAt: number, usedAt: number | null = null) {
  sqlite
    .prepare(
      `INSERT INTO emailCode (id, email, codeHash, salt, attempts, createdAt, expiresAt, usedAt, pendingId, ipHash)
       VALUES (?, 'a@example.com', 'h', 's', 0, ?, ?, ?, NULL, 'ip')`,
    )
    .run(id, expiresAt - 600_000, expiresAt, usedAt);
}

function ids(sqlite: DatabaseSync, table: string, key: string): string[] {
  return (sqlite.prepare(`SELECT ${key} AS k FROM ${table} ORDER BY ${key}`).all() as Array<{ k: string }>).map(
    (r) => r.k,
  );
}

function seed(sqlite: DatabaseSync) {
  insertPending(sqlite, 'p-old', NOW - PENDING_RETENTION_MS - 1);
  insertPending(sqlite, 'p-old-consumed', NOW - PENDING_RETENTION_MS - 1, NOW - DAY - 5);
  insertPending(sqlite, 'p-edge', NOW - PENDING_RETENTION_MS);
  insertPending(sqlite, 'p-expired-recent', NOW - 1);
  insertPending(sqlite, 'p-open', NOW + 1);
  insertCode(sqlite, 'c-old', NOW - CODE_RETENTION_MS - 1, NOW - CODE_RETENTION_MS - 100);
  insertCode(sqlite, 'c-edge', NOW - CODE_RETENTION_MS);
  insertCode(sqlite, 'c-live', NOW + 1);
  insertRefresh(sqlite, 'r-old', NOW - REFRESH_RETENTION_MS - 1);
  insertRefresh(sqlite, 'r-old-revoked', NOW - REFRESH_RETENTION_MS - 1, NOW - 50 * DAY);
  insertRefresh(sqlite, 'r-edge', NOW - REFRESH_RETENTION_MS);
  // Revoked long ago but expired recently: kept so reuse of the old token still revokes the family.
  insertRefresh(sqlite, 'r-revoked-recent-expiry', NOW - DAY, NOW - 40 * DAY);
  insertRefresh(sqlite, 'r-live', NOW + DAY);
  insertEmailCode(sqlite, 'e-old', NOW - EMAIL_CODE_RETENTION_MS - 1);
  insertEmailCode(sqlite, 'e-old-used', NOW - EMAIL_CODE_RETENTION_MS - 1, NOW - EMAIL_CODE_RETENTION_MS - 100);
  insertEmailCode(sqlite, 'e-edge', NOW - EMAIL_CODE_RETENTION_MS);
  insertEmailCode(sqlite, 'e-live', NOW + 1);
  sqlite
    .prepare('INSERT INTO oauthClient (clientId, clientName, redirectUris, ipHash, createdAt) VALUES (?, ?, ?, ?, ?)')
    .run('mcp-ancient', 'x', '[]', 'h', NOW - 400 * DAY);
}

afterEach(() => {
  vi.restoreAllMocks();
});

describe('cleanupExpiredOAuth (spec/mcp.md 4.8)', () => {
  it('deletes only rows past their retention, per table, and never clients', async () => {
    const { sqlite, database } = setup();
    expect(PENDING_RETENTION_MS).toBe(DAY);
    expect(CODE_RETENTION_MS).toBe(DAY);
    expect(REFRESH_RETENTION_MS).toBe(30 * DAY);
    expect(EMAIL_CODE_RETENTION_MS).toBe(DAY);
    seed(sqlite);

    const deleted = await cleanupExpiredOAuth(database, NOW);
    expect(deleted).toEqual({ pending: 2, code: 1, refresh: 2, emailCode: 2 });
    expect(ids(sqlite, 'oauthPending', 'id')).toEqual(['p-edge', 'p-expired-recent', 'p-open']);
    expect(ids(sqlite, 'oauthCode', 'codeHash')).toEqual(['c-edge', 'c-live']);
    expect(ids(sqlite, 'oauthRefresh', 'refreshHash')).toEqual(['r-edge', 'r-live', 'r-revoked-recent-expiry']);
    expect(ids(sqlite, 'oauthClient', 'clientId')).toEqual(['mcp-ancient']);
    expect(ids(sqlite, 'emailCode', 'id')).toEqual(['e-edge', 'e-live']);
  });

  it('deletes at most `batch` rows per table per call', async () => {
    const { sqlite, database } = setup();
    for (let i = 0; i < 5; i++) insertPending(sqlite, `p-${i}`, NOW - 2 * DAY);
    expect(await cleanupExpiredOAuth(database, NOW, 2)).toEqual({ pending: 2, code: 0, refresh: 0, emailCode: 0 });
    expect(ids(sqlite, 'oauthPending', 'id')).toHaveLength(3);
    for (let i = 0; i < 3; i++) insertEmailCode(sqlite, `e-${i}`, NOW - 2 * DAY);
    expect(await cleanupExpiredOAuth(database, NOW, 2)).toEqual({ pending: 2, code: 0, refresh: 0, emailCode: 2 });
    expect(ids(sqlite, 'emailCode', 'id')).toHaveLength(1);
  });
});

describe('runOAuthCleanup (hourly from the 5-minute cron)', () => {
  it('runs only on the first tick of each UTC hour', () => {
    expect(isCleanupTick(Date.UTC(2027, 0, 15, 10, 0, 0))).toBe(true);
    expect(isCleanupTick(Date.UTC(2027, 0, 15, 10, 4, 59))).toBe(true);
    expect(isCleanupTick(Date.UTC(2027, 0, 15, 10, 5, 0))).toBe(false);
    expect(isCleanupTick(Date.UTC(2027, 0, 15, 10, 55, 0))).toBe(false);
  });

  it('skips the cleanup on other ticks and runs it on the hourly one, logging the counts', async () => {
    const { sqlite, database } = setup();
    seed(sqlite);
    const log = vi.spyOn(console, 'log').mockImplementation(() => {});

    await runOAuthCleanup(database, NOW + 10 * 60_000);
    expect(ids(sqlite, 'oauthPending', 'id')).toHaveLength(5);
    expect(log).not.toHaveBeenCalled();

    await runOAuthCleanup(database, NOW);
    expect(ids(sqlite, 'oauthPending', 'id')).toHaveLength(3);
    expect(log).toHaveBeenCalledWith(
      JSON.stringify({ event: 'oauth.cleanup', pending: 2, code: 1, refresh: 2, emailCode: 2 }),
    );
  });

  it('never throws: a failing cleanup is logged as a warning', async () => {
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => {});
    const broken = {
      delete: () => {
        throw new Error('D1 unavailable');
      },
    } as unknown as DatabaseClient;
    await expect(runOAuthCleanup(broken, NOW)).resolves.toBeUndefined();
    expect(warn).toHaveBeenCalledWith(JSON.stringify({ event: 'oauth.cleanup.failed', error: 'D1 unavailable' }));
  });
});
