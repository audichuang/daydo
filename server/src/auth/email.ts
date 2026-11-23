import { nonEmptyString } from '../http';
import type { Mailer } from '../mail/mailer';
import { normalizeEmail, startEmailCode } from './emailCode';
import {
  createSessionForIdentity,
  type AuthSessionResult,
  type DatabaseClient,
  type ScopeLookup,
} from './session';
import { verifyCredential } from './verifyCredential';

export {
  EMAIL_CODE_MAX_ATTEMPTS,
  EMAIL_CODE_TTL_MS,
  EMAIL_LOCKOUT_FAILURES,
  EMAIL_LOCKOUT_WINDOW_MS,
  EMAIL_START_LIMIT_PER_EMAIL,
  EMAIL_START_LIMIT_PER_IP,
  generateEmailCode,
  normalizeEmail,
  startEmailCode,
  verifyEmailCode,
  type EmailStartOutcome,
} from './emailCode';

export interface EmailRouteResult {
  status: 200 | 202 | 400 | 401;
  body: Record<string, unknown>;
}

/** POST /auth/email/start: always 202 for a well-formed body (limits and mail failures included). */
export async function handleEmailStart(
  database: DatabaseClient,
  params: { body: Record<string, unknown> | null; ip: string | null; mailer: Mailer; now?: number },
): Promise<EmailRouteResult> {
  const email = normalizeEmail(params.body?.email);
  const deviceId = nonEmptyString(params.body?.deviceId);
  if (!email || !deviceId) {
    return { status: 400, body: { error: 'A valid email and deviceId are required' } };
  }
  await startEmailCode(database, { email, ip: params.ip, mailer: params.mailer, now: params.now });
  return { status: 202, body: { sent: true } };
}

/**
 * POST /auth/email/verify: the first success creates the user and the ('email', address) identity,
 * later ones log the same user in; the response matches /auth/google. Wrong, expired, used and
 * locked codes all get the same 401.
 */
export async function handleEmailVerify(
  database: DatabaseClient,
  params: {
    body: Record<string, unknown> | null;
    jwtSecret: string;
    getScopeStub?: ScopeLookup;
    now?: number;
  },
): Promise<EmailRouteResult> {
  const deviceId = nonEmptyString(params.body?.deviceId);
  if (!deviceId) {
    return { status: 400, body: { error: 'A valid email, code and deviceId are required' } };
  }
  const verified = await verifyCredential({
    provider: 'email',
    database,
    email: params.body?.email,
    code: params.body?.code,
    logEventName: 'auth.email.verify',
    now: params.now,
  });
  if (!verified.ok) {
    return {
      status: verified.status === 400 ? 400 : 401,
      body: {
        error:
          verified.status === 400
            ? 'A valid email, code and deviceId are required'
            : verified.error,
      },
    };
  }
  const result: AuthSessionResult = await createSessionForIdentity(database, {
    ...verified.identity,
    deviceId,
    jwtSecret: params.jwtSecret,
    now: params.now,
    getScopeStub: params.getScopeStub,
  });
  return { status: 200, body: { ...result } };
}
