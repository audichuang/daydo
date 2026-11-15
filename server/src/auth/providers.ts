import { createRemoteJWKSet, jwtVerify, type CryptoKey, type JWTVerifyGetKey, type JWTVerifyOptions } from 'jose';
import { sha256Hex } from './crypto';

export type ProviderName = 'apple' | 'google';

export interface VerifiedIdentity {
  provider: ProviderName;
  sub: string;
  email: string | null;
  avatarUrl?: string | null;
}

export function sanitizeHttpsAvatarUrl(raw: unknown): string | null {
  if (typeof raw !== 'string') return null;
  const trimmed = raw.trim();
  if (!trimmed) return null;
  try {
    const parsed = new URL(trimmed);
    if (parsed.protocol !== 'https:' || !parsed.hostname) {
      return null;
    }
    return parsed.toString();
  } catch {
    return null;
  }
}

export type KeySource = JWTVerifyGetKey | CryptoKey;

export class AuthVerificationError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'AuthVerificationError';
  }
}

const jwksCache = new Map<string, JWTVerifyGetKey>();

function getRemoteJwks(jwksUrl: string): JWTVerifyGetKey {
  let cached = jwksCache.get(jwksUrl);
  if (!cached) {
    cached = createRemoteJWKSet(new URL(jwksUrl));
    jwksCache.set(jwksUrl, cached);
  }
  return cached;
}

async function verifyJwtWithSource(
  token: string,
  keySource: KeySource,
  options: JWTVerifyOptions,
) {
  try {
    if (typeof keySource === 'function') {
      return await jwtVerify(token, keySource, options);
    }
    return await jwtVerify(token, keySource, options);
  } catch (error) {
    throw new AuthVerificationError(
      error instanceof Error ? error.message : 'Token verification failed',
    );
  }
}

export async function verifyAppleToken(params: {
  identityToken: string;
  nonce: string;
  audience: string;
  jwksUrl?: string;
  keySource?: KeySource;
  currentDate?: Date;
}): Promise<VerifiedIdentity> {
  if (!params.nonce) {
    throw new AuthVerificationError('Missing nonce');
  }
  const keySource = params.keySource ?? getRemoteJwks(params.jwksUrl ?? 'https://appleid.apple.com/auth/keys');
  const { payload } = await verifyJwtWithSource(params.identityToken, keySource, {
    issuer: 'https://appleid.apple.com',
    audience: params.audience,
    currentDate: params.currentDate,
  });

  if (typeof payload.sub !== 'string' || payload.sub.length === 0) {
    throw new AuthVerificationError('Missing subject');
  }
  const expectedNonceHash = await sha256Hex(params.nonce);
  if (typeof payload.nonce !== 'string' || payload.nonce !== expectedNonceHash) {
    throw new AuthVerificationError('Nonce mismatch');
  }

  return {
    provider: 'apple',
    sub: payload.sub,
    email: typeof payload.email === 'string' && payload.email.length > 0 ? payload.email : null,
  };
}

export async function verifyGoogleToken(params: {
  idToken: string;
  audience: string;
  jwksUrl?: string;
  keySource?: KeySource;
  currentDate?: Date;
}): Promise<VerifiedIdentity> {
  if (!params.audience) {
    throw new AuthVerificationError('Missing Google audience');
  }
  const keySource =
    params.keySource ?? getRemoteJwks(params.jwksUrl ?? 'https://www.googleapis.com/oauth2/v3/certs');
  const { payload } = await verifyJwtWithSource(params.idToken, keySource, {
    issuer: ['accounts.google.com', 'https://accounts.google.com'],
    audience: params.audience,
    currentDate: params.currentDate,
  });

  if (typeof payload.sub !== 'string' || payload.sub.length === 0) {
    throw new AuthVerificationError('Missing subject');
  }

  return {
    provider: 'google',
    sub: payload.sub,
    email: typeof payload.email === 'string' && payload.email.length > 0 ? payload.email : null,
    avatarUrl: sanitizeHttpsAvatarUrl(payload.picture),
  };
}
