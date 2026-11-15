import { index, integer, primaryKey, sqliteTable, text } from 'void/schema-d1';

export const user = sqliteTable('user', {
  id: text('id').primaryKey(),
  createdAt: integer('createdAt').notNull(),
  meMemberId: text('meMemberId'),
  name: text('name'),
  initial: text('initial'),
  color: text('color'),
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

export const entityHome = sqliteTable(
  'entityHome',
  {
    entity: text('entity').notNull(),
    entityId: text('entityId').notNull(),
    scope: text('scope').notNull(),
  },
  (t) => [primaryKey({ columns: [t.entity, t.entityId] })],
);

export const listScopes = sqliteTable(
  'listScopes',
  {
    projectId: text('projectId').notNull(),
    scope: text('scope').notNull(),
  },
  (t) => [
    primaryKey({ columns: [t.projectId, t.scope] }),
    index('listScopes_scope_idx').on(t.scope),
  ],
);

export const projectMembership = sqliteTable(
  'projectMembership',
  {
    projectId: text('projectId').notNull(),
    userId: text('userId').notNull(),
    role: text('role').notNull(),
    createdAt: integer('createdAt').notNull(),
    removedAt: integer('removedAt'),
  },
  (t) => [
    primaryKey({ columns: [t.projectId, t.userId] }),
    index('projectMembership_userId_idx').on(t.userId),
  ],
);

export const purgedProject = sqliteTable('purgedProject', {
  projectId: text('projectId').primaryKey(),
  purgedAt: integer('purgedAt').notNull(),
});

export const invite = sqliteTable(
  'invite',
  {
    codeHash: text('codeHash').primaryKey(),
    projectId: text('projectId').notNull(),
    role: text('role').notNull(),
    email: text('email'),
    createdBy: text('createdBy').notNull(),
    createdAt: integer('createdAt').notNull(),
    expiresAt: integer('expiresAt').notNull(),
    revokedAt: integer('revokedAt'),
  },
  (t) => [index('invite_projectId_idx').on(t.projectId)],
);
