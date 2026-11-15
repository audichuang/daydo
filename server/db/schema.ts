import { index, integer, primaryKey, sqliteTable, text } from 'void/schema-d1';

const syncMetadataColumns = () => ({
  createdAt: integer('createdAt').notNull(),
  updatedAt: integer('updatedAt').notNull(),
  deletedAt: integer('deletedAt'),
  ownerUserId: text('ownerUserId').notNull(),
  clocks: text('clocks').notNull().default('{}'),
  serverSeq: integer('serverSeq').notNull(),
  purgedAt: integer('purgedAt'),
});

export const user = sqliteTable('user', {
  id: text('id').primaryKey(),
  createdAt: integer('createdAt').notNull(),
});

export const identity = sqliteTable(
  'identity',
  {
    provider: text('provider').notNull(),
    sub: text('sub').notNull(),
    userId: text('userId')
      .notNull()
      .references(() => user.id, { onDelete: 'cascade' }),
    email: text('email'),
  },
  (t) => [
    primaryKey({ columns: [t.provider, t.sub] }),
    index('identity_userId_idx').on(t.userId),
  ],
);

export const session = sqliteTable(
  'session',
  {
    id: text('id').primaryKey(),
    userId: text('userId')
      .notNull()
      .references(() => user.id, { onDelete: 'cascade' }),
    deviceId: text('deviceId').notNull(),
    // Tracks a refresh token family so reuse of a revoked token invalidates the whole chain.
    chainId: text('chainId').notNull(),
    refreshHash: text('refreshHash').notNull().unique(),
    expiresAt: integer('expiresAt').notNull(),
    createdAt: integer('createdAt').notNull(),
    revokedAt: integer('revokedAt'),
  },
  (t) => [
    index('session_userId_idx').on(t.userId),
    index('session_chainId_idx').on(t.chainId),
  ],
);

export const device = sqliteTable(
  'device',
  {
    id: text('id').primaryKey(),
    userId: text('userId')
      .notNull()
      .references(() => user.id, { onDelete: 'cascade' }),
    lastSeenAt: integer('lastSeenAt').notNull(),
  },
  (t) => [index('device_userId_idx').on(t.userId)],
);

export const opApplied = sqliteTable(
  'op_applied',
  {
    opId: text('opId').primaryKey(),
    userId: text('userId').notNull(),
    status: text('status').notNull(),
    serverSeq: integer('serverSeq').notNull(),
    createdAt: integer('createdAt').notNull(),
  },
  (t) => [index('op_applied_userId_idx').on(t.userId)],
);

export const seq = sqliteTable('seq', {
  id: integer('id').primaryKey(),
  value: integer('value').notNull().default(0),
});

export const member = sqliteTable(
  'member',
  {
    id: text('id').primaryKey(),
    name: text('name').notNull(),
    initial: text('initial').notNull(),
    color: text('color').notNull(),
    ...syncMetadataColumns(),
  },
  (t) => [
    index('member_serverSeq_idx').on(t.serverSeq),
    index('member_ownerUserId_idx').on(t.ownerUserId),
  ],
);

export const folder = sqliteTable(
  'folder',
  {
    id: text('id').primaryKey(),
    name: text('name').notNull(),
    sortKey: text('sortKey').notNull(),
    ...syncMetadataColumns(),
  },
  (t) => [
    index('folder_serverSeq_idx').on(t.serverSeq),
    index('folder_ownerUserId_idx').on(t.ownerUserId),
  ],
);

export const project = sqliteTable(
  'project',
  {
    id: text('id').primaryKey(),
    name: text('name').notNull(),
    color: text('color'),
    icon: text('icon'),
    folderId: text('folderId'),
    viewMode: text('viewMode').notNull().default('list'),
    kind: text('kind').notNull().default('TASK'),
    isInbox: integer('isInbox').notNull().default(0),
    ownerId: text('ownerId').notNull(),
    sortKey: text('sortKey').notNull(),
    showInSmart: text('showInSmart').notNull().default('all'),
    notifyMode: text('notifyMode').notNull().default('all'),
    archivedAt: integer('archivedAt'),
    ...syncMetadataColumns(),
  },
  (t) => [
    index('project_serverSeq_idx').on(t.serverSeq),
    index('project_ownerUserId_idx').on(t.ownerUserId),
  ],
);

