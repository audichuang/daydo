import { identity, oauthClient, oauthPending, user } from '@schema';
import { and, count, eq, gt, isNotNull, isNull } from 'void/db';
import { sha256Hex } from '../auth/crypto';
import { AuthVerificationError, verifyAppleToken, type ProviderName, type VerifiedIdentity } from '../auth/providers';
import type { DatabaseClient } from '../auth/session';
import { createAuthorizationCode } from './codes';
import { SCOPES, requestOrigin } from './metadata';
import { consentPage, errorPage, loginPage } from './pages';
import { ipRateKey } from './register';
import { randomB64url } from './tokens';
import {
  PROVIDER_LABELS,
  WEB_PROVIDERS,
  isProviderAvailable,
  isWebProvider,
  providerAuthorizeUrl,
  type WebIdentityConfig,
} from './webIdentity';

// OAuth 2.1 authorization endpoint (spec/mcp.md 4.4). The browser that starts the flow gets
// a random bind cookie named after the pending (D1 stores its hash); both callbacks, the consent page and the consent
// POST compare it, so the browser that signs in must be the browser that started.

const BIND_COOKIE_PREFIX = 'daydo_oauth_bind_';
const BIND_COOKIE_ID_LENGTH = 16;

/** One cookie per pending, so several authorize tabs in one browser do not overwrite each other. */
export function bindCookieName(pendingId: string): string {
  return `${BIND_COOKIE_PREFIX}${pendingId.slice(0, BIND_COOKIE_ID_LENGTH)}`;
}
export const PENDING_TTL_MS = 10 * 60 * 1000;
/** Pending rows one address may create per hour (spec/mcp.md 4.4). */
export const AUTHORIZE_LIMIT_PER_HOUR = 30;
const LIMIT_WINDOW_MS = 60 * 60 * 1000;

export type PendingRow = typeof oauthPending.$inferSelect;

export interface AuthorizeDeps {
  database: DatabaseClient;
  web: WebIdentityConfig;
  now?: number;
}

const MESSAGES = {
  expired: '這個授權流程已失效或已完成，請回到應用程式重新開始連線。',
  bindMismatch: '請在開始授權的同一個瀏覽器完成登入。這個授權流程已終止，請回到應用程式重新開始連線。',
  wrongBrowser: '請在開始授權的同一個瀏覽器繼續。',
  cancelled: '登入已取消，請重新開始：可以再按一次登入按鈕。',
  providerError: '無法驗證登入結果，請再試一次。',
  unknownIdentity: '這個 Google／Apple 帳號還沒有 DayDo 帳號，請先在 DayDo App 用同一個帳號登入一次。',
  tooManyRequests: '這個網路位址開始的授權次數太多，請稍後再試。',
} as const;

function stringField(form: Record<string, unknown>, key: string): string {
  const value = form[key];
  return typeof value === 'string' ? value : '';
}

function readCookie(request: Request, name: string): string | null {
  const header = request.headers.get('Cookie');
  if (!header) return null;
  for (const part of header.split(';')) {
    const eqIndex = part.indexOf('=');
    if (eqIndex === -1) continue;
    if (part.slice(0, eqIndex).trim() === name) return part.slice(eqIndex + 1).trim();
  }
  return null;
}

async function cookieMatches(request: Request, pending: PendingRow): Promise<boolean> {
  const value = readCookie(request, bindCookieName(pending.id));
  return value !== null && value.length > 0 && (await sha256Hex(value)) === pending.bindHash;
}

function bindCookieHeader(pendingId: string, value: string): string {
  return `${bindCookieName(pendingId)}=${value}; HttpOnly; Secure; SameSite=None; Path=/authorize; Max-Age=${PENDING_TTL_MS / 1000}`;
}

/** Loads an open pending row: not consumed and not expired. */
async function loadOpenPending(database: DatabaseClient, id: string, now: number): Promise<PendingRow | undefined> {
  if (!id) return undefined;
  const row = await database.select().from(oauthPending).where(eq(oauthPending.id, id)).get();
  if (!row || row.consumedAt !== null || row.expiresAt <= now) return undefined;
  return row;
}

async function endPending(database: DatabaseClient, id: string, now: number): Promise<void> {
  await database
    .update(oauthPending)
    .set({ consumedAt: now })
    .where(and(eq(oauthPending.id, id), isNull(oauthPending.consumedAt)));
}

// ---------------------------------------------------------------------------
// GET /authorize (no pending): validate, create pending, set cookie, show buttons.

