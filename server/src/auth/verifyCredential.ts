import { nonEmptyString } from '../http';
import { logEvent } from '../log';
import { normalizeEmail, verifyEmailCode } from './emailCode';
import {
  AuthVerificationError,
  verifyAppleToken,
  verifyGoogleToken,
  type KeySource,
  type VerifiedIdentity,
} from './providers';
import type { DatabaseClient } from './session';

export type CredentialInput =
  | {
      provider: 'apple';
      identityToken: unknown;
      nonce: unknown;
      audience: string;
      jwksUrl?: string;
      keySource?: KeySource;
      now?: number;
    }
  | {
      provider: 'google';
      idToken: unknown;
      audience?: string;
      jwksUrl?: string;
      keySource?: KeySource;
      now?: number;
    }
  | {
      provider: 'email';
      database: DatabaseClient;
      email: unknown;
      code: unknown;
      logEventName: string;
      now?: number;
    };

export type CredentialVerificationResult =
  | { ok: true; identity: VerifiedIdentity }
  | { ok: false; status: 400 | 401 | 500; error: string };

/**
 * Single credential verification entry point shared by App login routes
 * (`/auth/apple`, `/auth/google`, `/auth/email/verify`) and account linking (`/auth/link`).
 */
export async function verifyCredential(
  input: CredentialInput,
): Promise<CredentialVerificationResult> {
  const currentDate = input.now !== undefined ? new Date(input.now) : undefined;

  switch (input.provider) {
    case 'apple': {
      const identityToken = nonEmptyString(input.identityToken);
      const nonce = nonEmptyString(input.nonce);
      if (!identityToken || !nonce) {
        return { ok: false, status: 400, error: 'identityToken and nonce are required' };
      }
      try {
        const identity = await verifyAppleToken({
          identityToken,
          nonce,
          audience: input.audience,
          jwksUrl: input.jwksUrl,
          keySource: input.keySource,
          currentDate,
        });
        return { ok: true, identity };
      } catch (error) {
        if (error instanceof AuthVerificationError) {
          return { ok: false, status: 401, error: error.message };
        }
        throw error;
      }
    }
    case 'google': {
      const idToken = nonEmptyString(input.idToken);
      if (!idToken) {
        return { ok: false, status: 400, error: 'idToken is required' };
      }
      if (!input.audience) {
        return { ok: false, status: 500, error: 'Google auth is not configured' };
      }
      try {
        const identity = await verifyGoogleToken({
          idToken,
          audience: input.audience,
          jwksUrl: input.jwksUrl,
          keySource: input.keySource,
          currentDate,
        });
        return { ok: true, identity };
      } catch (error) {
        if (error instanceof AuthVerificationError) {
          return { ok: false, status: 401, error: error.message };
        }
        throw error;
      }
    }
    case 'email': {
      const email = normalizeEmail(input.email);
      const code = input.code;
      if (!email || typeof code !== 'string') {
        return { ok: false, status: 400, error: 'A valid email and code are required' };
      }
      const ok = await verifyEmailCode(input.database, {
        email,
        code: code.trim(),
        now: input.now,
      });
      logEvent(ok ? 'log' : 'warn', input.logEventName, { outcome: ok ? 'ok' : 'invalid_code' });
      if (!ok) {
        return { ok: false, status: 401, error: 'Invalid or expired code' };
      }
      return { ok: true, identity: { provider: 'email', sub: email, email } };
    }
  }
}
