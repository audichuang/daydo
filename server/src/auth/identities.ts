import { identity, user } from '@schema';
import { and, asc, eq, sql } from 'void/db';
import { systemNow } from '../clock';
import type { IdentityProviderName, KeySource } from './providers';
import type { DatabaseClient } from './session';
import { verifyCredential, type CredentialVerificationResult } from './verifyCredential';

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

  // Atomic claim + readback in one D1 batch: insert if unbound, read owner of (provider, sub),
  // and read back caller's identity list so a write can never fail on a separate follow-up query.
  const [, ownerRows, identityRows] = await database.batch([
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
    selectIdentitiesForUser(database, params.userId),
  ]);

  const owner = ownerRows[0];
  if (!owner || owner.userId !== params.userId) {
    return { ok: false, reason: 'identity_in_use' };
  }

  return { ok: true, identities: decodeIdentityRows(identityRows) };
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

  const provider = params.body.provider;
  let verified: CredentialVerificationResult;

  if (provider === 'apple') {
    verified = await verifyCredential({
      provider: 'apple',
      identityToken: params.body.identityToken,
      nonce: params.body.nonce,
      audience: params.appleAudience,
      jwksUrl: params.appleJwksUrl,
      keySource: params.appleKeySource,
      now: params.now,
    });
  } else if (provider === 'google') {
    verified = await verifyCredential({
      provider: 'google',
      idToken: params.body.idToken,
      audience: params.googleAudience,
      jwksUrl: params.googleJwksUrl,
      keySource: params.googleKeySource,
      now: params.now,
    });
  } else if (provider === 'email') {
    verified = await verifyCredential({
      provider: 'email',
      database,
      email: params.body.email,
      code: params.body.code,
      logEventName: 'auth.link.email',
      now: params.now,
    });
  } else {
    return { status: 400, body: { error: 'provider must be apple, google, or email' } };
  }

  if (!verified.ok) {
    return { status: verified.status, body: { error: verified.error } };
  }

  const outcome = await linkIdentity(database, {
    userId: params.userId,
    provider: verified.identity.provider,
    sub: verified.identity.sub,
    email: verified.identity.email,
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