interface AuthParams {
  responseType: string;
  clientId: string;
  redirectUri: string;
  scope: string;
  state: string;
  codeChallenge: string;
  codeChallengeMethod: string;
  resource: string;
}

function normalizeScope(scope: string): string {
  return Array.from(new Set(scope.split(/\s+/).filter(Boolean))).join(' ');
}

function extractParams(sp: URLSearchParams): AuthParams {
  return {
    responseType: sp.get('response_type') ?? '',
    clientId: sp.get('client_id') ?? '',
    redirectUri: sp.get('redirect_uri') ?? '',
    scope: normalizeScope(sp.get('scope') ?? 'mcp'),
    state: sp.get('state') ?? '',
    codeChallenge: sp.get('code_challenge') ?? '',
    codeChallengeMethod: sp.get('code_challenge_method') ?? '',
    resource: sp.get('resource') ?? '',
  };
}

/** REF validateParams, minus the redirect_uri shape check (exact registration match replaces it). */
function validateParams(p: AuthParams): string | null {
  if (p.responseType !== 'code') return `不支援的 response_type：${p.responseType}`;
  if (!p.clientId) return '缺少 client_id';
  if (!p.redirectUri) return '缺少 redirect_uri';
  if (!p.codeChallenge) return '缺少 code_challenge（必須使用 PKCE）';
  if (p.codeChallengeMethod !== 'S256') return '只支援 code_challenge_method=S256';
  const scopes = p.scope.split(' ').filter(Boolean);
  const unsupported = scopes.filter((scope) => !SCOPES.includes(scope));
  if (unsupported.length > 0) return `不支援的 scope：${unsupported.join(', ')}`;
  if (!scopes.includes('mcp')) return 'scope 必須包含 mcp';
  return null;
}

function resourceMatches(resource: string, origin: string): boolean {
  try {
    return new URL(resource).origin === origin;
  } catch {
    return false;
  }
}

function registeredRedirects(raw: string): string[] {
  try {
    const value: unknown = JSON.parse(raw);
    return Array.isArray(value) ? value.filter((v): v is string => typeof v === 'string') : [];
  } catch {
    return [];
  }
}

async function beginAuthorization(request: Request, deps: AuthorizeDeps, now: number): Promise<Response> {
  const origin = requestOrigin(request.url);
  const params = extractParams(new URL(request.url).searchParams);
  const problem = validateParams(params);
  if (problem) return errorPage(problem);

  const client = await deps.database
    .select()
    .from(oauthClient)
    .where(eq(oauthClient.clientId, params.clientId))
    .get();
  if (!client) return errorPage('未註冊的 client_id');
  if (!registeredRedirects(client.redirectUris).includes(params.redirectUri)) {
    return errorPage('redirect_uri 與註冊的導向網址不符');
  }
  if (params.resource && !resourceMatches(params.resource, origin)) {
    return errorPage('invalid_target：resource 必須是這台伺服器');
  }

  const ipHash = await sha256Hex(`authorize|${ipRateKey(request.headers.get('CF-Connecting-IP'))}`);
  const [{ n }] = await deps.database
    .select({ n: count() })
    .from(oauthPending)
    .where(and(eq(oauthPending.ipHash, ipHash), gt(oauthPending.createdAt, now - LIMIT_WINDOW_MS)));
  if (n >= AUTHORIZE_LIMIT_PER_HOUR) return errorPage(MESSAGES.tooManyRequests, 429);

  const pendingId = randomB64url(32);
  const bindToken = randomB64url(32);
  await deps.database.insert(oauthPending).values({
    id: pendingId,
    clientId: params.clientId,
    redirectUri: params.redirectUri,
    codeChallenge: params.codeChallenge,
    scope: params.scope,
    clientState: params.state || null,
    resource: params.resource || null,
    bindHash: await sha256Hex(bindToken),
    provider: '',
    nonce: randomB64url(32),
    userId: null,
    consentTokenHash: null,
    createdAt: now,
    expiresAt: now + PENDING_TTL_MS,
    consumedAt: null,
    ipHash,
  });

  return loginPage({
    clientName: client.clientName,
    buttons: WEB_PROVIDERS.map((provider) => ({
      label: PROVIDER_LABELS[provider],
      href: isProviderAvailable(deps.web, provider)
        ? `/authorize/start?pending=${encodeURIComponent(pendingId)}&provider=${provider}`
        : null,
    })),
    setCookie: bindCookieHeader(pendingId, bindToken),
  });
}

// ---------------------------------------------------------------------------
// Consent: GET /authorize?pending&ct shows the page, POST /authorize decides.

