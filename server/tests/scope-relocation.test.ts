import { readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import type { DurableObject } from 'cloudflare:workers';
import { eq } from 'drizzle-orm';
import { describe, expect, it } from 'vitest';
import * as schema from '../db/schema';
import type { Scope } from '../durable-objects/scope';
import { syncDueSources, syncSource } from '../src/ics/engine';
import { D1IcsStore } from '../src/ics/store';
import { handleToolCall } from '../src/mcp/registry';
import type { ScopeImportPageInput, ScopeRelocationStub, ScopeStub } from '../src/scope/api';
import { isScopeRelocatingError, listRelocationTables } from '../src/scope/relocation';
import { ensureScopeSchema, RELOCATION_PURGED_TABLE, RELOCATION_STATE_TABLE } from '../src/scope/schema';
import { Sha256, sha256HexSync } from '../src/scope/sha256';
import { acceptInvite, createInvite } from '../src/sharing';
import { ScopeClass } from './helpers/scopeWorld';
import { createServerHarness, deviceOp, NOW_ISH, projectRow, seedBasic, taskRow } from './helpers/serverHarness';
import { createTestDoState } from './sqliteD1';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

async function webCryptoSha256Hex(text: string): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text));
  return Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, '0')).join('');
}

describe('synchronous SHA-256', () => {
  it('matches Web Crypto SHA-256 across empty, block-boundary, UTF-8, and chunked inputs', async () => {
    const samples = [
      '',
      'abc',
      'a'.repeat(55),
      'a'.repeat(56),
      'a'.repeat(63),
      'a'.repeat(64),
      'a'.repeat(65),
      'b'.repeat(128),
      'DayDo 東京搬家測試 🚀 日本語'.repeat(17),
    ];
    for (const s of samples) {
      expect(sha256HexSync(s)).toBe(await webCryptoSha256Hex(s));
    }

    // Streaming chunks of varying sizes
    const longText = samples.join('\n');
    const bytes = new TextEncoder().encode(longText);
    const hasher = new Sha256();
    for (let i = 0; i < bytes.length; i += 13) {
      hasher.update(bytes.subarray(i, Math.min(i + 13, bytes.length)));
    }
    expect(hasher.hex()).toBe(await webCryptoSha256Hex(longText));
  });
});

describe('table coverage', () => {
  it('covers every table created by ensureScopeSchema except relocationState', () => {
    const schemaSrc = readFileSync(path.resolve(__dirname, '../src/scope/schema.ts'), 'utf8');
    const createdTables = [...schemaSrc.matchAll(/CREATE TABLE IF NOT EXISTS\s+(\w+)/g)]
      .map((m) => m[1])
      .sort();
    expect(createdTables.length).toBeGreaterThan(10);
    expect(createdTables).toContain(RELOCATION_STATE_TABLE);

    expect(createdTables).toContain(RELOCATION_PURGED_TABLE);
    const expected = createdTables.filter((t) => t !== RELOCATION_STATE_TABLE && t !== RELOCATION_PURGED_TABLE);
    const doState = createTestDoState();
    const scope = new ScopeClass(doState.ctx, { SYNC_FAULT: 'none' });

    const listed = listRelocationTables(doState.ctx.storage.sql);
    expect(listed).toEqual(expected);
    expect(Object.keys(scope.relocationStatus().tables).sort()).toEqual(expected);
    expect(Object.keys(scope.digest().tables).sort()).toEqual(expected);
  });

  it('excludes _cf_* and __miniflare_* internal tables, includes sqlite_sequence when AUTOINCREMENT exists, and picks up new tables', () => {
    const doState = createTestDoState();
    ensureScopeSchema(doState.ctx.storage.sql);
    doState.sqlite.exec('CREATE TABLE _cf_KV (key TEXT PRIMARY KEY, value BLOB)');
    doState.sqlite.exec('CREATE TABLE __miniflare_do_name (name TEXT)');
    doState.sqlite.exec('CREATE TABLE extraData (id INTEGER PRIMARY KEY AUTOINCREMENT, label TEXT)');

    const listed = listRelocationTables(doState.ctx.storage.sql);
    expect(listed).not.toContain('_cf_KV');
    expect(listed).not.toContain('__miniflare_do_name');
    expect(listed).not.toContain(RELOCATION_STATE_TABLE);
    expect(listed).toContain('extraData');
    expect(listed).toContain('sqlite_sequence');
  });
});

