import { createLocalJWKSet, exportJWK, generateKeyPair, SignJWT } from 'jose';
import { eq } from 'drizzle-orm';
import { describe, expect, it } from 'vitest';
import * as schema from '../db/schema';
import {
  generateRefreshToken,
  sha256Hex,
  signAccessToken,
  verifyAccessToken,
} from '../src/auth/crypto';
import {
  AuthVerificationError,
  verifyAppleToken,
  verifyGoogleToken,
} from '../src/auth/providers';
import {
  createSessionForIdentity,
  rotateRefreshToken,
  type DatabaseClient,
} from '../src/auth/session';
import { createTestD1 } from './sqliteD1';

async function makeKeyFixture(alg: 'RS256' | 'ES256', kid: string) {
  const { publicKey, privateKey } = await generateKeyPair(alg);
  const jwk = await exportJWK(publicKey);
  jwk.kid = kid;
  jwk.alg = alg;
  jwk.use = 'sig';
  return {
    privateKey,
    jwks: createLocalJWKSet({ keys: [jwk] }),
  };
}

describe('auth crypto', () => {
  it('signs and verifies HS256 access tokens with 1h expiry', async () => {
    const secret = 'unit-test-jwt-secret-32-bytes-minimum';
    const token = await signAccessToken('user-123', secret);
    const verified = await verifyAccessToken(token, secret);
    expect(verified.userId).toBe('user-123');

    const [, payloadB64] = token.split('.');
    const payload = JSON.parse(Buffer.from(payloadB64, 'base64url').toString('utf8')) as {
      sub: string;
      iat: number;
      exp: number;
    };
    expect(payload.sub).toBe('user-123');
    expect(payload.exp - payload.iat).toBe(3600);
  });

  it('rejects access tokens signed with a different secret', async () => {
    const token = await signAccessToken('user-123', 'secret-a-32-bytes-minimum-123456');
    await expect(
      verifyAccessToken(token, 'secret-b-32-bytes-minimum-123456'),
    ).rejects.toThrow();
  });

  it('generates 32-byte base64url refresh tokens and sha256 hex hashes', async () => {
    const t1 = generateRefreshToken();
    const t2 = generateRefreshToken();
    expect(t1).not.toBe(t2);
    expect(t1).toMatch(/^[A-Za-z0-9_-]{43}$/);
    const hash = await sha256Hex(t1);
    expect(hash).toMatch(/^[0-9a-f]{64}$/);
  });
});