export const projectMember = sqliteTable(
  'projectMember',
  {
    projectId: text('projectId').notNull(),
    memberId: text('memberId').notNull(),
    role: text('role').notNull(),
    ...syncMetadataColumns(),
  },
  (t) => [
    primaryKey({ columns: [t.projectId, t.memberId] }),
    index('projectMember_serverSeq_idx').on(t.serverSeq),
    index('projectMember_ownerUserId_idx').on(t.ownerUserId),
  ],
);

export const task = sqliteTable(
  'task',
  {
    id: text('id').primaryKey(),
    projectId: text('projectId').notNull(),
    title: text('title').notNull(),
    content: text('content').notNull().default(''),
    priority: integer('priority').notNull().default(0),
    status: integer('status').notNull().default(0),
    startDay: text('startDay'),
    startMinute: integer('startMinute'),
    endDay: text('endDay'),
    endMinute: integer('endMinute'),
    timeZone: text('timeZone'),
    reminders: text('reminders').notNull().default('[]'),
    repeatRule: text('repeatRule'),
    tags: text('tags').notNull().default('[]'),
    assigneeId: text('assigneeId'),
    sortKey: text('sortKey').notNull(),
    completedAt: integer('completedAt'),
    sourceRaw: text('sourceRaw'),
    importNote: text('importNote'),
    ...syncMetadataColumns(),
  },
  (t) => [
    index('task_serverSeq_idx').on(t.serverSeq),
    index('task_ownerUserId_idx').on(t.ownerUserId),
    index('task_projectId_idx').on(t.projectId),
  ],
);

export const checklistItem = sqliteTable(
  'checklistItem',
  {
    id: text('id').primaryKey(),
    taskId: text('taskId').notNull(),
    title: text('title').notNull(),
    status: integer('status').notNull().default(0),
    sortKey: text('sortKey').notNull(),
    ...syncMetadataColumns(),
  },
  (t) => [
    index('checklistItem_serverSeq_idx').on(t.serverSeq),
    index('checklistItem_ownerUserId_idx').on(t.ownerUserId),
    index('checklistItem_taskId_idx').on(t.taskId),
  ],
);

export const tag = sqliteTable(
  'tag',
  {
    name: text('name').notNull(),
    label: text('label').notNull(),
    color: text('color'),
    sortKey: text('sortKey').notNull(),
    ...syncMetadataColumns(),
  },
  (t) => [
    primaryKey({ columns: [t.ownerUserId, t.name] }),
    index('tag_serverSeq_idx').on(t.serverSeq),
  ],
);

export const attachment = sqliteTable(
  'attachment',
  {
    id: text('id').primaryKey(),
    taskId: text('taskId').notNull(),
    fileName: text('fileName').notNull(),
    size: integer('size').notNull(),
    mimeType: text('mimeType').notNull(),
    ...syncMetadataColumns(),
  },
  (t) => [
    index('attachment_serverSeq_idx').on(t.serverSeq),
    index('attachment_ownerUserId_idx').on(t.ownerUserId),
    index('attachment_taskId_idx').on(t.taskId),
  ],
);

export const comment = sqliteTable(
  'comment',
  {
    id: text('id').primaryKey(),
    taskId: text('taskId').notNull(),
    authorId: text('authorId').notNull(),
    body: text('body').notNull(),
    ...syncMetadataColumns(),
  },
  (t) => [
    index('comment_serverSeq_idx').on(t.serverSeq),
    index('comment_ownerUserId_idx').on(t.ownerUserId),
    index('comment_taskId_idx').on(t.taskId),
  ],
);
