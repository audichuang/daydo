import { index, integer, primaryKey, sqliteTable, text } from 'void/schema-d1';

export const user = sqliteTable('user', {
  id: text('id').primaryKey(),
  createdAt: integer('createdAt').notNull(),
  meMemberId: text('meMemberId'),
  name: text('name'),
  initial: text('initial'),
  color: text('color'),
  avatarUrl: text('avatarUrl'),
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
    replacedBy: text('replacedBy'),
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

// OAuth 2.1 (remote MCP). Only SHA-256 hashes of secrets are stored. See spec/mcp.md 4.2.
export const oauthClient = sqliteTable(
  'oauthClient',
  {
    clientId: text('clientId').primaryKey(),
    clientName: text('clientName').notNull(),
    redirectUris: text('redirectUris').notNull(),
    ipHash: text('ipHash').notNull(),
    createdAt: integer('createdAt').notNull(),
  },
  (t) => [index('oauthClient_ipHash_createdAt_idx').on(t.ipHash, t.createdAt)],
);

export const oauthPending = sqliteTable('oauthPending', {
  id: text('id').primaryKey(),
  clientId: text('clientId').notNull(),
  redirectUri: text('redirectUri').notNull(),
  codeChallenge: text('codeChallenge').notNull(),
  scope: text('scope').notNull(),
  clientState: text('clientState'),
  resource: text('resource'),
  bindHash: text('bindHash').notNull(),
  provider: text('provider').notNull(),
  nonce: text('nonce').notNull(),
  userId: text('userId'),
  consentTokenHash: text('consentTokenHash'),
  createdAt: integer('createdAt').notNull(),
  expiresAt: integer('expiresAt').notNull(),
  consumedAt: integer('consumedAt'),
});

export const oauthCode = sqliteTable('oauthCode', {
  codeHash: text('codeHash').primaryKey(),
  clientId: text('clientId').notNull(),
  redirectUri: text('redirectUri').notNull(),
  codeChallenge: text('codeChallenge').notNull(),
  scope: text('scope').notNull(),
  resource: text('resource'),
  userId: text('userId').notNull(),
  familyId: text('familyId').notNull(),
  expiresAt: integer('expiresAt').notNull(),
  usedAt: integer('usedAt'),
});

export const oauthRefresh = sqliteTable(
  'oauthRefresh',
  {
    refreshHash: text('refreshHash').primaryKey(),
    familyId: text('familyId').notNull(),
    userId: text('userId').notNull(),
    clientId: text('clientId').notNull(),
    scope: text('scope').notNull(),
    resource: text('resource'),
    createdAt: integer('createdAt').notNull(),
    expiresAt: integer('expiresAt').notNull(),
    revokedAt: integer('revokedAt'),
    // refreshHash of the successor row created by rotation.
    replacedBy: text('replacedBy'),
  },
  (t) => [index('oauthRefresh_familyId_idx').on(t.familyId)],
);

// ICS subscription sync. See spec/mcp.md 9.2.
export const icsSource = sqliteTable(
  'icsSource',
  {
    id: integer('id').primaryKey({ autoIncrement: true }),
    userId: text('userId').notNull(),
    name: text('name').notNull(),
    url: text('url').notNull(),
    projectId: text('projectId').notNull(),
    enabled: integer('enabled').notNull().default(1),
    syncIntervalSec: integer('syncIntervalSec').notNull().default(900),
    filterJson: text('filterJson'),
    timezone: text('timezone'),
    lastSyncAt: integer('lastSyncAt'),
    lastStatus: text('lastStatus'),
    lastStats: text('lastStats'),
    leaseToken: text('leaseToken'),
    leaseUntilMs: integer('leaseUntilMs'),
    createdAt: integer('createdAt').notNull(),
    updatedAt: integer('updatedAt').notNull(),
  },
  (t) => [index('icsSource_userId_idx').on(t.userId)],
);

export const icsMapping = sqliteTable(
  'icsMapping',
  {
    sourceId: integer('sourceId').notNull(),
    icsUid: text('icsUid').notNull(),
    occurrenceId: text('occurrenceId').notNull(),
    taskId: text('taskId').notNull(),
    projectId: text('projectId').notNull(),
    fingerprint: text('fingerprint'),
    sequence: integer('sequence'),
    dtstamp: text('dtstamp'),
    // pending | updating | applied | cancelled | purged
    state: text('state').notNull(),
    seriesSignature: text('seriesSignature'),
    lastError: text('lastError'),
    updatedAt: integer('updatedAt').notNull(),
  },
  (t) => [
    primaryKey({ columns: [t.sourceId, t.icsUid, t.occurrenceId] }),
    index('icsMapping_sourceId_idx').on(t.sourceId),
  ],
);