describe('Apple identity token verification', () => {
  const audience = 'com.audichuang.daydo';

  it('verifies a valid RSA-signed Apple token with matching nonce sha256', async () => {
    const { privateKey, jwks } = await makeKeyFixture('RS256', 'apple-rsa-1');
    const rawNonce = 'raw-nonce-abc-123';
    const token = await new SignJWT({
      nonce: await sha256Hex(rawNonce),
      email: 'alice@privaterelay.appleid.com',
    })
      .setProtectedHeader({ alg: 'RS256', kid: 'apple-rsa-1' })
      .setIssuer('https://appleid.apple.com')
      .setAudience(audience)
      .setSubject('apple-sub-001')
      .setIssuedAt()
      .setExpirationTime('10m')
      .sign(privateKey);

    const result = await verifyAppleToken({
      identityToken: token,
      nonce: rawNonce,
      audience,
      keySource: jwks,
    });
    expect(result).toEqual({
      provider: 'apple',
      sub: 'apple-sub-001',
      email: 'alice@privaterelay.appleid.com',
    });
  });

  it('verifies a valid EC-signed token as well', async () => {
    const { privateKey, jwks } = await makeKeyFixture('ES256', 'apple-ec-1');
    const rawNonce = 'raw-nonce-ec';
    const token = await new SignJWT({ nonce: await sha256Hex(rawNonce) })
      .setProtectedHeader({ alg: 'ES256', kid: 'apple-ec-1' })
      .setIssuer('https://appleid.apple.com')
      .setAudience(audience)
      .setSubject('apple-sub-ec')
      .setIssuedAt()
      .setExpirationTime('10m')
      .sign(privateKey);

    const result = await verifyAppleToken({
      identityToken: token,
      nonce: rawNonce,
      audience,
      keySource: jwks,
    });
    expect(result).toEqual({
      provider: 'apple',
      sub: 'apple-sub-ec',
      email: null,
    });
  });

  it('rejects nonce mismatch', async () => {
    const { privateKey, jwks } = await makeKeyFixture('RS256', 'apple-rsa-2');
    const token = await new SignJWT({ nonce: await sha256Hex('expected-nonce') })
      .setProtectedHeader({ alg: 'RS256', kid: 'apple-rsa-2' })
      .setIssuer('https://appleid.apple.com')
      .setAudience(audience)
      .setSubject('apple-sub-001')
      .setIssuedAt()
      .setExpirationTime('10m')
      .sign(privateKey);

    await expect(
      verifyAppleToken({
        identityToken: token,
        nonce: 'different-nonce',
        audience,
        keySource: jwks,
      }),
    ).rejects.toThrow(AuthVerificationError);
  });

  it('rejects wrong audience', async () => {
    const { privateKey, jwks } = await makeKeyFixture('RS256', 'apple-rsa-3');
    const rawNonce = 'nonce-aud';
    const token = await new SignJWT({ nonce: await sha256Hex(rawNonce) })
      .setProtectedHeader({ alg: 'RS256', kid: 'apple-rsa-3' })
      .setIssuer('https://appleid.apple.com')
      .setAudience('com.other.app')
      .setSubject('apple-sub-001')
      .setIssuedAt()
      .setExpirationTime('10m')
      .sign(privateKey);

    await expect(
      verifyAppleToken({
        identityToken: token,
        nonce: rawNonce,
        audience,
        keySource: jwks,
      }),
    ).rejects.toThrow(AuthVerificationError);
  });

  it('rejects expired tokens', async () => {
    const { privateKey, jwks } = await makeKeyFixture('RS256', 'apple-rsa-4');
    const rawNonce = 'nonce-exp';
    const nowSec = Math.floor(Date.now() / 1000);
    const token = await new SignJWT({ nonce: await sha256Hex(rawNonce) })
      .setProtectedHeader({ alg: 'RS256', kid: 'apple-rsa-4' })
      .setIssuer('https://appleid.apple.com')
      .setAudience(audience)
      .setSubject('apple-sub-001')
      .setIssuedAt(nowSec - 3600)
      .setExpirationTime(nowSec - 60)
      .sign(privateKey);

    await expect(
      verifyAppleToken({
        identityToken: token,
        nonce: rawNonce,
        audience,
        keySource: jwks,
      }),
    ).rejects.toThrow(AuthVerificationError);
  });
});

describe('Google ID token verification', () => {
  const audience = 'google-ios-client-id';

  it('accepts both accounts.google.com and https://accounts.google.com issuers', async () => {
    const { privateKey, jwks } = await makeKeyFixture('RS256', 'google-1');
    for (const iss of ['accounts.google.com', 'https://accounts.google.com']) {
      const token = await new SignJWT({ email: 'bob@gmail.com' })
        .setProtectedHeader({ alg: 'RS256', kid: 'google-1' })
        .setIssuer(iss)
        .setAudience(audience)
        .setSubject('google-sub-1')
        .setIssuedAt()
        .setExpirationTime('10m')
        .sign(privateKey);

      const result = await verifyGoogleToken({
        idToken: token,
        audience,
        keySource: jwks,
      });
      expect(result).toEqual({
        provider: 'google',
        sub: 'google-sub-1',
        email: 'bob@gmail.com',
      });
    }
  });

  it('rejects wrong audience and expired Google tokens', async () => {
    const { privateKey, jwks } = await makeKeyFixture('RS256', 'google-2');
    const wrongAudToken = await new SignJWT({})
      .setProtectedHeader({ alg: 'RS256', kid: 'google-2' })
      .setIssuer('https://accounts.google.com')
      .setAudience('wrong-aud')
      .setSubject('google-sub-2')
      .setIssuedAt()
      .setExpirationTime('10m')
      .sign(privateKey);

    await expect(
      verifyGoogleToken({ idToken: wrongAudToken, audience, keySource: jwks }),
    ).rejects.toThrow(AuthVerificationError);

    const nowSec = Math.floor(Date.now() / 1000);
    const expiredToken = await new SignJWT({})
      .setProtectedHeader({ alg: 'RS256', kid: 'google-2' })
      .setIssuer('https://accounts.google.com')
      .setAudience(audience)
      .setSubject('google-sub-2')
      .setIssuedAt(nowSec - 3600)
      .setExpirationTime(nowSec - 60)
      .sign(privateKey);

    await expect(
      verifyGoogleToken({ idToken: expiredToken, audience, keySource: jwks }),
    ).rejects.toThrow(AuthVerificationError);
  });
});

