import { device, identity, session, user } from '@schema';
import { and, eq, gt, isNull, sql, type db } from 'void/db';
import { systemNow } from '../clock';
import { activeProjectIds, decodeProjectIds } from '../membership';
import type { ScopeStub } from '../scope/api';
import { userScope } from '../sync/scopeName';
import { generateRefreshToken, sha256Hex, signAccessToken } from './crypto';
import { sanitizeHttpsAvatarUrl, type IdentityProviderName } from './providers';

const REFRESH_TTL_MS = 90 * 24 * 60 * 60 * 1000;
const REFRESH_GRACE_MS = 10 * 60 * 1000;

export type DatabaseClient = typeof db;
export type ScopeLookup = (scope: string) => Pick<ScopeStub, 'getInboxProjectId'>;

export interface LoginStateFields {
  hasData: boolean;
  meMemberId: string | null;
  inboxProjectId: string | null;
  avatarUrl: string | null;
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
    database
      .select({ meMemberId: user.meMemberId, avatarUrl: user.avatarUrl })
      .from(user)
      .where(eq(user.id, userId)),
    activeProjectIds(database, userId),
  ]);

  const meMemberId =
    userRows[0] && typeof userRows[0].meMemberId === 'string' ? userRows[0].meMemberId : null;
  const avatarUrl =
    userRows[0] && typeof userRows[0].avatarUrl === 'string' && userRows[0].avatarUrl.length > 0
      ? userRows[0].avatarUrl
      : null;
  const readableProjectIds = decodeProjectIds(membershipRows);

  let inboxProjectId: string | null = null;
  if (readableProjectIds.length > 0 && getScopeStub) {
    inboxProjectId = await getScopeStub(userScope(userId)).getInboxProjectId({
      readableProjectIds,
    });
  }

  return {
    hasData: inboxProjectId !== null,
    meMemberId,
    inboxProjectId,
    avatarUrl,
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
      replacedBy: null,
    }),
  ] as const;
}

async function issueSessionForExistingUser(
  database: DatabaseClient,
  params: {
    userId: string;
    deviceId: string;
    chainId: string;
    sessionId: string;
    refreshToken: string;
    refreshHash: string;
    jwtSecret: string;
    now: number;
    getScopeStub?: ScopeLookup;
    googleAvatarUrl?: string | null;
  },
): Promise<AuthSessionResult> {
  // Resolve sync state before writing the session row so a transient DO RPC failure
  // does not leave an orphaned session in D1.
  const [accessToken, syncState] = await Promise.all([
    signAccessToken(params.userId, params.jwtSecret),
    resolveUserSyncState(database, params.userId, params.getScopeStub),
  ]);
  const statements = [
    ...buildDeviceAndSessionStatements(database, {
      userId: params.userId,
      deviceId: params.deviceId,
      chainId: params.chainId,
      sessionId: params.sessionId,
      refreshHash: params.refreshHash,
      now: params.now,
    }),
    ...(params.googleAvatarUrl !== undefined
      ? [
          database
            .update(user)
            .set({ avatarUrl: params.googleAvatarUrl })
            .where(eq(user.id, params.userId)),
        ]
      : []),
  ];
  await database.batch(statements as [typeof statements[0], ...typeof statements]);
  return {
    accessToken,
    refreshToken: params.refreshToken,
    user: { id: params.userId },
    isNewAccount: false,
    ...syncState,
    ...(params.googleAvatarUrl !== undefined ? { avatarUrl: params.googleAvatarUrl } : {}),
  };
}

