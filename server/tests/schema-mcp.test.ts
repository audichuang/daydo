import { describe, expect, it } from 'vitest';
import { createTestD1 } from './sqliteD1';

type Row = Record<string, unknown>;

function columns(sqlite: ReturnType<typeof createTestD1>['sqlite'], table: string): string[] {
  return (sqlite.prepare(`PRAGMA table_info(${table})`).all() as Row[]).map((r) => r.name as string);
}

function pk(sqlite: ReturnType<typeof createTestD1>['sqlite'], table: string): string[] {
  return (sqlite.prepare(`PRAGMA table_info(${table})`).all() as Row[])
    .filter((r) => (r.pk as number) > 0)
    .sort((a, b) => (a.pk as number) - (b.pk as number))
    .map((r) => r.name as string);
}

function indexed(sqlite: ReturnType<typeof createTestD1>['sqlite'], table: string): string[][] {
  const idx = sqlite.prepare(`PRAGMA index_list(${table})`).all() as Row[];
  return idx.map((i) =>
    (sqlite.prepare(`PRAGMA index_info(${i.name as string})`).all() as Row[]).map((c) => c.name as string),
  );
}

describe('OAuth and ICS tables (spec/mcp.md 4.2, 9.2)', () => {
  const { sqlite } = createTestD1();

  it('oauthClient has ipHash and an (ipHash, createdAt) index', () => {
    expect(columns(sqlite, 'oauthClient')).toEqual(
      expect.arrayContaining(['clientId', 'clientName', 'redirectUris', 'ipHash', 'createdAt']),
    );
    expect(pk(sqlite, 'oauthClient')).toEqual(['clientId']);
    expect(indexed(sqlite, 'oauthClient')).toContainEqual(['ipHash', 'createdAt']);
  });

  it('oauthPending has bind and consent hashes', () => {
    expect(columns(sqlite, 'oauthPending')).toEqual(
      expect.arrayContaining([
        'id', 'clientId', 'redirectUri', 'codeChallenge', 'scope', 'clientState', 'resource',
        'bindHash', 'provider', 'nonce', 'userId', 'consentTokenHash', 'createdAt', 'expiresAt', 'consumedAt',
      ]),
    );
    expect(pk(sqlite, 'oauthPending')).toEqual(['id']);
  });

  it('oauthCode is keyed by codeHash', () => {
    expect(columns(sqlite, 'oauthCode')).toEqual(
      expect.arrayContaining([
        'codeHash', 'clientId', 'redirectUri', 'codeChallenge', 'scope', 'resource',
        'userId', 'familyId', 'expiresAt', 'usedAt',
      ]),
    );
    expect(pk(sqlite, 'oauthCode')).toEqual(['codeHash']);
  });

  it('oauthRefresh keyed by refreshHash with replacedBy, no successorSealed, familyId index', () => {
    const cols = columns(sqlite, 'oauthRefresh');
    expect(cols).toEqual(
      expect.arrayContaining([
        'refreshHash', 'familyId', 'userId', 'clientId', 'scope', 'resource',
        'createdAt', 'expiresAt', 'revokedAt', 'replacedBy',
      ]),
    );
    expect(cols).not.toContain('successorSealed');
    expect(pk(sqlite, 'oauthRefresh')).toEqual(['refreshHash']);
    expect(indexed(sqlite, 'oauthRefresh')).toContainEqual(['familyId']);
  });

  it('icsSource has integer autoincrement id and userId index', () => {
    expect(columns(sqlite, 'icsSource')).toEqual(
      expect.arrayContaining([
        'id', 'userId', 'name', 'url', 'projectId', 'enabled', 'syncIntervalSec', 'filterJson',
        'timezone', 'lastSyncAt', 'lastStatus', 'lastStats', 'leaseToken', 'leaseUntilMs',
        'createdAt', 'updatedAt',
      ]),
    );
    sqlite.exec(
      "INSERT INTO icsSource (userId,name,url,projectId,createdAt,updatedAt) VALUES ('u','a','https://x','p',1,1)",
    );
    sqlite.exec(
      "INSERT INTO icsSource (userId,name,url,projectId,createdAt,updatedAt) VALUES ('u','b','https://y','p',1,1)",
    );
    const rows = sqlite.prepare('SELECT id, syncIntervalSec, enabled FROM icsSource ORDER BY id').all() as Row[];
    expect(rows.map((r) => r.id)).toEqual([1, 2]);
    expect(rows[0].syncIntervalSec).toBe(900);
    expect(indexed(sqlite, 'icsSource')).toContainEqual(['userId']);
  });

  it('icsMapping has composite primary key and sourceId index', () => {
    expect(columns(sqlite, 'icsMapping')).toEqual(
      expect.arrayContaining([
        'sourceId', 'icsUid', 'occurrenceId', 'taskId', 'projectId', 'fingerprint', 'sequence',
        'dtstamp', 'state', 'seriesSignature', 'lastError', 'updatedAt',
      ]),
    );
    expect(pk(sqlite, 'icsMapping')).toEqual(['sourceId', 'icsUid', 'occurrenceId']);
    expect(indexed(sqlite, 'icsMapping')).toContainEqual(['sourceId']);
  });
});