describe('refresh token rotation & reuse race (Finding 3)', () => {
  const jwtSecret = 'unit-test-jwt-secret-32-bytes-minimum';

  it('kills the entire chain when B reuses the token between A revoke/read and A batch', async () => {
    const { db } = createTestD1();
    const database = db as unknown as DatabaseClient;

    const initial = await createSessionForIdentity(database, {
      provider: 'apple',
      sub: 'race-user-1',
      email: null,
      deviceId: 'dev-1',
      jwtSecret,
      now: 1000,
    });
    const otherChain = await createSessionForIdentity(database, {
      provider: 'apple',
      sub: 'race-user-1',
      email: null,
      deviceId: 'dev-1',
      jwtSecret,
      now: 1001,
    });

    let intercepted = false;
    let bResult: Awaited<ReturnType<typeof rotateRefreshToken>> | undefined;

    const proxiedDb = new Proxy(database, {
      get(target, prop, receiver) {
        if (prop === 'batch') {
          return async (...args: Parameters<DatabaseClient['batch']>) => {
            if (!intercepted) {
              intercepted = true;
              // Run B completely against the underlying DB right before A's batch executes.
              bResult = await rotateRefreshToken(database, {
                refreshToken: initial.refreshToken,
                jwtSecret,
                now: 2001,
              });
            }
            return target.batch(...args);
          };
        }
        return Reflect.get(target, prop, receiver);
      },
    });

    const aResult = await rotateRefreshToken(proxiedDb, {
      refreshToken: initial.refreshToken,
      jwtSecret,
      now: 2000,
    });

    expect(intercepted).toBe(true);
    // At most one of A or B could obtain a candidate replacement, and the chain must be dead afterwards.
    if (aResult) {
      const followUpA = await rotateRefreshToken(database, {
        refreshToken: aResult.refreshToken,
        jwtSecret,
        now: 3000,
      });
      expect(followUpA).toBeNull();
    }
    if (bResult) {
      const followUpB = await rotateRefreshToken(database, {
        refreshToken: bResult.refreshToken,
        jwtSecret,
        now: 3001,
      });
      expect(followUpB).toBeNull();
    }
    expect(aResult !== null && bResult !== null).toBe(false);

    // Unrelated chain for the same user/device remains valid.
    const otherAfter = await rotateRefreshToken(database, {
      refreshToken: otherChain.refreshToken,
      jwtSecret,
      now: 3002,
    });
    expect(otherAfter).not.toBeNull();
  });

  it('kills the entire chain in the opposite interleaving (A completes batch before B, or concurrent SELECT before batch)', async () => {
    const { db } = createTestD1();
    const database = db as unknown as DatabaseClient;

    const initial = await createSessionForIdentity(database, {
      provider: 'apple',
      sub: 'race-user-2',
      email: null,
      deviceId: 'dev-1',
      jwtSecret,
      now: 1000,
    });

    // Gate B's batch until A's batch has completed, while B already passed SELECT.
    let releaseB!: () => void;
    const bWait = new Promise<void>((resolve) => {
      releaseB = resolve;
    });
    let bReachedBatch!: () => void;
    const bAtBatch = new Promise<void>((resolve) => {
      bReachedBatch = resolve;
    });

    const bProxiedDb = new Proxy(database, {
      get(target, prop, receiver) {
        if (prop === 'batch') {
          return async (...args: Parameters<DatabaseClient['batch']>) => {
            bReachedBatch();
            await bWait;
            return target.batch(...args);
          };
        }
        return Reflect.get(target, prop, receiver);
      },
    });

    const bPromise = rotateRefreshToken(bProxiedDb, {
      refreshToken: initial.refreshToken,
      jwtSecret,
      now: 2001,
    });
    await bAtBatch;

    // A completes fully while B is paused right before its batch.
    const aResult = await rotateRefreshToken(database, {
      refreshToken: initial.refreshToken,
      jwtSecret,
      now: 2000,
    });
    expect(aResult).not.toBeNull();

    releaseB();
    const bResult = await bPromise;
    expect(bResult).toBeNull();

    // Chain must be dead: A's replacement must be revoked by B's reuse detection.
    const followUp = await rotateRefreshToken(database, {
      refreshToken: aResult!.refreshToken,
      jwtSecret,
      now: 3000,
    });
    expect(followUp).toBeNull();
  });
});

