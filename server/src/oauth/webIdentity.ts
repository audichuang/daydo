import { sha256Hex } from '../auth/crypto';
import type { KeySource, ProviderName } from '../auth/providers';

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

/** Whether the provider's web sign-in can be started. Google web sign-in arrives in M7b. */
export function isProviderAvailable(_config: WebIdentityConfig, provider: ProviderName): boolean {
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

/** The provider's authorize URL, or null when the provider is not available. */
export async function providerAuthorizeUrl(
  config: WebIdentityConfig,
  provider: ProviderName,
  params: AuthorizeUrlParams,
): Promise<string | null> {
  if (!isProviderAvailable(config, provider)) return null;
  if (provider === 'apple') return appleAuthorizeUrl(config.apple, params);
  return null;
}
