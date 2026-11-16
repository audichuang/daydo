import { sha256Hex } from '../auth/crypto';
import {
  AuthVerificationError,
  verifyGoogleToken,
  type KeySource,
  type ProviderName,
  type VerifiedIdentity,
} from '../auth/providers';
import { bindIdentity, openCallbackPending, providerErrorPage, type AuthorizeDeps } from './authorize';

// Web sign-in with Google / Apple for /authorize (spec/mcp.md 4.4 steps 2-3).

export interface AppleWebConfig {
  authUrl: string;
  /** Services ID; both the authorize client_id and the id_token audience. */
  audience: string;
  jwksUrl?: string;
  /** Test-only key source; production fetches jwksUrl. */
  keySource?: KeySource;
}

export interface GoogleWebConfig {
  clientId: string;
  clientSecret: string | undefined;
  authUrl: string;
  tokenUrl: string;
  jwksUrl?: string;
  /** Test-only key source; production fetches jwksUrl. */
  keySource?: KeySource;
}

export interface WebIdentityConfig {
  apple: AppleWebConfig;
  google: GoogleWebConfig;
}

export interface WebIdentityEnv {
  APPLE_AUTH_URL: string;
  APPLE_WEB_AUDIENCE: string;
  APPLE_JWKS_URL: string;
  GOOGLE_WEB_CLIENT_ID: string;
  GOOGLE_WEB_CLIENT_SECRET?: string;
  GOOGLE_AUTH_URL: string;
  GOOGLE_TOKEN_URL: string;
}

export function webIdentityConfigFromEnv(env: WebIdentityEnv): WebIdentityConfig {
  return {
    apple: { authUrl: env.APPLE_AUTH_URL, audience: env.APPLE_WEB_AUDIENCE, jwksUrl: env.APPLE_JWKS_URL },
    google: {
      clientId: env.GOOGLE_WEB_CLIENT_ID,
      clientSecret: env.GOOGLE_WEB_CLIENT_SECRET || undefined,
      authUrl: env.GOOGLE_AUTH_URL,
      tokenUrl: env.GOOGLE_TOKEN_URL,
    },
  };
}

export const WEB_PROVIDERS: readonly ProviderName[] = ['google', 'apple'];

export const PROVIDER_LABELS: Record<ProviderName, string> = {
  google: '使用 Google 繼續',
  apple: '使用 Apple 繼續',
};

export function isWebProvider(value: string): value is ProviderName {
  return (WEB_PROVIDERS as readonly string[]).includes(value);
}

/** Apple needs no secret; Google needs the web client secret to exchange the code. */
export function isProviderAvailable(config: WebIdentityConfig, provider: ProviderName): boolean {
  if (provider === 'google') return Boolean(config.google.clientSecret);
  return provider === 'apple';
}

export interface AuthorizeUrlParams {
  origin: string;
  /** The pending id. */
  state: string;
  /** Raw nonce stored on the pending row. */
  rawNonce: string;
}

/**
 * Sign in with Apple JS (no .p8): form_post with an id_token. No scope, since we need neither
 * email nor name. Apple echoes sha256Hex(rawNonce), which verifyAppleToken checks.
 */
export async function appleAuthorizeUrl(config: AppleWebConfig, params: AuthorizeUrlParams): Promise<string> {
  const url = new URL(config.authUrl);
  url.searchParams.set('client_id', config.audience);
  url.searchParams.set('redirect_uri', `${params.origin}/authorize/apple/callback`);
  url.searchParams.set('response_type', 'code id_token');
  url.searchParams.set('response_mode', 'form_post');
  url.searchParams.set('state', params.state);
  url.searchParams.set('nonce', await sha256Hex(params.rawNonce));
  return url.toString();
}

/** Google authorization-code flow; Google echoes the raw nonce inside the id_token. */
export function googleAuthorizeUrl(config: GoogleWebConfig, params: AuthorizeUrlParams): string {
  const url = new URL(config.authUrl);
  url.searchParams.set('client_id', config.clientId);
  url.searchParams.set('redirect_uri', `${params.origin}/authorize/google/callback`);
  url.searchParams.set('response_type', 'code');
  url.searchParams.set('scope', 'openid email profile');
  url.searchParams.set('state', params.state);
  url.searchParams.set('nonce', params.rawNonce);
  url.searchParams.set('prompt', 'select_account');
  return url.toString();
}

/** Exchanges an authorization code for the id_token; null when Google refuses or replies oddly. */
export async function exchangeGoogleCode(
  config: GoogleWebConfig,
  params: { code: string; origin: string },
  fetchImpl: typeof fetch = fetch,
): Promise<string | null> {
  if (!config.clientSecret) return null;
  const response = await fetchImpl(config.tokenUrl, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'authorization_code',
      code: params.code,
      client_id: config.clientId,
      client_secret: config.clientSecret,
      redirect_uri: `${params.origin}/authorize/google/callback`,
    }),
  });
  if (!response.ok) return null;
  const body: unknown = await response.json().catch(() => null);
  if (typeof body !== 'object' || body === null) return null;
  const idToken = (body as Record<string, unknown>).id_token;
  return typeof idToken === 'string' && idToken.length > 0 ? idToken : null;
}

/** GET /authorize/google/callback. Anything that fails after the cookie check keeps the pending. */
export async function handleGoogleCallback(
  request: Request,
  deps: AuthorizeDeps,
  fetchImpl: typeof fetch = fetch,
): Promise<Response> {
  const url = new URL(request.url);
  const check = await openCallbackPending(request, deps, {
    provider: 'google',
    state: url.searchParams.get('state') ?? '',
    error: url.searchParams.get('error') ?? '',
  });
  if (!check.ok) return check.response;

  const code = url.searchParams.get('code') ?? '';
  if (!code) return providerErrorPage();
  const google = deps.web.google;
  let verified: VerifiedIdentity;
  try {
    const idToken = await exchangeGoogleCode(google, { code, origin: new URL(request.url).origin }, fetchImpl);
    if (!idToken) return providerErrorPage();
    verified = await verifyGoogleToken({
      idToken,
      audience: google.clientId,
      nonce: check.pending.nonce,
      jwksUrl: google.jwksUrl,
      keySource: google.keySource,
    });
  } catch (error) {
    if (error instanceof AuthVerificationError) return providerErrorPage();
    throw error;
  }
  return bindIdentity(request, deps, check.pending, verified);
}

/** The provider's authorize URL, or null when the provider is not available. */
export async function providerAuthorizeUrl(
  config: WebIdentityConfig,
  provider: ProviderName,
  params: AuthorizeUrlParams,
): Promise<string | null> {
  if (!isProviderAvailable(config, provider)) return null;
  if (provider === 'apple') return appleAuthorizeUrl(config.apple, params);
  return googleAuthorizeUrl(config.google, params);
}
