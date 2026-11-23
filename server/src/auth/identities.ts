import { identity, user } from '@schema';
import { and, asc, eq, sql } from 'void/db';
import { systemNow } from '../clock';
import { nonEmptyString } from '../http';
import { logEvent } from '../log';
import { normalizeEmail, verifyEmailCode } from './email';
import {
  AuthVerificationError,
  verifyAppleToken,
  verifyGoogleToken,
  type IdentityProviderName,
  type KeySource,
  type VerifiedIdentity,
} from './providers';
import type { DatabaseClient } from './session';

export interface LinkedIdentity {
  provider: IdentityProviderName;
  email?: string;
  createdAt: number;
}

function decodeIdentityRows(
  rows: ReadonlyArray<{ provider: string; email: string | null; createdAt: number }>,
): LinkedIdentity[] {
  return rows.map((row) => ({
    provider: row.provider as IdentityProviderName,
    ...(row.email ? { email: row.email } : {}),
    createdAt: Number(row.createdAt),
  }));
}

function selectIdentitiesForUser(database: DatabaseClient, userId: string) {
  const effectiveCreatedAt = sql<number>`coalesce(${identity.createdAt}, ${user.createdAt})`;
  return database
    .select({
      provider: identity.provider,
      email: identity.email,
      createdAt: effectiveCreatedAt,
    })
    .from(identity)
    .innerJoin(user, eq(identity.userId, user.id))
    .where(eq(identity.userId, userId))
    .orderBy(asc(effectiveCreatedAt), asc(identity.provider), asc(identity.sub));
}

export async function listUserIdentities(
  database: DatabaseClient,
  userId: string,
): Promise<LinkedIdentity[]> {
  const rows = await selectIdentitiesForUser(database, userId);
  return decodeIdentityRows(rows);
}

/** Returns null when `userId` does not exist in `user`. */
export async function listUserIdentitiesWithCheck(
  database: DatabaseClient,
  userId: string,
): Promise<LinkedIdentity[] | null> {
  const [userRows, identityRows] = await database.batch([
    database.select({ id: user.id }).from(user).where(eq(user.id, userId)),
    selectIdentitiesForUser(database, userId),
  ]);
  if (userRows.length === 0) {
    return null;
  }
  return decodeIdentityRows(identityRows);
}

export type LinkIdentityOutcome =
  | { ok: true; identities: LinkedIdentity[] }
  | { ok: false; reason: 'user_not_found' | 'identity_in_use' };

export async function linkIdentity(
  database: DatabaseClient,
  params: {
    userId: string;
    provider: IdentityProviderName;
    sub: string;
    email: string | null;
    now?: number;
  },
): Promise<LinkIdentityOutcome> {
  const now = params.now ?? systemNow();
  const caller = await database
    .select({ id: user.id })
    .from(user)
    .where(eq(user.id, params.userId))
    .get();
  if (!caller) {
    return { ok: false, reason: 'user_not_found' };
  }

  // Atomic claim: insert if unbound, then read back the owner of (provider, sub).
  // Already belonging to caller -> idempotent success; belonging to another user -> 409 without transfer.
  const [, ownerRows] = await database.batch([
    database
      .insert(identity)
      .values({
        provider: params.provider,
        sub: params.sub,
        userId: params.userId,
        email: params.email,
        createdAt: now,
      })
      .onConflictDoNothing(),
    database
      .select({ userId: identity.userId })
      .from(identity)
      .where(and(eq(identity.provider, params.provider), eq(identity.sub, params.sub))),
  ]);

  const owner = ownerRows[0];
  if (!owner || owner.userId !== params.userId) {
    return { ok: false, reason: 'identity_in_use' };
  }

  const identities = await listUserIdentities(database, params.userId);
  return { ok: true, identities };
}

export type AuthLinkRouteResult =
  | { status: 200; body: LinkedIdentity[] }
  | { status: 400 | 401 | 404 | 409 | 500; body: { error: string } };

export async function handleAuthLink(
  database: DatabaseClient,
  params: {
    userId: string;
    body: Record<string, unknown> | null;
    appleAudience: string;
    appleJwksUrl?: string;
    appleKeySource?: KeySource;
    googleAudience?: string;
    googleJwksUrl?: string;
    googleKeySource?: KeySource;
    now?: number;
  },
): Promise<AuthLinkRouteResult> {
  if (!params.body) {
    return { status: 400, body: { error: 'Invalid JSON body' } };
  }

  const currentDate = params.now !== undefined ? new Date(params.now) : undefined;
  const provider = params.body.provider;
  let verified: VerifiedIdentity;

  if (provider === 'apple') {
    const identityToken = nonEmptyString(params.body.identityToken);
    const nonce = nonEmptyString(params.body.nonce);
    if (!identityToken || !nonce) {
      return { status: 400, body: { error: 'identityToken and nonce are required' } };
    }
    try {
      verified = await verifyAppleToken({
        identityToken,
        nonce,
        audience: params.appleAudience,
        jwksUrl: params.appleJwksUrl,
        keySource: params.appleKeySource,
        currentDate,
      });
    } catch (error) {
      if (error instanceof AuthVerificationError) {
        return { status: 401, body: { error: error.message } };
      }
      throw error;
    }
  } else if (provider === 'google') {
    const idToken = nonEmptyString(params.body.idToken);
    if (!idToken) {
      return { status: 400, body: { error: 'idToken is required' } };
    }
    if (!params.googleAudience) {
      return { status: 500, body: { error: 'Google auth is not configured' } };
    }
    try {
      verified = await verifyGoogleToken({
        idToken,
        audience: params.googleAudience,
        jwksUrl: params.googleJwksUrl,
        keySource: params.googleKeySource,
        currentDate,
      });
    } catch (error) {
      if (error instanceof AuthVerificationError) {
        return { status: 401, body: { error: error.message } };
      }
      throw error;
    }
  } else if (provider === 'email') {
    const email = normalizeEmail(params.body.email);
    const code = params.body.code;
    if (!email || typeof code !== 'string') {
      return { status: 400, body: { error: 'A valid email and code are required' } };
    }
    const ok = await verifyEmailCode(database, { email, code: code.trim(), now: params.now });
    logEvent(ok ? 'log' : 'warn', 'auth.link.email', { outcome: ok ? 'ok' : 'invalid_code' });
    if (!ok) {
      return { status: 401, body: { error: 'Invalid or expired code' } };
    }
    verified = { provider: 'email', sub: email, email };
  } else {
    return { status: 400, body: { error: 'provider must be apple, google, or email' } };
  }

  const outcome = await linkIdentity(database, {
    userId: params.userId,
    provider: verified.provider,
    sub: verified.sub,
    email: verified.email,
    now: params.now,
  });

  if (!outcome.ok) {
    if (outcome.reason === 'user_not_found') {
      return { status: 404, body: { error: 'User not found' } };
    }
    return { status: 409, body: { error: 'identity_in_use' } };
  }
  return { status: 200, body: outcome.identities };
}