describe('refresh token grace window for lost-response retries', () => {
  const jwtSecret = 'unit-test-jwt-secret-32-bytes-minimum';
  const TEN_MINUTES_MS = 10 * 60 * 1000;

  it('lostResponseRetryWithinGraceGetsNewTokens', async () => {
    const { db } = createTestD1();
    const database = db as unknown as DatabaseClient;

    const initial = await createSessionForIdentity(database, {
      provider: 'apple',
      sub: 'grace-user-1',
      email: null,
      deviceId: 'dev-1',
      jwtSecret,
      now: 1000,
    });

    const rotated = await rotateRefreshToken(database, {
      refreshToken: initial.refreshToken,
      jwtSecret,
      now: 2000,
    });
    expect(rotated).not.toBeNull();

    const grace = await rotateRefreshToken(database, {
      refreshToken: initial.refreshToken,
      jwtSecret,
      now: 2000 + 9 * 60 * 1000,
    });
    expect(grace).not.toBeNull();
    expect(grace!.refreshToken).not.toBe(initial.refreshToken);
    expect(grace!.refreshToken).not.toBe(rotated!.refreshToken);
    expect(typeof grace!.accessToken).toBe('string');

    const followUp = await rotateRefreshToken(database, {
      refreshToken: grace!.refreshToken,
      jwtSecret,
      now: 2000 + 9 * 60 * 1000 + 1000,
    });
    expect(followUp).not.toBeNull();
  });

  it('twoConsecutiveLostResponsesWithinGraceSucceedWithoutExtendingDeadline', async () => {
    const { db } = createTestD1();
    const database = db as unknown as DatabaseClient;

    const initial = await createSessionForIdentity(database, {
      provider: 'apple',
      sub: 'grace-user-consecutive-1',
      email: null,
      deviceId: 'dev-1',
      jwtSecret,
      now: 1000,
    });

    const r1 = await rotateRefreshToken(database, {
      refreshToken: initial.refreshToken,
      jwtSecret,
      now: 2000,
    });
    expect(r1).not.toBeNull();

    // First lost-response grace retry at +8 min.
    const r2 = await rotateRefreshToken(database, {
      refreshToken: initial.refreshToken,
      jwtSecret,
      now: 2000 + 8 * 60 * 1000,
    });
    expect(r2).not.toBeNull();
    expect(r2!.refreshToken).not.toBe(initial.refreshToken);
    expect(r2!.refreshToken).not.toBe(r1!.refreshToken);

    // Second consecutive lost-response grace retry with the same R0 at +9 min.
    const r3 = await rotateRefreshToken(database, {
      refreshToken: initial.refreshToken,
      jwtSecret,
      now: 2000 + 9 * 60 * 1000,
    });
    expect(r3).not.toBeNull();
    expect(r3!.refreshToken).not.toBe(initial.refreshToken);
    expect(r3!.refreshToken).not.toBe(r1!.refreshToken);
    expect(r3!.refreshToken).not.toBe(r2!.refreshToken);

    // Latest grace-issued token r3 works for normal rotation.
    const r4 = await rotateRefreshToken(database, {
      refreshToken: r3!.refreshToken,
      jwtSecret,
      now: 2000 + 9 * 60 * 1000 + 1000,
    });
    expect(r4).not.toBeNull();

    // Once r3 has been used, retrying with R0 within 10 minutes must revoke the chain (including r4).
    const replayAfterR3Used = await rotateRefreshToken(database, {
      refreshToken: initial.refreshToken,
      jwtSecret,
      now: 2000 + 9 * 60 * 1000 + 2000,
    });
    expect(replayAfterR3Used).toBeNull();
    const r4After = await rotateRefreshToken(database, {
      refreshToken: r4!.refreshToken,
      jwtSecret,
      now: 2000 + 9 * 60 * 1000 + 3000,
    });
    expect(r4After).toBeNull();

    // Original 10-minute deadline from t=2000 must NOT be extended by an earlier grace retry.
    const initial2 = await createSessionForIdentity(database, {
      provider: 'apple',
      sub: 'grace-user-consecutive-2',
      email: null,
      deviceId: 'dev-1',
      jwtSecret,
      now: 1000,
    });
    await rotateRefreshToken(database, {
      refreshToken: initial2.refreshToken,
      jwtSecret,
      now: 2000,
    });
    const graceAt8Min = await rotateRefreshToken(database, {
      refreshToken: initial2.refreshToken,
      jwtSecret,
      now: 2000 + 8 * 60 * 1000,
    });
    expect(graceAt8Min).not.toBeNull();

    // 1ms past the original 10-minute deadline (only ~2 min after graceAt8Min) must fail and revoke the chain.
    const pastOriginalDeadline = await rotateRefreshToken(database, {
      refreshToken: initial2.refreshToken,
      jwtSecret,
      now: 2000 + TEN_MINUTES_MS + 1,
    });
    expect(pastOriginalDeadline).toBeNull();

    const afterDeadlineRevoke = await rotateRefreshToken(database, {
      refreshToken: graceAt8Min!.refreshToken,
      jwtSecret,
      now: 2000 + TEN_MINUTES_MS + 2,
    });
    expect(afterDeadlineRevoke).toBeNull();
  });

  it('graceRetryRevokesUnusedSuccessor', async () => {
    const { db } = createTestD1();
    const database = db as unknown as DatabaseClient;

    const initial = await createSessionForIdentity(database, {
      provider: 'apple',
      sub: 'grace-user-2',
      email: null,
      deviceId: 'dev-1',
      jwtSecret,
      now: 1000,
    });

    const rotated = await rotateRefreshToken(database, {
      refreshToken: initial.refreshToken,
      jwtSecret,
      now: 2000,
    });
    expect(rotated).not.toBeNull();

    const grace = await rotateRefreshToken(database, {
      refreshToken: initial.refreshToken,
      jwtSecret,
      now: 2000 + 60_000,
    });
    expect(grace).not.toBeNull();

    // The unused successor from the first rotation was revoked by the grace retry and no longer works.
    const successorAttempt = await rotateRefreshToken(database, {
      refreshToken: rotated!.refreshToken,
      jwtSecret,
      now: 2000 + 61_000,
    });
    expect(successorAttempt).toBeNull();

    // Presenting the revoked successor also revokes the chain (including the grace-issued token).
    const afterSuccessorReuse = await rotateRefreshToken(database, {
      refreshToken: grace!.refreshToken,
      jwtSecret,
      now: 2000 + 62_000,
    });
    expect(afterSuccessorReuse).toBeNull();
  });

  it('retryAfterSuccessorWasUsedRevokesChain', async () => {
    const { db } = createTestD1();
    const database = db as unknown as DatabaseClient;

    const initial = await createSessionForIdentity(database, {
      provider: 'apple',
      sub: 'grace-user-3',
      email: null,
      deviceId: 'dev-1',
      jwtSecret,
      now: 1000,
    });
    const otherChain = await createSessionForIdentity(database, {
      provider: 'apple',
      sub: 'grace-user-3',
      email: null,
      deviceId: 'dev-1',
      jwtSecret,
      now: 1001,
    });

    const s1 = await rotateRefreshToken(database, {
      refreshToken: initial.refreshToken,
      jwtSecret,
      now: 2000,
    });
    expect(s1).not.toBeNull();

    const s2 = await rotateRefreshToken(database, {
      refreshToken: s1!.refreshToken,
      jwtSecret,
      now: 3000,
    });
    expect(s2).not.toBeNull();

    // Presenting initial token within 10 minutes after s1 was already used must revoke the chain.
    const replay = await rotateRefreshToken(database, {
      refreshToken: initial.refreshToken,
      jwtSecret,
      now: 4000,
    });
    expect(replay).toBeNull();

    const s2After = await rotateRefreshToken(database, {
      refreshToken: s2!.refreshToken,
      jwtSecret,
      now: 5000,
    });
    expect(s2After).toBeNull();

    // Unrelated chain for the same user/device remains valid.
    const otherAfter = await rotateRefreshToken(database, {
      refreshToken: otherChain.refreshToken,
      jwtSecret,
      now: 5001,
    });
    expect(otherAfter).not.toBeNull();
  });

  it('retryAfterGraceWindowRevokesChain', async () => {
    const { db } = createTestD1();
    const database = db as unknown as DatabaseClient;

    const initial = await createSessionForIdentity(database, {
      provider: 'apple',
      sub: 'grace-user-4',
      email: null,
      deviceId: 'dev-1',
      jwtSecret,
      now: 1000,
    });

    const s1 = await rotateRefreshToken(database, {
      refreshToken: initial.refreshToken,
      jwtSecret,
      now: 2000,
    });
    expect(s1).not.toBeNull();

    const replay = await rotateRefreshToken(database, {
      refreshToken: initial.refreshToken,
      jwtSecret,
      now: 2000 + TEN_MINUTES_MS + 1,
    });
    expect(replay).toBeNull();

    const s1After = await rotateRefreshToken(database, {
      refreshToken: s1!.refreshToken,
      jwtSecret,
      now: 2000 + TEN_MINUTES_MS + 2,
    });
    expect(s1After).toBeNull();
  });

  it('concurrentGraceRetriesOnlyOneSucceeds', async () => {
    const { db } = createTestD1();
    const database = db as unknown as DatabaseClient;

    const initial = await createSessionForIdentity(database, {
      provider: 'apple',
      sub: 'grace-user-5',
      email: null,
      deviceId: 'dev-1',
      jwtSecret,
      now: 1000,
    });
    const s1 = await rotateRefreshToken(database, {
      refreshToken: initial.refreshToken,
      jwtSecret,
      now: 2000,
    });
    expect(s1).not.toBeNull();

    // Interleave B right before its batch while A completes its grace retry.
    let releaseB!: () => void;
    const bWait = new Promise<void>((resolve) => {
      releaseB = resolve;
    });
    let bReachedBatch!: () => void;
    const bAtBatch = new Promise<void>((resolve) => {
      bReachedBatch = resolve;
    });

    const bProxiedDb = new Proxy(database, {
      get(target, prop, receiver) {
        if (prop === 'batch') {
          return async (...args: Parameters<DatabaseClient['batch']>) => {
            bReachedBatch();
            await bWait;
            return target.batch(...args);
          };
        }
        return Reflect.get(target, prop, receiver);
      },
    });

    const bPromise = rotateRefreshToken(bProxiedDb, {
      refreshToken: initial.refreshToken,
      jwtSecret,
      now: 3001,
    });
    await bAtBatch;

    const aResult = await rotateRefreshToken(database, {
      refreshToken: initial.refreshToken,
      jwtSecret,
      now: 3000,
    });
    expect(aResult).not.toBeNull();

    releaseB();
    const bResult = await bPromise;
    expect(bResult).toBeNull();

    // Also verify parallel Promise.all grace retries on a fresh chain: only one can succeed.
    const initial2 = await createSessionForIdentity(database, {
      provider: 'apple',
      sub: 'grace-user-5b',
      email: null,
      deviceId: 'dev-1',
      jwtSecret,
      now: 1000,
    });
    await rotateRefreshToken(database, {
      refreshToken: initial2.refreshToken,
      jwtSecret,
      now: 2000,
    });

    const parallelResults = await Promise.all([
      rotateRefreshToken(database, {
        refreshToken: initial2.refreshToken,
        jwtSecret,
        now: 3000,
      }),
      rotateRefreshToken(database, {
        refreshToken: initial2.refreshToken,
        jwtSecret,
        now: 3001,
      }),
    ]);
    expect(parallelResults.filter((r) => r !== null)).toHaveLength(1);
    expect(parallelResults.filter((r) => r === null)).toHaveLength(1);
  });
});

