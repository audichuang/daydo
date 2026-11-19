export const RELOCATION_STATE_TABLE = 'relocationState';
/** Set once by purgeFrozenData; kept separate from relocationState so older builds still read 'frozen'. */
export const RELOCATION_PURGED_TABLE = '_relocationPurged';

export function ensureScopeSchema(sql: SqlStorage): void {
  sql.exec(`
      CREATE TABLE IF NOT EXISTS member (
        id TEXT PRIMARY KEY NOT NULL,
        name TEXT NOT NULL,
        initial TEXT NOT NULL,
        color TEXT NOT NULL,
        createdAt INTEGER NOT NULL,
        updatedAt INTEGER NOT NULL,
        deletedAt INTEGER,
        clocks TEXT NOT NULL DEFAULT '{}',
        serverSeq INTEGER NOT NULL,
        purgedAt INTEGER
      );
      CREATE INDEX IF NOT EXISTS member_serverSeq_idx ON member (serverSeq);

      CREATE TABLE IF NOT EXISTS folder (
        id TEXT PRIMARY KEY NOT NULL,
        name TEXT NOT NULL,
        sortKey TEXT NOT NULL,
        createdAt INTEGER NOT NULL,
        updatedAt INTEGER NOT NULL,
        deletedAt INTEGER,
        clocks TEXT NOT NULL DEFAULT '{}',
        serverSeq INTEGER NOT NULL,
        purgedAt INTEGER
      );
      CREATE INDEX IF NOT EXISTS folder_serverSeq_idx ON folder (serverSeq);

      CREATE TABLE IF NOT EXISTS project (
        id TEXT PRIMARY KEY NOT NULL,
        name TEXT NOT NULL,
        color TEXT,
        icon TEXT,
        folderId TEXT,
        viewMode TEXT NOT NULL DEFAULT 'list',
        kind TEXT NOT NULL DEFAULT 'TASK',
        isInbox INTEGER NOT NULL DEFAULT 0,
        ownerId TEXT NOT NULL,
        sortKey TEXT NOT NULL,
        showInSmart TEXT NOT NULL DEFAULT 'all',
        notifyMode TEXT NOT NULL DEFAULT 'all',
        archivedAt INTEGER,
        createdAt INTEGER NOT NULL,
        updatedAt INTEGER NOT NULL,
        deletedAt INTEGER,
        clocks TEXT NOT NULL DEFAULT '{}',
        serverSeq INTEGER NOT NULL,
        purgedAt INTEGER
      );
      CREATE INDEX IF NOT EXISTS project_serverSeq_idx ON project (serverSeq);

      CREATE TABLE IF NOT EXISTS projectMember (
        projectId TEXT NOT NULL,
        memberId TEXT NOT NULL,
        role TEXT NOT NULL,
        createdAt INTEGER NOT NULL,
        updatedAt INTEGER NOT NULL,
        deletedAt INTEGER,
        clocks TEXT NOT NULL DEFAULT '{}',
        serverSeq INTEGER NOT NULL,
        purgedAt INTEGER,
        PRIMARY KEY (projectId, memberId)
      );
      CREATE INDEX IF NOT EXISTS projectMember_serverSeq_idx ON projectMember (serverSeq);

      CREATE TABLE IF NOT EXISTS projectInvite (
        id TEXT PRIMARY KEY NOT NULL,
        projectId TEXT NOT NULL,
        email TEXT NOT NULL,
        role TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'pending',
        createdAt INTEGER NOT NULL,
        updatedAt INTEGER NOT NULL,
        deletedAt INTEGER,
        clocks TEXT NOT NULL DEFAULT '{}',
        serverSeq INTEGER NOT NULL,
        purgedAt INTEGER
      );
      CREATE INDEX IF NOT EXISTS projectInvite_serverSeq_idx ON projectInvite (serverSeq);

      CREATE TABLE IF NOT EXISTS task (
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
        countdown INTEGER NOT NULL DEFAULT 0,
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
      CREATE INDEX IF NOT EXISTS task_serverSeq_idx ON task (serverSeq);
      CREATE INDEX IF NOT EXISTS task_projectId_idx ON task (projectId);

      CREATE TABLE IF NOT EXISTS checklistItem (
        id TEXT PRIMARY KEY NOT NULL,
        taskId TEXT NOT NULL,
        projectId TEXT NOT NULL,
        title TEXT NOT NULL,
        status INTEGER NOT NULL DEFAULT 0,
        sortKey TEXT NOT NULL,
        createdAt INTEGER NOT NULL,
        updatedAt INTEGER NOT NULL,
        deletedAt INTEGER,
        clocks TEXT NOT NULL DEFAULT '{}',
        serverSeq INTEGER NOT NULL,
        purgedAt INTEGER
      );
      CREATE INDEX IF NOT EXISTS checklistItem_serverSeq_idx ON checklistItem (serverSeq);
      CREATE INDEX IF NOT EXISTS checklistItem_taskId_idx ON checklistItem (taskId);
      CREATE INDEX IF NOT EXISTS checklistItem_projectId_idx ON checklistItem (projectId);

      CREATE TABLE IF NOT EXISTS tag (
        name TEXT PRIMARY KEY NOT NULL,
        label TEXT NOT NULL,
        color TEXT,
        sortKey TEXT NOT NULL,
        createdAt INTEGER NOT NULL,
        updatedAt INTEGER NOT NULL,
        deletedAt INTEGER,
        clocks TEXT NOT NULL DEFAULT '{}',
        serverSeq INTEGER NOT NULL,
        purgedAt INTEGER
      );
      CREATE INDEX IF NOT EXISTS tag_serverSeq_idx ON tag (serverSeq);

      CREATE TABLE IF NOT EXISTS attachment (
        id TEXT PRIMARY KEY NOT NULL,
        taskId TEXT NOT NULL,
        projectId TEXT NOT NULL,
        fileName TEXT NOT NULL,
        size INTEGER NOT NULL,
        mimeType TEXT NOT NULL,
        createdAt INTEGER NOT NULL,
        updatedAt INTEGER NOT NULL,
        deletedAt INTEGER,
        clocks TEXT NOT NULL DEFAULT '{}',
        serverSeq INTEGER NOT NULL,
        purgedAt INTEGER
      );
      CREATE INDEX IF NOT EXISTS attachment_serverSeq_idx ON attachment (serverSeq);
      CREATE INDEX IF NOT EXISTS attachment_taskId_idx ON attachment (taskId);
      CREATE INDEX IF NOT EXISTS attachment_projectId_idx ON attachment (projectId);

      CREATE TABLE IF NOT EXISTS comment (
        id TEXT PRIMARY KEY NOT NULL,
        taskId TEXT NOT NULL,
        projectId TEXT NOT NULL,
        authorId TEXT NOT NULL,
        body TEXT NOT NULL,
        createdAt INTEGER NOT NULL,
        updatedAt INTEGER NOT NULL,
        deletedAt INTEGER,
        clocks TEXT NOT NULL DEFAULT '{}',
        serverSeq INTEGER NOT NULL,
        purgedAt INTEGER
      );
      CREATE INDEX IF NOT EXISTS comment_serverSeq_idx ON comment (serverSeq);
      CREATE INDEX IF NOT EXISTS comment_taskId_idx ON comment (taskId);
      CREATE INDEX IF NOT EXISTS comment_projectId_idx ON comment (projectId);

      CREATE TABLE IF NOT EXISTS departure (
        entity TEXT NOT NULL,
        entityId TEXT NOT NULL,
        projectId TEXT NOT NULL,
        serverSeq INTEGER NOT NULL,
        PRIMARY KEY (entity, entityId, projectId)
      );
      CREATE INDEX IF NOT EXISTS departure_serverSeq_idx ON departure (serverSeq);

      CREATE TABLE IF NOT EXISTS opApplied (
        opId TEXT PRIMARY KEY NOT NULL,
        userId TEXT NOT NULL,
        status TEXT NOT NULL,
        reason TEXT,
        serverSeq INTEGER NOT NULL
      );

      CREATE TABLE IF NOT EXISTS counter (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        value INTEGER NOT NULL DEFAULT 0
      );

      CREATE TABLE IF NOT EXISTS purgedProject (
        projectId TEXT PRIMARY KEY NOT NULL,
        purgedAt INTEGER NOT NULL
      );

      CREATE TABLE IF NOT EXISTS relocationState (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        state TEXT NOT NULL CHECK (state IN ('live', 'frozen', 'importing'))
      );

      CREATE TABLE IF NOT EXISTS _relocationPurged (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        purgedAt INTEGER NOT NULL
      );
    `);

  const taskCols = sql
    .exec('PRAGMA table_info(task)')
    .toArray()
    .map((r) => String(r.name));
  if (!taskCols.includes('countdown')) {
    sql.exec('ALTER TABLE task ADD COLUMN countdown INTEGER NOT NULL DEFAULT 0;');
  }
}