/** Pending bound to a user whose cookie and consent token both match, or null. */
async function loadConsentPending(
  request: Request,
  deps: AuthorizeDeps,
  pendingId: string,
  consentToken: string,
  now: number,
): Promise<PendingRow | null> {
  const pending = await loadOpenPending(deps.database, pendingId, now);
  if (!pending || pending.userId === null || pending.consentTokenHash === null || !consentToken) return null;
  if (!(await cookieMatches(request, pending))) return null;
  if ((await sha256Hex(consentToken)) !== pending.consentTokenHash) return null;
  return pending;
}

async function showConsent(request: Request, deps: AuthorizeDeps, now: number): Promise<Response> {
  const sp = new URL(request.url).searchParams;
  const pendingId = sp.get('pending') ?? '';
  const consentToken = sp.get('ct') ?? '';
  const pending = await loadConsentPending(request, deps, pendingId, consentToken, now);
  if (!pending || pending.userId === null) return errorPage(MESSAGES.expired);

  const [account, client] = await Promise.all([
    deps.database.select({ name: user.name }).from(user).where(eq(user.id, pending.userId)).get(),
    deps.database
      .select({ clientName: oauthClient.clientName })
      .from(oauthClient)
      .where(eq(oauthClient.clientId, pending.clientId))
      .get(),
  ]);
  if (!account) return errorPage(MESSAGES.expired);

  return consentPage({
    userName: account.name || 'DayDo 使用者',
    clientName: client?.clientName ?? pending.clientId,
    redirectHost: new URL(pending.redirectUri).host,
    pendingId: pending.id,
    consentToken,
  });
}

export function handleAuthorizeGet(request: Request, deps: AuthorizeDeps): Promise<Response> {
  const now = deps.now ?? Date.now();
  if (new URL(request.url).searchParams.has('pending')) return showConsent(request, deps, now);
  return beginAuthorization(request, deps, now);
}

export async function handleAuthorizePost(
  request: Request,
  form: Record<string, unknown>,
  deps: AuthorizeDeps,
): Promise<Response> {
  const now = deps.now ?? Date.now();
  const pendingId = stringField(form, 'pending');
  const consentToken = stringField(form, 'ct');
  const decision = stringField(form, 'decision');
  if (decision !== 'approve' && decision !== 'deny') return errorPage('無效的選擇');

  const pending = await loadConsentPending(request, deps, pendingId, consentToken, now);
  if (!pending) return errorPage(MESSAGES.expired);

  // Single conditional write: only one request can consume the pending.
  const [consumed] = await deps.database
    .update(oauthPending)
    .set({ consumedAt: now })
    .where(
      and(
        eq(oauthPending.id, pending.id),
        isNull(oauthPending.consumedAt),
        isNotNull(oauthPending.userId),
        eq(oauthPending.consentTokenHash, await sha256Hex(consentToken)),
        gt(oauthPending.expiresAt, now),
      ),
    )
    .returning();
  if (!consumed || consumed.userId === null) return errorPage(MESSAGES.expired);

  const redirect = new URL(consumed.redirectUri);
  if (decision === 'approve') {
    const code = await createAuthorizationCode(deps.database, {
      clientId: consumed.clientId,
      redirectUri: consumed.redirectUri,
      codeChallenge: consumed.codeChallenge,
      scope: consumed.scope,
      resource: consumed.resource,
      userId: consumed.userId,
      now,
    });
    redirect.searchParams.set('code', code);
  } else {
    redirect.searchParams.set('error', 'access_denied');
  }
  if (consumed.clientState) redirect.searchParams.set('state', consumed.clientState);
  return new Response(null, { status: 302, headers: { Location: redirect.toString(), 'Cache-Control': 'no-store' } });
}

// ---------------------------------------------------------------------------
// GET /authorize/start?pending&provider: compare cookie, record provider, go to provider.