describe('login and refresh state fields (hasData, meMemberId, inboxProjectId)', () => {
  const jwtSecret = 'unit-test-jwt-secret-32-bytes-minimum';

  it('returns hasData=false and null ids on new account, and reflects inbox + meMemberId on login and refresh', async () => {
    const { db } = createTestD1();
    const database = db as unknown as DatabaseClient;
    const inboxId = 'proj-inbox-1';
    const workId = 'proj-work-1';
    const scopeCalls: Array<{ scope: string; readableProjectIds: string[] }> = [];

    const getScopeStub = (scope: string) => ({
      async getInboxProjectId(input: { readableProjectIds: string[] }) {
        scopeCalls.push({ scope, readableProjectIds: input.readableProjectIds });
        return input.readableProjectIds.includes(inboxId) ? inboxId : null;
      },
    });

    // 1. New account -> hasData=false, meMemberId=null, inboxProjectId=null
    const first = await createSessionForIdentity(database, {
      provider: 'apple',
      sub: 'state-user-1',
      email: null,
      deviceId: 'dev-1',
      jwtSecret,
      now: 1000,
      getScopeStub,
    });
    expect(first).toMatchObject({
      user: { id: first.user.id },
      isNewAccount: true,
      hasData: false,
      meMemberId: null,
      inboxProjectId: null,
    });
    expect(scopeCalls).toHaveLength(0);

    // 2. User has meMemberId and a regular list, but no inbox -> hasData=false, inboxProjectId=null
    await db
      .update(schema.user)
      .set({ meMemberId: 'mem-me-1' })
      .where(eq(schema.user.id, first.user.id));
    await db.insert(schema.projectMembership).values({
      projectId: workId,
      userId: first.user.id,
      role: 'owner',
      createdAt: 1001,
      removedAt: null,
    });

    const second = await createSessionForIdentity(database, {
      provider: 'apple',
      sub: 'state-user-1',
      email: null,
      deviceId: 'dev-2',
      jwtSecret,
      now: 1002,
      getScopeStub,
    });
    expect(second).toMatchObject({
      user: { id: first.user.id },
      isNewAccount: false,
      hasData: false,
      meMemberId: 'mem-me-1',
      inboxProjectId: null,
    });
    expect(scopeCalls[0]).toEqual({
      scope: `u:${first.user.id}`,
      readableProjectIds: [workId],
    });

    // 3. Add readable inbox membership -> login and refresh both return hasData=true + both ids
    await db.insert(schema.projectMembership).values({
      projectId: inboxId,
      userId: first.user.id,
      role: 'owner',
      createdAt: 1003,
      removedAt: null,
    });

    const third = await createSessionForIdentity(database, {
      provider: 'apple',
      sub: 'state-user-1',
      email: null,
      deviceId: 'dev-2',
      jwtSecret,
      now: 1004,
      getScopeStub,
    });
    expect(third).toMatchObject({
      isNewAccount: false,
      hasData: true,
      meMemberId: 'mem-me-1',
      inboxProjectId: inboxId,
    });

    const refreshed = await rotateRefreshToken(database, {
      refreshToken: third.refreshToken,
      jwtSecret,
      now: 1005,
      getScopeStub,
    });
    expect(refreshed).toMatchObject({
      hasData: true,
      meMemberId: 'mem-me-1',
      inboxProjectId: inboxId,
    });

    // 4. Removed inbox membership -> no longer readable -> hasData=false, inboxProjectId=null
    await db
      .update(schema.projectMembership)
      .set({ removedAt: 1006 })
      .where(eq(schema.projectMembership.projectId, inboxId));

    const refreshedAfterRemove = await rotateRefreshToken(database, {
      refreshToken: refreshed!.refreshToken,
      jwtSecret,
      now: 1007,
      getScopeStub,
    });
    expect(refreshedAfterRemove).toMatchObject({
      hasData: false,
      meMemberId: 'mem-me-1',
      inboxProjectId: null,
    });
  });

  it('keeps the refresh token valid if Scope.getInboxProjectId fails transiently and allows retry on recovery', async () => {
    const { db } = createTestD1();
    const database = db as unknown as DatabaseClient;
    const inboxId = 'proj-inbox-transient';

    const initial = await createSessionForIdentity(database, {
      provider: 'apple',
      sub: 'transient-refresh-user',
      email: null,
      deviceId: 'dev-1',
      jwtSecret,
      now: 1000,
    });

    await db.insert(schema.projectMembership).values({
      projectId: inboxId,
      userId: initial.user.id,
      role: 'owner',
      createdAt: 1001,
      removedAt: null,
    });

    const failingScopeStub = () => ({
      async getInboxProjectId() {
        throw new Error('DO transient');
      },
    });
    const workingScopeStub = () => ({
      async getInboxProjectId(input: { readableProjectIds: string[] }) {
        return input.readableProjectIds.includes(inboxId) ? inboxId : null;
      },
    });

    await expect(
      rotateRefreshToken(database, {
        refreshToken: initial.refreshToken,
        jwtSecret,
        now: 2000,
        getScopeStub: failingScopeStub,
      }),
    ).rejects.toThrow('DO transient');

    const sessionsAfterFailure = await db.select().from(schema.session);
    expect(sessionsAfterFailure).toHaveLength(1);
    expect(sessionsAfterFailure[0].revokedAt).toBeNull();

    const recovered = await rotateRefreshToken(database, {
      refreshToken: initial.refreshToken,
      jwtSecret,
      now: 2001,
      getScopeStub: workingScopeStub,
    });
    expect(recovered).not.toBeNull();
    expect(recovered).toMatchObject({
      hasData: true,
      meMemberId: null,
      inboxProjectId: inboxId,
    });
    expect(recovered!.refreshToken).not.toBe(initial.refreshToken);

    const sessionsAfterRecovery = await db.select().from(schema.session);
    expect(sessionsAfterRecovery).toHaveLength(2);
    expect(sessionsAfterRecovery.filter((s) => s.revokedAt === null)).toHaveLength(1);
    expect(sessionsAfterRecovery.filter((s) => s.revokedAt !== null)).toHaveLength(1);
  });

  it('does not insert an orphaned session row on login if Scope.getInboxProjectId fails transiently', async () => {
    const { db } = createTestD1();
    const database = db as unknown as DatabaseClient;
    const inboxId = 'proj-inbox-login-transient';

    const initial = await createSessionForIdentity(database, {
      provider: 'apple',
      sub: 'transient-login-user',
      email: null,
      deviceId: 'dev-1',
      jwtSecret,
      now: 1000,
    });

    await db.insert(schema.projectMembership).values({
      projectId: inboxId,
      userId: initial.user.id,
      role: 'owner',
      createdAt: 1001,
      removedAt: null,
    });

    const failingScopeStub = () => ({
      async getInboxProjectId() {
        throw new Error('DO transient');
      },
    });
    const workingScopeStub = () => ({
      async getInboxProjectId(input: { readableProjectIds: string[] }) {
        return input.readableProjectIds.includes(inboxId) ? inboxId : null;
      },
    });

    await expect(
      createSessionForIdentity(database, {
        provider: 'apple',
        sub: 'transient-login-user',
        email: null,
        deviceId: 'dev-2',
        jwtSecret,
        now: 2000,
        getScopeStub: failingScopeStub,
      }),
    ).rejects.toThrow('DO transient');

    const sessionsAfterFailure = await db.select().from(schema.session);
    expect(sessionsAfterFailure).toHaveLength(1);

    const recovered = await createSessionForIdentity(database, {
      provider: 'apple',
      sub: 'transient-login-user',
      email: null,
      deviceId: 'dev-2',
      jwtSecret,
      now: 2001,
      getScopeStub: workingScopeStub,
    });
    expect(recovered).toMatchObject({
      isNewAccount: false,
      hasData: true,
      meMemberId: null,
      inboxProjectId: inboxId,
    });
    const sessionsAfterRecovery = await db.select().from(schema.session);
    expect(sessionsAfterRecovery).toHaveLength(2);
  });
});