describe('Scope DO relocation round trip and continuity', () => {
  it('round-trips every entity type, tombstones, departures, opApplied, purgedProject, and shared project across paged export/import', async () => {
    const h = createServerHarness();
    const { world, db, deviceHlc } = h;
    await db.insert(schema.user).values([
      { id: 'u-a', name: 'Alice', initial: 'A', color: '#007AFF', avatarUrl: null, createdAt: NOW_ISH },
      { id: 'u-b', name: 'Bob', initial: 'B', color: '#34C759', avatarUrl: null, createdAt: NOW_ISH },
    ]);

    const memberOp = deviceOp(h, 'member', {
      id: 'm-a',
      name: 'Alice',
      initial: 'A',
      color: '#007AFF',
      isMe: true,
      createdAt: NOW_ISH,
      updatedAt: NOW_ISH,
    });
    const folderOp = deviceOp(h, 'folder', {
      id: 'f-1',
      name: 'Work',
      sortKey: 'a0',
      createdAt: NOW_ISH,
      updatedAt: NOW_ISH,
    });
    const inboxOp = deviceOp(h, 'project', projectRow('inbox-a', { isInbox: true, ownerId: 'm-a' }));
    const sharedProjOp = deviceOp(h, 'project', projectRow('p-shared', { ownerId: 'm-a', folderId: 'f-1' }));
    const otherProjOp = deviceOp(h, 'project', projectRow('p-other', { ownerId: 'm-a' }));
    const purgeProjOp = deviceOp(h, 'project', projectRow('p-purge', { ownerId: 'm-a' }));
    const tagRow = {
      name: 'urgent',
      label: 'Urgent',
      color: '#FF3B30',
      sortKey: 'a0',
      createdAt: NOW_ISH,
      updatedAt: NOW_ISH,
    };
    const tagOp = {
      opId: 'dev-tag-urgent',
      hlc: deviceHlc(),
      entity: 'tag',
      entityId: 'urgent',
      op: 'upsert',
      fields: Object.keys(tagRow),
      row: tagRow,
    };

    const seed1 = await world.push('u-a', 'dev-a', [
      memberOp,
      folderOp,
      inboxOp,
      sharedProjOp,
      otherProjOp,
      purgeProjOp,
      tagOp,
    ]);
    expect(seed1.results.every((r) => r.status === 'applied')).toBe(true);

    // Share p-shared with u-b so projectMember row exists in u:u-a
    const inv = await createInvite(db, { userId: 'u-a', projectId: 'p-shared', role: 'editor', nowMs: NOW_ISH });
    await acceptInvite(db, { code: inv.code, userId: 'u-b', getScopeStub: world.getScopeStub, nowMs: NOW_ISH });

    // Tasks (live, soft-deleted, to-be-moved, to-be-purged, and one in p-purge) + children
    const taskOps = [
      deviceOp(h, 'task', taskRow('t-live', 'p-shared', { title: 'Live task', tags: ['urgent'] })),
      deviceOp(h, 'task', taskRow('t-trashed', 'p-shared', { title: 'Trashed', deletedAt: NOW_ISH + 5 })),
      deviceOp(h, 'task', taskRow('t-move', 'p-shared', { title: 'Will move' })),
      deviceOp(h, 'task', taskRow('t-del', 'p-shared', { title: 'Will hard delete' })),
      deviceOp(h, 'task', taskRow('t-in-purge', 'p-purge', { title: 'In purged list' })),
      deviceOp(h, 'checklistItem', {
        id: 'ci-1',
        taskId: 't-live',
        title: 'Subitem 1',
        status: 0,
        sortKey: 'a0',
        createdAt: NOW_ISH,
        updatedAt: NOW_ISH,
      }),
      deviceOp(h, 'attachment', {
        id: 'att-1',
        taskId: 't-live',
        fileName: 'photo.png',
        size: 1234,
        mimeType: 'image/png',
        createdAt: NOW_ISH,
        updatedAt: NOW_ISH,
      }),
      deviceOp(h, 'comment', {
        id: 'cm-1',
        taskId: 't-live',
        authorId: 'm-a',
        body: 'Looks good',
        createdAt: NOW_ISH,
        updatedAt: NOW_ISH,
      }),
    ];
    const seed2 = await world.push('u-a', 'dev-a', taskOps);
    expect(seed2.results.every((r) => r.status === 'applied')).toBe(true);

    // Move t-move from p-shared -> p-other (creates a departure row), hard-delete t-del (tombstone),
    // and hard-delete p-purge (purgedProject + tombstones)
    const moveAndPurge = await world.push('u-a', 'dev-a', [
      {
        opId: 'op-move-t',
        hlc: deviceHlc(),
        entity: 'task',
        entityId: 't-move',
        op: 'upsert',
        fields: ['projectId', 'updatedAt'],
        row: { projectId: 'p-other', updatedAt: NOW_ISH + 10 },
      },
      {
        opId: 'op-del-t',
        hlc: deviceHlc(),
        entity: 'task',
        entityId: 't-del',
        op: 'delete',
        fields: [],
        row: {},
      },
      {
        opId: 'op-del-p',
        hlc: deviceHlc(),
        entity: 'project',
        entityId: 'p-purge',
        op: 'delete',
        fields: [],
        row: {},
      },
    ]);
    expect(moveAndPurge.results.every((r) => r.status === 'applied')).toBe(true);

    // Also seed a projectInvite row directly in SQLite so all 14 tables have rows.
    const oldSqlite = world.scopeSqlites.get('u:u-a')!;
    oldSqlite
      .prepare(
        `INSERT INTO projectInvite (id, projectId, email, role, status, createdAt, updatedAt, deletedAt, clocks, serverSeq, purgedAt)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      )
      .run('pi-1', 'p-shared', 'friend@example.com', 'editor', 'pending', NOW_ISH, NOW_ISH, null, '{}', 1, null);

    const oldPhysical = 'u:u-a';
    const newPhysical = 'u:u-a:nrt1';
    const oldStub = world.getPhysicalScopeStub(oldPhysical);
    const newStub = world.getPhysicalScopeStub(newPhysical);

    // Pull baseline from old DO before freeze (also finishes any initial member projections)
    const oldPull = await world.pull('u-a', { limit: 1000 });

    const statusBefore = await oldStub.relocationStatus();
    expect(statusBefore.state).toBe('live');
    expect(statusBefore.maxServerSeq).toBeGreaterThan(0);
    expect(statusBefore.counter).toEqual([{ id: 1, value: statusBefore.maxServerSeq }]);
    for (const [table, count] of Object.entries(statusBefore.tables)) {
      expect(count, `table ${table} should be seeded`).toBeGreaterThan(0);
    }

    // 1. Freeze old DO
    expect(await oldStub.setRelocationState({ state: 'frozen', expect: 'live' })).toEqual({
      previous: 'live',
      state: 'frozen',
    });

    // 2. Begin import on empty new DO
    expect(await newStub.setRelocationState({ state: 'importing', expect: 'live' })).toEqual({
      previous: 'live',
      state: 'importing',
    });

    // 3. Export all pages with small maxChars to force multi-page export, import into new DO
    let multiPageTables = 0;
    for (const table of Object.keys(statusBefore.tables).sort()) {
      let afterRowid = 0;
      let pages = 0;
      while (true) {
        const page = await oldStub.exportPage({ table, afterRowid, maxChars: 350 });
        pages += 1;
        if (page.rows.length > 0) {
          const imp = await newStub.importPage({ table, rows: page.rows });
          expect(imp.imported).toBe(page.rows.length);
        }
        if (page.done) break;
        expect(page.nextAfterRowid).toBeGreaterThan(afterRowid);
        afterRowid = page.nextAfterRowid;
      }
      if (pages > 1) multiPageTables += 1;
    }
    expect(multiPageTables).toBeGreaterThan(0);

    // 4. Compare digests BEFORE finishing import
    const oldDigest = await oldStub.digest();
    const newDigest = await newStub.digest();
    expect(oldDigest.state).toBe('frozen');
    expect(newDigest.state).toBe('importing');
    expect(newDigest.tables).toEqual(oldDigest.tables);

    // 5. Finish import on new DO with expectDigest
    expect(
      await newStub.setRelocationState({
        state: 'live',
        expect: 'importing',
        expectDigest: oldDigest.tables,
      }),
    ).toEqual({
      previous: 'importing',
      state: 'live',
    });

    // 6. Switch logical -> physical routing and verify full pull equals old DO row for row
    world.physicalNames.set('u:u-a', newPhysical);
    const newPull = await world.pull('u-a', { limit: 1000 });
    expect(newPull).toEqual(oldPull);

    // 7. Continuity: new push gets serverSeq > old max, and re-sending old opId is deduplicated
    const prevMaxSeq = statusBefore.maxServerSeq;
    const replayRes = await world.push('u-a', 'dev-a', [taskOps[0]]);
    expect(replayRes.results[0].status).toBe('applied');
    expect(replayRes.results[0].row?.id).toBe('t-live');
    expect((await newStub.relocationStatus()).counter[0].value).toBe(prevMaxSeq);

    const freshOp = deviceOp(h, 'task', taskRow('t-after', 'p-shared', { title: 'After relocation' }));
    const afterRes = await world.push('u-a', 'dev-a', [freshOp]);
    expect(afterRes.results[0].status).toBe('applied');
    const afterStatus = await newStub.relocationStatus();
    expect(afterStatus.maxServerSeq).toBeGreaterThan(prevMaxSeq);
    expect(afterStatus.counter[0].value).toBe(afterStatus.maxServerSeq);
  });

  it('produces identical digests when old DO has task.countdown appended via ALTER TABLE', async () => {
    const oldState = createTestDoState();
    // Create task table WITHOUT countdown first, mimicking a legacy production DO.
    oldState.sqlite.exec(`
      CREATE TABLE task (
        id TEXT PRIMARY KEY NOT NULL,
        projectId TEXT NOT NULL,
        title TEXT NOT NULL,
        content TEXT NOT NULL DEFAULT '',
        priority INTEGER NOT NULL DEFAULT 0,
        status INTEGER NOT NULL DEFAULT 0,
        startDay TEXT,
        startMinute INTEGER,
        endDay TEXT,
        endMinute INTEGER,
        timeZone TEXT,
        reminders TEXT NOT NULL DEFAULT '[]',
        repeatRule TEXT,
        tags TEXT NOT NULL DEFAULT '[]',
        assigneeId TEXT,
        sortKey TEXT NOT NULL,
        completedAt INTEGER,
        sourceRaw TEXT,
        importNote TEXT,
        createdAt INTEGER NOT NULL,
        updatedAt INTEGER NOT NULL,
        deletedAt INTEGER,
        clocks TEXT NOT NULL DEFAULT '{}',
        serverSeq INTEGER NOT NULL,
        purgedAt INTEGER
      );
    `);
    const oldScope = new ScopeClass(oldState.ctx, { SYNC_FAULT: 'none' });
    // Verify countdown is indeed at the end on old DO
    const oldCols = oldState.sqlite.prepare('PRAGMA table_info(task)').all().map((r: any) => r.name);
    expect(oldCols[oldCols.length - 1]).toBe('countdown');

    const freshState = createTestDoState();
    const freshScope = new ScopeClass(freshState.ctx, { SYNC_FAULT: 'none' });
    const freshCols = freshState.sqlite.prepare('PRAGMA table_info(task)').all().map((r: any) => r.name);
    expect(freshCols[freshCols.length - 1]).not.toBe('countdown');

    // Push a task to oldScope
    await oldScope.push({
      scope: 'u:u-a',
      scopeUserId: 'u-a',
      pusherUserId: 'u-a',
      deviceId: 'dev-a',
      memberships: { p1: 'owner' },
      purgedProjects: [],
      meMemberId: null,
      ops: [
        {
          opId: 'op-1',
          hlc: `${Date.now()}:0000:dev-a`,
          entity: 'task',
          entityId: 't1',
          op: 'upsert',
          fields: ['id', 'projectId', 'title', 'sortKey', 'createdAt', 'updatedAt', 'countdown'],
          row: {
            id: 't1',
            projectId: 'p1',
            title: 'Legacy schema task',
            sortKey: 'a0',
            createdAt: NOW_ISH,
            updatedAt: NOW_ISH,
            countdown: true,
          },
        },
      ],
    });

    oldScope.setRelocationState({ state: 'frozen', expect: 'live' });
    freshScope.setRelocationState({ state: 'importing', expect: 'live' });
    for (const table of Object.keys(oldScope.relocationStatus().tables)) {
      const page = oldScope.exportPage({ table });
      if (page.rows.length > 0) {
        freshScope.importPage({ table, rows: page.rows });
      }
    }
    expect(freshScope.digest().tables).toEqual(oldScope.digest().tables);
  });
});

describe('Scope DO frozen, importing, and state machine rules', () => {
  it('blocks every write method when frozen and skips pull member reconciliation while returning data', async () => {
    const doState = createTestDoState();
    const scope = new ScopeClass(doState.ctx, { SYNC_FAULT: 'none' }, true);
    const hlc = `${Date.now()}:0000:dev-a`;

    // Seed a project and attachment
    const p1Row = projectRow('p1', { isInbox: true, ownerId: 'm-a' });
    const t1Row = taskRow('t1', 'p1');
    const a1Row = {
      id: 'a1',
      taskId: 't1',
      fileName: 'doc.pdf',
      size: 100,
      mimeType: 'application/pdf',
      createdAt: NOW_ISH,
      updatedAt: NOW_ISH,
    };
    const seeded = await scope.push({
      scope: 'u:u-a',
      scopeUserId: 'u-a',
      pusherUserId: 'u-a',
      deviceId: 'dev-a',
      memberships: { p1: 'owner' },
      purgedProjects: [],
      meMemberId: null,
      ops: [
        {
          opId: 'op-p1',
          hlc,
          entity: 'project',
          entityId: 'p1',
          op: 'upsert',
          fields: Object.keys(p1Row),
          row: p1Row,
        },
        {
          opId: 'op-t1',
          hlc: `${Date.now()}:0001:dev-a`,
          entity: 'task',
          entityId: 't1',
          op: 'upsert',
          fields: Object.keys(t1Row),
          row: t1Row,
        },
        {
          opId: 'op-a1',
          hlc: `${Date.now()}:0002:dev-a`,
          entity: 'attachment',
          entityId: 'a1',
          op: 'upsert',
          fields: Object.keys(a1Row),
          row: a1Row,
        },
      ],
    });
    expect(seeded.results.map((r) => r.status)).toEqual(['applied', 'applied', 'applied']);

    scope.setRelocationState({ state: 'frozen', expect: 'live' });
    const digestFrozen = scope.digest().tables;

    // 1. push refused
    await expect(
      scope.push({
        scope: 'u:u-a',
        scopeUserId: 'u-a',
        pusherUserId: 'u-a',
        deviceId: 'dev-a',
        memberships: { p1: 'owner' },
        purgedProjects: [],
        meMemberId: null,
        ops: [],
      }),
    ).rejects.toSatisfy((err: unknown) => isScopeRelocatingError(err));

    // 2. projectMember refused
    let pmErr: unknown;
    try {
      scope.projectMember({ projectId: 'p1', memberId: 'm-b', role: 'editor', deleted: false });
    } catch (e) {
      pmErr = e;
    }
    expect(isScopeRelocatingError(pmErr)).toBe(true);

    // 3. purgeProject refused
    let purgeErr: unknown;
    try {
      scope.purgeProject({ projectId: 'p1', purgedAt: NOW_ISH + 1 });
    } catch (e) {
      purgeErr = e;
    }
    expect(isScopeRelocatingError(purgeErr)).toBe(true);

    // 4. split-txn dev push refused too
    const splitScope = new ScopeClass(doState.ctx, { SYNC_FAULT: 'split-txn' }, true);
    await expect(
      splitScope.push({
        scope: 'u:u-a',
        scopeUserId: 'u-a',
        pusherUserId: 'u-a',
        deviceId: 'dev-a',
        memberships: { p1: 'owner' },
        purgedProjects: [],
        meMemberId: null,
        ops: [],
      }),
    ).rejects.toSatisfy((err: unknown) => isScopeRelocatingError(err));

    // 5. Read-only queries still work while frozen
    expect(scope.getInboxProjectId({ readableProjectIds: ['p1'] })).toBe('p1');
    expect(scope.getProjectInfo({ projectId: 'p1' })?.name).toBe('p1');
    expect(scope.getAttachmentInfo({ attachmentId: 'a1' })?.mimeType).toBe('application/pdf');

    // 6. pull returns data AND skips reconcileProjectMembers (writes nothing!)
    const pulled = scope.pull({
      scope: 'u:u-a',
      scopeUserId: 'u-a',
      requesterUserId: 'u-a',
      since: 0,
      limit: 500,
      memberships: { p1: 'owner' },
      meMemberId: 'm-a',
      expectedProjectMembers: { p1: [{ memberId: 'm-b', role: 'editor' }] },
    });
    expect(pulled.rows.length).toBe(3);
    expect(scope.relocationStatus().tables.projectMember).toBe(0);
    expect(scope.digest().tables).toEqual(digestFrozen);

    // 7. Unfreeze re-enables reconcileProjectMembers on pull
    scope.setRelocationState({ state: 'live', expect: 'frozen' });
    scope.pull({
      scope: 'u:u-a',
      scopeUserId: 'u-a',
      requesterUserId: 'u-a',
      since: 0,
      limit: 500,
      memberships: { p1: 'owner' },
      meMemberId: 'm-a',
      expectedProjectMembers: { p1: [{ memberId: 'm-b', role: 'editor' }] },
    });
    expect(scope.relocationStatus().tables.projectMember).toBe(1);
  });

  it('refuses every normal read and write method when importing', async () => {
    const doState = createTestDoState();
    const scope = new ScopeClass(doState.ctx, { SYNC_FAULT: 'none' });
    scope.setRelocationState({ state: 'importing', expect: 'live' });

    await expect(
      scope.push({
        scope: 'u:u-a',
        scopeUserId: 'u-a',
        pusherUserId: 'u-a',
        deviceId: 'dev-a',
        memberships: {},
        purgedProjects: [],
        meMemberId: null,
        ops: [],
      }),
    ).rejects.toSatisfy((err: unknown) => isScopeRelocatingError(err));

    const syncCalls: Array<() => unknown> = [
      () =>
        scope.pull({
          scope: 'u:u-a',
          scopeUserId: 'u-a',
          requesterUserId: 'u-a',
          since: 0,
          limit: 500,
          memberships: {},
          meMemberId: null,
        }),
      () => scope.getInboxProjectId({ readableProjectIds: ['p1'] }),
      () => scope.getProjectInfo({ projectId: 'p1' }),
      () => scope.getAttachmentInfo({ attachmentId: 'a1' }),
      () => scope.projectMember({ projectId: 'p1', memberId: 'm1', role: 'editor', deleted: false }),
      () => scope.purgeProject({ projectId: 'p1', purgedAt: NOW_ISH }),
    ];

    for (const fn of syncCalls) {
      let caught: unknown;
      try {
        fn();
      } catch (e) {
        caught = e;
      }
      expect(isScopeRelocatingError(caught)).toBe(true);
    }

    // exportPage is refused during importing, while status/digest work
    expect(() => scope.exportPage({ table: 'task' })).toThrow(/requires state 'frozen'/);
    expect(scope.relocationStatus().state).toBe('importing');
    expect(scope.digest().state).toBe('importing');
  });

  it('enforces state machine transitions, empty check on begin-import, and table/column validation', () => {
    const doState = createTestDoState();
    const scope = new ScopeClass(doState.ctx, { SYNC_FAULT: 'none' });

    // expect mismatch
    expect(() => scope.setRelocationState({ state: 'frozen', expect: 'frozen' })).toThrow(/mismatch/);
    // illegal transitions from live
    expect(() => scope.setRelocationState({ state: 'live', expect: 'live' })).toThrow(/Illegal/);
    // export/import in live
    expect(() => scope.exportPage({ table: 'task' })).toThrow(/frozen/);
    expect(() => scope.importPage({ table: 'task', rows: [] })).toThrow(/importing/);

    // live -> frozen -> importing is illegal
    scope.setRelocationState({ state: 'frozen', expect: 'live' });
    expect(() => scope.setRelocationState({ state: 'importing', expect: 'frozen' })).toThrow(/Illegal/);
    expect(() => scope.exportPage({ table: 'unknownTable' })).toThrow(/Unknown/);
    expect(() => scope.exportPage({ table: RELOCATION_STATE_TABLE })).toThrow(/Unknown/);
    scope.setRelocationState({ state: 'live', expect: 'frozen' });

    // Non-empty DO refuses live -> importing (even with only counter populated)
    doState.sqlite.prepare('INSERT INTO counter (id, value) VALUES (1, 5)').run();
    expect(() => scope.setRelocationState({ state: 'importing', expect: 'live' })).toThrow(/non-empty/);

    // Empty DO accepts live -> importing; importing -> frozen is illegal
    doState.sqlite.prepare('DELETE FROM counter').run();
    scope.setRelocationState({ state: 'importing', expect: 'live' });
    expect(() => scope.setRelocationState({ state: 'frozen', expect: 'importing' })).toThrow(/Illegal/);

    // Unknown table, relocationState, unknown column rejected in importPage
    expect(() => scope.importPage({ table: 'noSuchTable', rows: [] })).toThrow(/Unknown/);
    expect(() => scope.importPage({ table: RELOCATION_STATE_TABLE, rows: [] })).toThrow(/Unknown/);
    expect(() =>
      scope.importPage({
        table: 'tag',
        rows: [{ rowid: 1, values: { name: 't', bogusCol: 'x' } }],
      }),
    ).toThrow(/Unknown column/);
  });

  it('refuses finish-import on partial import or mismatching/missing expectDigest and leaves state importing', async () => {
    const srcState = createTestDoState();
    const src = new ScopeClass(srcState.ctx, { SYNC_FAULT: 'none' });
    const hlc = `${Date.now()}:0000:dev-a`;
    const p1 = projectRow('p1', { isInbox: true, ownerId: 'm-a' });
    const t1 = taskRow('t1', 'p1');
    await src.push({
      scope: 'u:u-a',
      scopeUserId: 'u-a',
      pusherUserId: 'u-a',
      deviceId: 'dev-a',
      memberships: { p1: 'owner' },
      purgedProjects: [],
      meMemberId: null,
      ops: [
        { opId: 'op-p1', hlc, entity: 'project', entityId: 'p1', op: 'upsert', fields: Object.keys(p1), row: p1 },
        { opId: 'op-t1', hlc: `${Date.now()}:0001:dev-a`, entity: 'task', entityId: 't1', op: 'upsert', fields: Object.keys(t1), row: t1 },
      ],
    });
    src.setRelocationState({ state: 'frozen', expect: 'live' });
    const srcDigest = src.digest().tables;

    const dstState = createTestDoState();
    const dst = new ScopeClass(dstState.ctx, { SYNC_FAULT: 'none' });
    dst.setRelocationState({ state: 'importing', expect: 'live' });

    // Partial import: copy only project (skip task, counter, opApplied)
    const projPage = src.exportPage({ table: 'project' });
    dst.importPage({ table: 'project', rows: projPage.rows });

    // Missing expectDigest -> refused, stays importing
    expect(() => dst.setRelocationState({ state: 'live', expect: 'importing' })).toThrow(/expectDigest/);
    expect(dst.relocationStatus().state).toBe('importing');

    // Partial import against source digest -> refused, stays importing
    expect(() =>
      dst.setRelocationState({ state: 'live', expect: 'importing', expectDigest: srcDigest }),
    ).toThrow(/Digest mismatch/);
    expect(dst.relocationStatus().state).toBe('importing');

    // Copy remaining tables
    for (const table of Object.keys(srcDigest)) {
      if (table === 'project') continue;
      const page = src.exportPage({ table });
      if (page.rows.length > 0) dst.importPage({ table, rows: page.rows });
    }

    // Wrong hash in expectDigest -> refused, stays importing
    expect(() =>
      dst.setRelocationState({
        state: 'live',
        expect: 'importing',
        expectDigest: { ...srcDigest, task: { count: srcDigest.task.count, sha256: '0'.repeat(64) } },
      }),
    ).toThrow(/Digest mismatch/);
    expect(dst.relocationStatus().state).toBe('importing');

    // Missing table in expectDigest -> refused, stays importing
    const { task: _omitted, ...missingTask } = srcDigest;
    expect(() =>
      dst.setRelocationState({ state: 'live', expect: 'importing', expectDigest: missingTask }),
    ).toThrow(/Digest mismatch/);
    expect(dst.relocationStatus().state).toBe('importing');

    // Extra table in expectDigest -> refused, stays importing
    expect(() =>
      dst.setRelocationState({
        state: 'live',
        expect: 'importing',
        expectDigest: { ...srcDigest, ghostTable: { count: 0, sha256: 'abc' } },
      }),
    ).toThrow(/Digest mismatch/);
    expect(dst.relocationStatus().state).toBe('importing');

    // Matching expectDigest -> succeeds and transitions importing -> live
    expect(
      dst.setRelocationState({ state: 'live', expect: 'importing', expectDigest: srcDigest }),
    ).toEqual({ previous: 'importing', state: 'live' });
    expect(dst.relocationStatus().state).toBe('live');
  });
});

describe('MCP tools and ICS cron behavior while a scope is relocating', () => {
  it('MCP tools return an isError retry-shortly message when scope is frozen or importing', async () => {
    const h = createServerHarness();
    await seedBasic(h);
    const ctx = h.toolContext('u-a');

    // Freeze: read works, write returns retry-shortly tool error
    const stub = h.world.getPhysicalScopeStub('u:u-a');
    await stub.setRelocationState({ state: 'frozen', expect: 'live' });

    const listWhileFrozen = await handleToolCall('list_projects', {}, ctx);
    expect(listWhileFrozen.isError).toBeUndefined();

    const writeWhileFrozen = await handleToolCall(
      'create_task',
      { project_id: 'inbox-u-a', title: 'Blocked while frozen' },
      ctx,
    );
    expect(writeWhileFrozen.isError).toBe(true);
    expect(writeWhileFrozen.content[0]).toEqual({
      type: 'text',
      text: expect.stringMatching(/relocating.*retry/i),
    });

    // Importing (new empty DO mapped in): read also returns retry-shortly tool error
    const newStub = h.world.getPhysicalScopeStub('u:u-a:nrt1');
    await newStub.setRelocationState({ state: 'importing', expect: 'live' });
    h.world.physicalNames.set('u:u-a', 'u:u-a:nrt1');

    const listWhileImporting = await handleToolCall('list_projects', {}, ctx);
    expect(listWhileImporting.isError).toBe(true);
    expect(listWhileImporting.content[0]).toEqual({
      type: 'text',
      text: expect.stringMatching(/relocating.*retry/i),
    });
  });

  it('ICS cron records per-source error while frozen or importing, marks nothing permanently failed, and succeeds after unfreeze', async () => {
    const h = createServerHarness();
    await seedBasic(h);
    const store = new D1IcsStore(h.db);
    const source = await store.addSource('u-a', {
      name: 'Calendar',
      url: 'https://cal.example/feed.ics',
      projectId: 'p1',
    });

    const icsBody = [
      'BEGIN:VCALENDAR',
      'VERSION:2.0',
      'BEGIN:VEVENT',
      'UID:ev-relocate-1',
      'DTSTART:20261120T090000Z',
      'DTEND:20261120T100000Z',
      'SUMMARY:Relocation sync event',
      'END:VEVENT',
      'END:VCALENDAR',
    ].join('\r\n');

    const fetchOptions = {
      fetch: (async () => new Response(icsBody, { status: 200 })) as typeof fetch,
    };
    const deps = {
      store,
      db: h.db,
      getScopeStub: h.world.getScopeStub,
      clock: h.world.clock,
      fetchOptions,
    };

    const runNow = Date.parse('2026-11-19T12:00:00Z');

    // 1. Frozen scope: pull succeeds, push throws ScopeRelocatingError -> recorded as per-source error
    await h.world.getPhysicalScopeStub('u:u-a').setRelocationState({ state: 'frozen', expect: 'live' });
    const dueFrozen = await syncDueSources(deps, runNow);
    expect(dueFrozen).toHaveLength(1);
    expect(dueFrozen[0].stats.errors).toBeGreaterThan(0);
    expect(dueFrozen[0].stats.created).toBe(0);

    const srcAfterFrozen = await store.getSource('u-a', source.id);
    expect(srcAfterFrozen?.enabled).toBe(true);
    expect(srcAfterFrozen?.lastStatus).toBe('partial');

    const mappingsAfterFrozen = await store.listMappings('u-a', source.id);
    expect(mappingsAfterFrozen).toHaveLength(1);
    expect(mappingsAfterFrozen[0].state).toBe('pending');
    expect(mappingsAfterFrozen[0].state).not.toBe('purged');

    // 2. Importing scope: loadSnapshot fails -> recorded as per-source error, still enabled
    await h.world.getPhysicalScopeStub('u:u-a:nrt1').setRelocationState({ state: 'importing', expect: 'live' });
    h.world.physicalNames.set('u:u-a', 'u:u-a:nrt1');
    const importingStats = await syncSource(deps, 'u-a', source.id, runNow + 1_000_000);
    expect(importingStats.errors).toBe(1);
    expect(importingStats.lastError).toMatch(/SCOPE_RELOCATING/);
    const srcAfterImporting = await store.getSource('u-a', source.id);
    expect(srcAfterImporting?.enabled).toBe(true);
    expect(srcAfterImporting?.lastStatus).toBe('error');

    // 3. Unfreeze original scope and restore routing -> next run creates the task cleanly
    h.world.physicalNames.delete('u:u-a');
    await h.world.getPhysicalScopeStub('u:u-a').setRelocationState({ state: 'live', expect: 'frozen' });
    const recovered = await syncSource(deps, 'u-a', source.id, runNow + 2_000_000);
    expect(recovered.errors).toBe(0);
    expect(recovered.created).toBe(1);

    const mappingsAfterRecovery = await store.listMappings('u-a', source.id);
    expect(mappingsAfterRecovery[0].state).toBe('applied');
    expect(mappingsAfterRecovery[0].taskId).toBe(mappingsAfterFrozen[0].taskId);
  });
});

describe('D1 + Scope push retry consistency after 503', () => {
  it('stays consistent when a new project, new task, and owner project delete fail while frozen and retry on the new DO', async () => {
    const h = createServerHarness();
    await seedBasic(h);

    const oldStub = h.world.getPhysicalScopeStub('u:u-a');
    const newStub = h.world.getPhysicalScopeStub('u:u-a:nrt1');

    // Freeze old DO and copy existing state into new DO
    await oldStub.setRelocationState({ state: 'frozen', expect: 'live' });
    await newStub.setRelocationState({ state: 'importing', expect: 'live' });
    for (const table of Object.keys((await oldStub.relocationStatus()).tables)) {
      const page = await oldStub.exportPage({ table });
      if (page.rows.length > 0) {
        await newStub.importPage({ table, rows: page.rows });
      }
    }

    // Attempt 1 while old DO is frozen: creates new project p-new + task t-new + deletes existing p1
    const newProj = projectRow('p-new', { ownerId: 'm-a' });
    const newTask = taskRow('t-new', 'p-new', { title: 'Created during freeze' });
    const batch = [
      deviceOp(h, 'project', newProj),
      deviceOp(h, 'task', newTask),
      {
        opId: 'op-purge-p1',
        hlc: h.deviceHlc(),
        entity: 'project',
        entityId: 'p1',
        op: 'delete',
        fields: [],
        row: {},
      },
    ];

    await expect(h.world.push('u-a', 'dev-a', batch)).rejects.toSatisfy((err: unknown) =>
      isScopeRelocatingError(err),
    );

    // Finish relocation & flip routing to new DO
    const oldDigest = await oldStub.digest();
    await newStub.setRelocationState({
      state: 'live',
      expect: 'importing',
      expectDigest: oldDigest.tables,
    });
    h.world.physicalNames.set('u:u-a', 'u:u-a:nrt1');

    // Attempt 2: App retries the exact same batch against the new DO
    const retried = await h.world.push('u-a', 'dev-a', batch);
    expect(retried.results.map((r) => r.status)).toEqual(['applied', 'applied', 'applied']);

    // Verify new DO has p-new, t-new, and purged p1
    expect(retried.results[2].row?.purgedAt).not.toBeNull();
    expect((await newStub.relocationStatus()).tables.purgedProject).toBe(1);
    const pulled = await h.world.pull('u-a');
    const rows = pulled.scopes.flatMap((s) => s.rows);
    expect(rows.some((r) => r.entity === 'project' && 'row' in r && r.row.id === 'p-new')).toBe(true);
    expect(rows.some((r) => r.entity === 'task' && 'row' in r && r.row.id === 't-new')).toBe(true);
    expect(pulled.memberships.some((m) => m.projectId === 'p1')).toBe(false);

    // And D1 entityHome still points to logical scope u:u-a
    const homes = await h.db.select().from(schema.entityHome).where(eq(schema.entityHome.entityId, 't-new'));
    expect(homes).toEqual([{ entity: 'task', entityId: 't-new', scope: 'u:u-a' }]);
  });
});

describe('purgeFrozenData on a relocated old DO', () => {
  async function seededScope() {
    const doState = createTestDoState();
    const scope = new ScopeClass(doState.ctx, { SYNC_FAULT: 'none' }, true);
    const hlc = `${Date.now()}:0000:dev-a`;
    const res = await scope.push({
      scope: 'u:u-a',
      scopeUserId: 'u-a',
      pusherUserId: 'u-a',
      deviceId: 'dev-a',
      memberships: { p1: 'owner' },
      purgedProjects: [],
      meMemberId: null,
      ops: [
        { opId: 'op-p1', hlc, entity: 'project', entityId: 'p1', op: 'upsert', fields: Object.keys(projectRow('p1', { isInbox: true, ownerId: 'm-a' })), row: projectRow('p1', { isInbox: true, ownerId: 'm-a' }) },
        { opId: 'op-t1', hlc: `${Date.now()}:0001:dev-a`, entity: 'task', entityId: 't1', op: 'upsert', fields: Object.keys(taskRow('t1', 'p1')), row: taskRow('t1', 'p1') },
      ],
    });
    expect(res.results.every((r) => r.status === 'applied')).toBe(true);
    return scope;
  }

  it('refuses a live DO and a wrong expectMaxServerSeq, then empties a frozen DO and keeps it frozen', async () => {
    const scope = await seededScope();
    const before = scope.relocationStatus();
    expect(before.maxServerSeq).toBeGreaterThan(0);

    expect(() => scope.purgeFrozenData({ expectMaxServerSeq: before.maxServerSeq })).toThrow(/frozen/);
    scope.setRelocationState({ state: 'frozen', expect: 'live' });
    expect(() => scope.purgeFrozenData({ expectMaxServerSeq: before.maxServerSeq + 1 })).toThrow(/mismatch/);
    expect(scope.relocationStatus().tables.task).toBe(1);

    const res = scope.purgeFrozenData({ expectMaxServerSeq: before.maxServerSeq });
    expect(res.state).toBe('frozen');
    expect(res.deleted.task).toBe(1);
    expect(res.deleted.opApplied).toBeGreaterThan(0);

    const after = scope.relocationStatus();
    expect(after.state).toBe('frozen');
    expect(Object.values(after.tables).every((n) => n === 0)).toBe(true);
    expect(after.maxServerSeq).toBe(0);
    await expect(
      scope.push({ scope: 'u:u-a', scopeUserId: 'u-a', pusherUserId: 'u-a', deviceId: 'dev-a', memberships: { p1: 'owner' }, purgedProjects: [], meMemberId: null, ops: [] }),
    ).rejects.toThrow(/relocating/i);

    // A purged DO must not answer reads with an empty "complete" page, and can never be unfrozen.
    expect(() =>
      scope.pull({ scope: 'u:u-a', scopeUserId: 'u-a', requesterUserId: 'u-a', since: 0, limit: 100, memberships: { p1: 'owner' }, meMemberId: null }),
    ).toThrow(/relocating/i);
    expect(() => scope.getInboxProjectId({ readableProjectIds: ['p1'] })).toThrow(/relocating/i);
    expect(() => scope.setRelocationState({ state: 'live', expect: 'frozen' })).toThrow(/purged/);
    expect(scope.relocationStatus().state).toBe('frozen');
  });
});

describe('opLogDigest prefix proof', () => {
  it('matches between a source and its copy up to the source rowid, and differs for another log', () => {
    const a = createTestDoState();
    const b = createTestDoState();
    const c = createTestDoState();
    const insert = (st: ReturnType<typeof createTestDoState>, rowid: number, opId: string) =>
      st.sqlite.prepare('INSERT INTO opApplied (rowid, opId, userId, status, reason, serverSeq) VALUES (?, ?, ?, ?, ?, ?)').run(rowid, opId, 'u', 'applied', null, rowid);
    const sa = new ScopeClass(a.ctx, { SYNC_FAULT: 'none' });
    const sb = new ScopeClass(b.ctx, { SYNC_FAULT: 'none' });
    const sc = new ScopeClass(c.ctx, { SYNC_FAULT: 'none' });
    for (const st of [a, b]) { insert(st, 1, 'op-1'); insert(st, 2, 'op-2'); }
    insert(b, 3, 'op-3'); // the copy kept growing after cut-over
    insert(c, 1, 'other-1'); insert(c, 2, 'other-2'); insert(c, 3, 'other-3');

    const src = sa.opLogDigest({});
    expect(src).toMatchObject({ count: 2, maxRowid: 2 });
    expect(sb.opLogDigest({ maxRowid: src.maxRowid })).toEqual(src);
    expect(sb.opLogDigest({}).count).toBe(3);
    expect(sc.opLogDigest({ maxRowid: src.maxRowid }).sha256).not.toBe(src.sha256);
    expect(() => sa.opLogDigest({ maxRowid: -1 })).toThrow(/maxRowid/);
  });
});

describe('Scope DO RPC relocation policy coverage', () => {
  type StateOutcome = 'ok' | 'relocating' | 'conflict';
  type Policy = { frozen: StateOutcome; importing: StateOutcome };
  type ScopeGetStub = ReturnType<typeof Scope.get>;
  type PlatformStubKey = keyof DurableObjectStub<DurableObject> | keyof DurableObject;
  type ScopeRpcMethod = Exclude<keyof ScopeGetStub, PlatformStubKey>;
  type ScopeInstance = InstanceType<typeof ScopeClass>;
  type CallContext = { state: 'frozen' | 'importing'; importTaskPage: ScopeImportPageInput };
  type InvokeResult = { ok: true; value: unknown } | { ok: false; error: unknown };
  type ExactEqual<A, B> =
    (<T>() => T extends A ? 1 : 2) extends <T>() => T extends B ? 1 : 2 ? true : false;
  type AssertTrue<T extends true> = T;

  // Every public RPC method on Scope.get() (excluding platform DurableObject/stub members)
  // must be explicitly classified with its exact outcome in both frozen and importing states;
  // adding a method to ScopeObject fails typecheck until its relocation policy is covered.
  const POLICY = {
    push: { frozen: 'relocating', importing: 'relocating' },
    projectMember: { frozen: 'relocating', importing: 'relocating' },
    purgeProject: { frozen: 'relocating', importing: 'relocating' },
    pull: { frozen: 'ok', importing: 'relocating' },
    getInboxProjectId: { frozen: 'ok', importing: 'relocating' },
    getProjectInfo: { frozen: 'ok', importing: 'relocating' },
    getAttachmentInfo: { frozen: 'ok', importing: 'relocating' },
    relocationStatus: { frozen: 'ok', importing: 'ok' },
    setRelocationState: { frozen: 'ok', importing: 'ok' },
    exportPage: { frozen: 'ok', importing: 'conflict' },
    importPage: { frozen: 'conflict', importing: 'ok' },
    digest: { frozen: 'ok', importing: 'ok' },
    opLogDigest: { frozen: 'ok', importing: 'ok' },
    purgeFrozenData: { frozen: 'ok', importing: 'conflict' },
  } satisfies Record<ScopeRpcMethod, Policy>;

  // Compile-time type equality: POLICY keys must match both Scope.get() RPC methods and the
  // hand-written stub interfaces (catches methods added directly to ScopeObject).
  type _PolicyMatchesScopeGet = AssertTrue<ExactEqual<keyof typeof POLICY, ScopeRpcMethod>>;
  type _PolicyMatchesStubs = AssertTrue<
    ExactEqual<keyof typeof POLICY, keyof (ScopeStub & ScopeRelocationStub)>
  >;
  const _typeProof: [_PolicyMatchesScopeGet, _PolicyMatchesStubs] = [true, true];
  void _typeProof;

  const CALL: Record<ScopeRpcMethod, (scope: ScopeInstance, ctx: CallContext) => unknown> = {
    push: (scope) =>
      scope.push({
        scope: 'u:u-a',
        scopeUserId: 'u-a',
        pusherUserId: 'u-a',
        deviceId: 'dev-a',
        memberships: { p1: 'owner' },
        purgedProjects: [],
        meMemberId: null,
        ops: [],
      }),
    projectMember: (scope) =>
      scope.projectMember({ projectId: 'p1', memberId: 'm-b', role: 'editor', deleted: false }),
    purgeProject: (scope) => scope.purgeProject({ projectId: 'p1', purgedAt: NOW_ISH + 1 }),
    pull: (scope) =>
      scope.pull({
        scope: 'u:u-a',
        scopeUserId: 'u-a',
        requesterUserId: 'u-a',
        since: 0,
        limit: 500,
        memberships: { p1: 'owner' },
        meMemberId: 'm-a',
      }),
    getInboxProjectId: (scope) => scope.getInboxProjectId({ readableProjectIds: ['p1'] }),
    getProjectInfo: (scope) => scope.getProjectInfo({ projectId: 'p1' }),
    getAttachmentInfo: (scope) => scope.getAttachmentInfo({ attachmentId: 'a1' }),
    relocationStatus: (scope) => scope.relocationStatus(),
    setRelocationState: (scope, { state }) =>
      state === 'frozen'
        ? scope.setRelocationState({ state: 'live', expect: 'frozen' })
        : scope.setRelocationState({
            state: 'live',
            expect: 'importing',
            expectDigest: scope.digest().tables,
          }),
    exportPage: (scope) => scope.exportPage({ table: 'task' }),
    importPage: (scope, { importTaskPage }) => scope.importPage(importTaskPage),
    digest: (scope) => scope.digest(),
    opLogDigest: (scope) => scope.opLogDigest({}),
    purgeFrozenData: (scope) =>
      scope.purgeFrozenData({ expectMaxServerSeq: scope.relocationStatus().maxServerSeq }),
  };

  let cachedImportTaskPage: ScopeImportPageInput | undefined;

  async function getValidImportTaskPage(): Promise<ScopeImportPageInput> {
    if (cachedImportTaskPage) return cachedImportTaskPage;
    const doState = createTestDoState();
    const source = new ScopeClass(doState.ctx, { SYNC_FAULT: 'none' });
    const pRow = projectRow('p-imp', { isInbox: true, ownerId: 'm-a' });
    const tRow = taskRow('t-imp', 'p-imp', { title: 'Imported task' });
    const seeded = await source.push({
      scope: 'u:u-a',
      scopeUserId: 'u-a',
      pusherUserId: 'u-a',
      deviceId: 'dev-a',
      memberships: { 'p-imp': 'owner' },
      purgedProjects: [],
      meMemberId: null,
      ops: [
        {
          opId: 'op-imp-p',
          hlc: `${Date.now()}:0000:dev-a`,
          entity: 'project',
          entityId: 'p-imp',
          op: 'upsert',
          fields: Object.keys(pRow),
          row: pRow,
        },
        {
          opId: 'op-imp-t',
          hlc: `${Date.now()}:0001:dev-a`,
          entity: 'task',
          entityId: 't-imp',
          op: 'upsert',
          fields: Object.keys(tRow),
          row: tRow,
        },
      ],
    });
    expect(seeded.results.every((r) => r.status === 'applied')).toBe(true);
    source.setRelocationState({ state: 'frozen', expect: 'live' });
    const page = source.exportPage({ table: 'task' });
    expect(page.rows.length).toBeGreaterThan(0);
    // Use a distinct rowid so importing into a seeded frozen scope would actually insert
    // (mutating the digest) rather than hitting a PK/rowid collision if the guard regressed.
    cachedImportTaskPage = {
      table: 'task',
      rows: page.rows.map((row, idx) => ({ rowid: 100 + idx, values: row.values })),
    };
    return cachedImportTaskPage;
  }

  async function createFrozenScope(): Promise<ScopeInstance> {
    const doState = createTestDoState();
    const scope = new ScopeClass(doState.ctx, { SYNC_FAULT: 'none' }, true);
    const p1Row = projectRow('p1', { isInbox: true, ownerId: 'm-a' });
    const t1Row = taskRow('t1', 'p1');
    const a1Row = {
      id: 'a1',
      taskId: 't1',
      fileName: 'doc.pdf',
      size: 100,
      mimeType: 'application/pdf',
      createdAt: NOW_ISH,
      updatedAt: NOW_ISH,
    };
    const seeded = await scope.push({
      scope: 'u:u-a',
      scopeUserId: 'u-a',
      pusherUserId: 'u-a',
      deviceId: 'dev-a',
      memberships: { p1: 'owner' },
      purgedProjects: [],
      meMemberId: null,
      ops: [
        {
          opId: 'op-p1',
          hlc: `${Date.now()}:0000:dev-a`,
          entity: 'project',
          entityId: 'p1',
          op: 'upsert',
          fields: Object.keys(p1Row),
          row: p1Row,
        },
        {
          opId: 'op-t1',
          hlc: `${Date.now()}:0001:dev-a`,
          entity: 'task',
          entityId: 't1',
          op: 'upsert',
          fields: Object.keys(t1Row),
          row: t1Row,
        },
        {
          opId: 'op-a1',
          hlc: `${Date.now()}:0002:dev-a`,
          entity: 'attachment',
          entityId: 'a1',
          op: 'upsert',
          fields: Object.keys(a1Row),
          row: a1Row,
        },
      ],
    });
    expect(seeded.results.every((r) => r.status === 'applied')).toBe(true);
    scope.setRelocationState({ state: 'frozen', expect: 'live' });
    return scope;
  }

  function createImportingScope(): ScopeInstance {
    const doState = createTestDoState();
    const scope = new ScopeClass(doState.ctx, { SYNC_FAULT: 'none' });
    scope.setRelocationState({ state: 'importing', expect: 'live' });
    return scope;
  }

  async function invokeMethod(
    scope: ScopeInstance,
    method: ScopeRpcMethod,
    ctx: CallContext,
  ): Promise<InvokeResult> {
    try {
      const value = await Promise.resolve(CALL[method](scope, ctx));
      return { ok: true, value };
    } catch (error) {
      return { ok: false, error };
    }
  }

  function isRelocationConflictError(error: unknown): boolean {
    return error instanceof Error && error.message.startsWith('RELOCATION_CONFLICT: ');
  }

  function assertOutcome(result: InvokeResult, expected: StateOutcome, label: string): void {
    switch (expected) {
      case 'ok':
        expect(result.ok, `${label} should succeed`).toBe(true);
        break;
      case 'relocating':
        expect(result.ok, `${label} should reject with SCOPE_RELOCATING`).toBe(false);
        if (!result.ok) {
          expect(isScopeRelocatingError(result.error), `${label} should fail with SCOPE_RELOCATING`).toBe(true);
        }
        break;
      case 'conflict':
        expect(result.ok, `${label} should reject with RELOCATION_CONFLICT`).toBe(false);
        if (!result.ok) {
          expect(isRelocationConflictError(result.error), `${label} should fail with RELOCATION_CONFLICT`).toBe(true);
        }
        break;
    }
  }

  const entries = (Object.entries(POLICY) as Array<[ScopeRpcMethod, Policy]>).map(
    ([method, policy]) => [method, policy.frozen, policy.importing] as const,
  );

  it.each(entries)(
    'enforces %s relocation policy (frozen: %s, importing: %s)',
    async (method, frozenExpected, importingExpected) => {
      const importTaskPage = await getValidImportTaskPage();

      const frozenScope = await createFrozenScope();
      const frozenDigestBefore = frozenScope.digest();
      const frozenResult = await invokeMethod(frozenScope, method, { state: 'frozen', importTaskPage });
      assertOutcome(frozenResult, frozenExpected, `${method} while frozen`);
      if (frozenExpected !== 'ok') {
        expect(frozenScope.digest(), `${method} must not mutate frozen scope`).toEqual(frozenDigestBefore);
      }

      const importingScope = createImportingScope();
      const importingDigestBefore = importingScope.digest();
      const importingResult = await invokeMethod(importingScope, method, {
        state: 'importing',
        importTaskPage,
      });
      assertOutcome(importingResult, importingExpected, `${method} while importing`);
      if (importingExpected !== 'ok') {
        expect(importingScope.digest(), `${method} must not mutate importing scope`).toEqual(importingDigestBefore);
      }
      if (method === 'importPage' && importingResult.ok) {
        expect(importingResult.value).toEqual({
          table: importTaskPage.table,
          imported: importTaskPage.rows.length,
        });
        expect(importingScope.digest().tables.task.count).toBe(importTaskPage.rows.length);
      }
    },
  );
});