export async function handleAuthorizeStart(request: Request, deps: AuthorizeDeps): Promise<Response> {
  const now = deps.now ?? Date.now();
  const sp = new URL(request.url).searchParams;
  const provider = sp.get('provider') ?? '';
  if (!isWebProvider(provider) || !isProviderAvailable(deps.web, provider)) {
    return errorPage('這個登入方式未設定');
  }

  const pending = await loadOpenPending(deps.database, sp.get('pending') ?? '', now);
  if (!pending || pending.userId !== null) return errorPage(MESSAGES.expired);
  if (!(await cookieMatches(request, pending))) return errorPage(MESSAGES.wrongBrowser);

  const location = await providerAuthorizeUrl(deps.web, provider, {
    origin: requestOrigin(request.url),
    state: pending.id,
    rawNonce: pending.nonce,
  });
  if (!location) return errorPage('這個登入方式未設定');

  // The provider may change while unbound, so a user can pick the other button after cancelling.
  const [updated] = await deps.database
    .update(oauthPending)
    .set({ provider })
    .where(
      and(
        eq(oauthPending.id, pending.id),
        isNull(oauthPending.consumedAt),
        isNull(oauthPending.userId),
        gt(oauthPending.expiresAt, now),
      ),
    )
    .returning({ id: oauthPending.id });
  if (!updated) return errorPage(MESSAGES.expired);

  return new Response(null, { status: 302, headers: { Location: location, 'Cache-Control': 'no-store' } });
}

// ---------------------------------------------------------------------------
// Callbacks (shared by Apple here and Google in routes/authorize/google/callback.ts).

export type CallbackCheck = { ok: true; pending: PendingRow } | { ok: false; response: Response };

/**
 * Callback preamble: load the pending by state, check it is open and was started with this
 * provider, compare the bind cookie (a mismatch ends the pending), then handle a provider
 * `error` (which keeps the pending so the user can retry).
 */
export async function openCallbackPending(
  request: Request,
  deps: AuthorizeDeps,
  params: { provider: ProviderName; state: string; error: string },
): Promise<CallbackCheck> {
  const now = deps.now ?? Date.now();
  const pending = await loadOpenPending(deps.database, params.state, now);
  if (!pending || pending.provider !== params.provider || pending.userId !== null) {
    return { ok: false, response: errorPage(MESSAGES.expired) };
  }
  if (!(await cookieMatches(request, pending))) {
    await endPending(deps.database, pending.id, now);
    return { ok: false, response: errorPage(MESSAGES.bindMismatch) };
  }
  if (params.error) return { ok: false, response: errorPage(MESSAGES.cancelled) };
  return { ok: true, pending };
}

/** A failed or missing id_token: retryable, so the pending is kept. */
export function providerErrorPage(): Response {
  return errorPage(MESSAGES.providerError);
}

/**
 * Maps a verified provider identity to an existing DayDo user (read-only: never creates an
 * account), binds it to the pending once, and redirects to the consent page.
 */
export async function bindIdentity(
  request: Request,
  deps: AuthorizeDeps,
  pending: PendingRow,
  verified: VerifiedIdentity,
): Promise<Response> {
  const now = deps.now ?? Date.now();
  const found = await deps.database
    .select({ userId: identity.userId })
    .from(identity)
    .where(and(eq(identity.provider, verified.provider), eq(identity.sub, verified.sub)))
    .get();
  if (!found) {
    return errorPage(MESSAGES.unknownIdentity, 403);
  }

  const consentToken = randomB64url(32);
  const [bound] = await deps.database
    .update(oauthPending)
    .set({ userId: found.userId, consentTokenHash: await sha256Hex(consentToken) })
    .where(
      and(
        eq(oauthPending.id, pending.id),
        isNull(oauthPending.userId),
        isNull(oauthPending.consumedAt),
        gt(oauthPending.expiresAt, now),
      ),
    )
    .returning({ id: oauthPending.id });
  if (!bound) return errorPage(MESSAGES.expired);

  const consent = new URL('/authorize', requestOrigin(request.url));
  consent.searchParams.set('pending', pending.id);
  consent.searchParams.set('ct', consentToken);
  return new Response(null, { status: 303, headers: { Location: consent.toString(), 'Cache-Control': 'no-store' } });
}

/** POST /authorize/apple/callback (form_post). The authorization `code` is discarded. */
export async function handleAppleCallback(
  request: Request,
  form: Record<string, unknown>,
  deps: AuthorizeDeps,
): Promise<Response> {
  const check = await openCallbackPending(request, deps, {
    provider: 'apple',
    state: stringField(form, 'state'),
    error: stringField(form, 'error'),
  });
  if (!check.ok) return check.response;

  const idToken = stringField(form, 'id_token');
  if (!idToken) return providerErrorPage();
  let verified: VerifiedIdentity;
  try {
    verified = await verifyAppleToken({
      identityToken: idToken,
      nonce: check.pending.nonce,
      audience: deps.web.apple.audience,
      jwksUrl: deps.web.apple.jwksUrl,
      keySource: deps.web.apple.keySource,
    });
  } catch (error) {
    if (error instanceof AuthVerificationError) return providerErrorPage();
    throw error;
  }
  return bindIdentity(request, deps, check.pending, verified);
}
