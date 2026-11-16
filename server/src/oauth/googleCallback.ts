import { AuthVerificationError, verifyGoogleToken, type VerifiedIdentity } from '../auth/providers';
import { bindIdentity, openCallbackPending, providerErrorPage, type AuthorizeDeps } from './authorize';
import { exchangeGoogleCode } from './webIdentity';

// Google web sign-in callback for /authorize (spec/mcp.md 4.4 step 3). Lives apart from
// webIdentity.ts because it finishes the flow through authorize.ts, which imports webIdentity.ts.

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
