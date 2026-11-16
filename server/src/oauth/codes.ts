import { oauthCode } from '@schema';
import { and, eq, gt, isNull } from 'void/db';
import { sha256Hex } from '../auth/crypto';
import type { DatabaseClient } from '../auth/session';
import { randomB64url } from '../base64url';

// Authorization codes (spec/mcp.md 4.2, 4.4 step 6, 4.5). D1 stores only the SHA-256 of
// the code; each code starts a new refresh family.

export const CODE_TTL_MS = 120 * 1000;

export type CodeRow = typeof oauthCode.$inferSelect;

export interface NewAuthorizationCode {
  clientId: string;
  redirectUri: string;
  codeChallenge: string;
  scope: string;
  resource: string | null;
  userId: string;
  now?: number;
}

/** Stores a new single-use code and returns the raw value to send to the client. */
export async function createAuthorizationCode(
  database: DatabaseClient,
  params: NewAuthorizationCode,
): Promise<string> {
  const now = params.now ?? Date.now();
  const code = randomB64url(32);
  await database.insert(oauthCode).values({
    codeHash: await sha256Hex(code),
    clientId: params.clientId,
    redirectUri: params.redirectUri,
    codeChallenge: params.codeChallenge,
    scope: params.scope,
    resource: params.resource,
    userId: params.userId,
    familyId: crypto.randomUUID(),
    expiresAt: now + CODE_TTL_MS,
    usedAt: null,
  });
  return code;
}

export async function findAuthorizationCode(database: DatabaseClient, codeHash: string): Promise<CodeRow | undefined> {
  return database.select().from(oauthCode).where(eq(oauthCode.codeHash, codeHash)).get();
}

/** Atomically marks the code used; returns undefined if it was already used or expired. */
export async function consumeAuthorizationCode(
  database: DatabaseClient,
  codeHash: string,
  now: number,
): Promise<CodeRow | undefined> {
  const [row] = await database
    .update(oauthCode)
    .set({ usedAt: now })
    .where(and(eq(oauthCode.codeHash, codeHash), isNull(oauthCode.usedAt), gt(oauthCode.expiresAt, now)))
    .returning();
  return row;
}
