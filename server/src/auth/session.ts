import { device, identity, projectMembership, session, user } from '@schema';
import { and, eq, isNull, sql, type db } from 'void/db';
import type { ScopeStub } from '../sync/push';
import { generateRefreshToken, sha256Hex, signAccessToken } from './crypto';
import type { ProviderName } from './providers';

const REFRESH_TTL_MS = 90 * 24 * 60 * 60 * 1000;

export type DatabaseClient = typeof db;
export type ScopeLookup = (scope: string) => Pick<ScopeStub, 'getInboxProjectId'>;

export interface LoginStateFields {
  hasData: boolean;
  meMemberId: string | null;
  inboxProjectId: string | null;
}

export interface AuthSessionResult extends LoginStateFields {
  accessToken: string;
  refreshToken: string;
  user: { id: string };
  isNewAccount: boolean;
}

export interface RefreshResult extends LoginStateFields {
  accessToken: string;
  refreshToken: string;
}

async function resolveUserSyncState(
  database: DatabaseClient,
  userId: string,
  getScopeStub?: ScopeLookup,
): Promise<LoginStateFields> {
  const [userRows, membershipRows] = await database.batch([
    database.select({ meMemberId: user.meMemberId }).from(user).where(eq(user.id, userId)),
    database
      .select({ projectId: projectMembership.projectId })
      .from(projectMembership)
      .where(and(eq(projectMembership.userId, userId), isNull(projectMembership.removedAt))),
  ]);

  const meMemberId =
    userRows[0] && typeof userRows[0].meMemberId === 'string' ? userRows[0].meMemberId : null;
  const readableProjectIds = membershipRows.map((r) => String(r.projectId));

  let inboxProjectId: string | null = null;
  if (readableProjectIds.length > 0 && getScopeStub) {
    inboxProjectId = await getScopeStub(`u:${userId}`).getInboxProjectId({
      readableProjectIds,
    });
  }

  return {
    hasData: inboxProjectId !== null,
    meMemberId,
    inboxProjectId,
  };
}

function buildDeviceAndSessionStatements(
  database: DatabaseClient,
  params: {
    userId: string;
    deviceId: string;
    chainId: string;
    sessionId: string;
    refreshHash: string;
    now: number;
  },
) {
  return [
    database
      .insert(device)
      .values({ id: params.deviceId, userId: params.userId, lastSeenAt: params.now })
      .onConflictDoUpdate({
        target: device.id,
        set: { userId: params.userId, lastSeenAt: params.now },
      }),
    database.insert(session).values({
      id: params.sessionId,
      userId: params.userId,
      deviceId: params.deviceId,
      chainId: params.chainId,
      refreshHash: params.refreshHash,
      expiresAt: params.now + REFRESH_TTL_MS,
      createdAt: params.now,
      revokedAt: null,
    }),
  ] as const;
}