export async function createSessionForIdentity(
  database: DatabaseClient,
  params: {
    provider: IdentityProviderName;
    sub: string;
    email: string | null;
    avatarUrl?: string | null;
    deviceId: string;
    jwtSecret: string;
    now?: number;
    getScopeStub?: ScopeLookup;
  },
): Promise<AuthSessionResult> {
  const now = params.now ?? systemNow();
  const refreshToken = generateRefreshToken();
  const refreshHash = await sha256Hex(refreshToken);
  const sessionId = crypto.randomUUID();
  const chainId = crypto.randomUUID();
  const googleAvatarUrl =
    params.provider === 'google' ? sanitizeHttpsAvatarUrl(params.avatarUrl) : undefined;

  const existing = await database
    .select({ userId: identity.userId })
    .from(identity)
    .where(and(eq(identity.provider, params.provider), eq(identity.sub, params.sub)))
    .get();

  if (existing) {
    return issueSessionForExistingUser(database, {
      userId: existing.userId,
      deviceId: params.deviceId,
      chainId,
      sessionId,
      refreshToken,
      refreshHash,
      jwtSecret: params.jwtSecret,
      now,
      getScopeStub: params.getScopeStub,
      googleAvatarUrl,
    });
  }

  const newUserId = crypto.randomUUID();
  try {
    await database.batch([
      database.insert(user).values({
        id: newUserId,
        createdAt: now,
        ...(googleAvatarUrl !== undefined ? { avatarUrl: googleAvatarUrl } : {}),
      }),
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
    const accessToken = await signAccessToken(newUserId, params.jwtSecret);
    return {
      accessToken,
      refreshToken,
      user: { id: newUserId },
      isNewAccount: true,
      hasData: false,
      meMemberId: null,
      inboxProjectId: null,
      avatarUrl: googleAvatarUrl ?? null,
    };
  } catch (error) {
    // Handle concurrent first-time login for the same (provider, sub).
    const raced = await database
      .select({ userId: identity.userId })
      .from(identity)
      .where(and(eq(identity.provider, params.provider), eq(identity.sub, params.sub)))
      .get();
    if (!raced) throw error;
    return issueSessionForExistingUser(database, {
      userId: raced.userId,
      deviceId: params.deviceId,
      chainId,
      sessionId,
      refreshToken,
      refreshHash,
      jwtSecret: params.jwtSecret,
      now,
      getScopeStub: params.getScopeStub,
      googleAvatarUrl,
    });
  }
}

async function revokeChain(database: DatabaseClient, chainId: string, now: number): Promise<void> {
  await database
    .update(session)
    .set({ revokedAt: now })
    .where(and(eq(session.chainId, chainId), isNull(session.revokedAt)));
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
  const now = params.now ?? systemNow();
  const tokenHash = await sha256Hex(params.refreshToken);

  const existing = await database
    .select()
    .from(session)
    .where(eq(session.refreshHash, tokenHash))
    .get();

  if (!existing) {
    return null;
  }

  let target = existing;
  let isGraceRetry = false;

  if (existing.revokedAt !== null) {
    // Allow lost-response grace retries when `existing` was revoked by normal rotation
    // within the grace window and its latest direct successor has not been used or revoked yet.
    const withinGrace =
      now >= existing.revokedAt && now - existing.revokedAt <= REFRESH_GRACE_MS;
    const successor =
      withinGrace && existing.replacedBy !== null
        ? await database
            .select()
            .from(session)
            .where(and(eq(session.id, existing.replacedBy), eq(session.chainId, existing.chainId)))
            .get()
        : undefined;

    if (!successor || successor.revokedAt !== null || successor.expiresAt <= now) {
      // Reuse of a revoked refresh token: revoke the entire session chain.
      await revokeChain(database, existing.chainId, now);
      return null;
    }

    target = successor;
    isGraceRetry = true;
  } else if (existing.expiresAt <= now) {
    return null;
  }

  // Resolve sync state before rotating so a transient Scope DO RPC failure leaves
  // the active token valid and avoids triggering reuse detection on retry.
  const [accessToken, syncState] = await Promise.all([
    signAccessToken(existing.userId, params.jwtSecret),
    resolveUserSyncState(database, existing.userId, params.getScopeStub),
  ]);

  const newRefreshToken = generateRefreshToken();
  const newRefreshHash = await sha256Hex(newRefreshToken);
  const newSessionId = crypto.randomUUID();

  // Atomically insert the replacement only while `target` is still unrevoked and unexpired,
  // and claim `target` in the same D1 batch so no reuse or concurrent grace retry can slip in.
  // On a grace retry, also repoint `existing.replacedBy` to `newSessionId` (without changing
  // `existing.revokedAt`) so subsequent lost-response retries within the same 10-minute window
  // still find the latest unused successor.
  const baseStatements = [
    database.insert(session).select(
      sql`SELECT ${newSessionId}, ${existing.userId}, ${existing.deviceId}, ${existing.chainId}, ${newRefreshHash}, ${now + REFRESH_TTL_MS}, ${now}, NULL, NULL WHERE EXISTS (SELECT 1 FROM session WHERE id = ${target.id} AND revokedAt IS NULL AND expiresAt > ${now})`,
    ),
    database
      .update(session)
      .set(isGraceRetry ? { revokedAt: now } : { revokedAt: now, replacedBy: newSessionId })
      .where(and(eq(session.id, target.id), isNull(session.revokedAt), gt(session.expiresAt, now)))
      .returning({ id: session.id }),
    database
      .insert(device)
      .values({ id: existing.deviceId, userId: existing.userId, lastSeenAt: now })
      .onConflictDoUpdate({
        target: device.id,
        set: { userId: existing.userId, lastSeenAt: now },
      }),
  ] as const;

  const [, revoked] = await database.batch(
    isGraceRetry
      ? [
          ...baseStatements,
          database
            .update(session)
            .set({ replacedBy: newSessionId })
            .where(
              and(
                eq(session.id, existing.id),
                eq(session.replacedBy, target.id),
                sql`EXISTS (SELECT 1 FROM session WHERE id = ${newSessionId})`,
              ),
            ),
        ]
      : [...baseStatements],
  );

  if (revoked.length === 0) {
    await revokeChain(database, existing.chainId, now);
    return null;
  }

  return { accessToken, refreshToken: newRefreshToken, ...syncState };
}

export async function updateUserAvatar(
  database: DatabaseClient,
  params: { userId: string; avatarUrl: string },
): Promise<{ avatarUrl: string } | null> {
  const updated = await database
    .update(user)
    .set({ avatarUrl: params.avatarUrl })
    .where(eq(user.id, params.userId))
    .returning({ avatarUrl: user.avatarUrl });
  if (updated.length === 0) {
    return null;
  }
  return { avatarUrl: params.avatarUrl };
}