export async function createSessionForIdentity(
  database: DatabaseClient,
  params: {
    provider: ProviderName;
    sub: string;
    email: string | null;
    deviceId: string;
    jwtSecret: string;
    now?: number;
    getScopeStub?: ScopeLookup;
  },
): Promise<AuthSessionResult> {
  const now = params.now ?? Date.now();
  const refreshToken = generateRefreshToken();
  const refreshHash = await sha256Hex(refreshToken);
  const sessionId = crypto.randomUUID();
  const chainId = crypto.randomUUID();

  const existing = await database
    .select({ userId: identity.userId })
    .from(identity)
    .where(and(eq(identity.provider, params.provider), eq(identity.sub, params.sub)))
    .get();

  let userId: string;
  let isNewAccount: boolean;

  if (existing) {
    userId = existing.userId;
    isNewAccount = false;
    await database.batch([
      ...buildDeviceAndSessionStatements(database, {
        userId,
        deviceId: params.deviceId,
        chainId,
        sessionId,
        refreshHash,
        now,
      }),
    ]);
  } else {
    const newUserId = crypto.randomUUID();
    try {
      await database.batch([
        database.insert(user).values({ id: newUserId, createdAt: now }),
        database.insert(identity).values({
          provider: params.provider,
          sub: params.sub,
          userId: newUserId,
          email: params.email,
        }),
        ...buildDeviceAndSessionStatements(database, {
          userId: newUserId,
          deviceId: params.deviceId,
          chainId,
          sessionId,
          refreshHash,
          now,
        }),
      ]);
      userId = newUserId;
      isNewAccount = true;
    } catch (error) {
      // Handle concurrent first-time login for the same (provider, sub).
      const raced = await database
        .select({ userId: identity.userId })
        .from(identity)
        .where(and(eq(identity.provider, params.provider), eq(identity.sub, params.sub)))
        .get();
      if (!raced) throw error;
      userId = raced.userId;
      isNewAccount = false;
      await database.batch([
        ...buildDeviceAndSessionStatements(database, {
          userId,
          deviceId: params.deviceId,
          chainId,
          sessionId,
          refreshHash,
          now,
        }),
      ]);
    }
  }

  const [accessToken, syncState] = await Promise.all([
    signAccessToken(userId, params.jwtSecret),
    isNewAccount
      ? Promise.resolve<LoginStateFields>({
          hasData: false,
          meMemberId: null,
          inboxProjectId: null,
        })
      : resolveUserSyncState(database, userId, params.getScopeStub),
  ]);
  return {
    accessToken,
    refreshToken,
    user: { id: userId },
    isNewAccount,
    ...syncState,
  };
}

export async function rotateRefreshToken(
  database: DatabaseClient,
  params: {
    refreshToken: string;
    jwtSecret: string;
    now?: number;
    getScopeStub?: ScopeLookup;
  },
): Promise<RefreshResult | null> {
  const now = params.now ?? Date.now();
  const tokenHash = await sha256Hex(params.refreshToken);

  const existing = await database
    .select()
    .from(session)
    .where(eq(session.refreshHash, tokenHash))
    .get();

  if (!existing) {
    return null;
  }

  if (existing.revokedAt !== null) {
    // Reuse of a revoked refresh token: revoke the entire session chain.
    await database
      .update(session)
      .set({ revokedAt: now })
      .where(and(eq(session.chainId, existing.chainId), isNull(session.revokedAt)));
    return null;
  }

  if (existing.expiresAt <= now) {
    return null;
  }

  const newRefreshToken = generateRefreshToken();
  const newRefreshHash = await sha256Hex(newRefreshToken);
  const newSessionId = crypto.randomUUID();

  // Atomically insert the replacement only while `existing` is still unrevoked and unexpired,
  // and claim `existing` in the same D1 batch so no reuse can slip in between revoke and insert.
  const [, revoked] = await database.batch([
    database.insert(session).select(
      sql`SELECT ${newSessionId}, ${existing.userId}, ${existing.deviceId}, ${existing.chainId}, ${newRefreshHash}, ${now + REFRESH_TTL_MS}, ${now}, NULL WHERE EXISTS (SELECT 1 FROM session WHERE id = ${existing.id} AND revokedAt IS NULL AND expiresAt > ${now})`,
    ),
    database
      .update(session)
      .set({ revokedAt: now })
      .where(and(eq(session.id, existing.id), isNull(session.revokedAt)))
      .returning({ id: session.id }),
    database
      .insert(device)
      .values({ id: existing.deviceId, userId: existing.userId, lastSeenAt: now })
      .onConflictDoUpdate({
        target: device.id,
        set: { userId: existing.userId, lastSeenAt: now },
      }),
  ]);

  if (revoked.length === 0) {
    await database
      .update(session)
      .set({ revokedAt: now })
      .where(and(eq(session.chainId, existing.chainId), isNull(session.revokedAt)));
    return null;
  }

  const [accessToken, syncState] = await Promise.all([
    signAccessToken(existing.userId, params.jwtSecret),
    resolveUserSyncState(database, existing.userId, params.getScopeStub),
  ]);
  return { accessToken, refreshToken: newRefreshToken, ...syncState };
}
