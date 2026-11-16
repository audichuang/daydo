import { sha256Hex } from '../auth/crypto';
import type { DatabaseClient } from '../auth/session';
import { systemNow } from '../clock';
import { consumeAuthorizationCode, findAuthorizationCode } from './codes';
import { issueRefreshToken, rotateRefreshToken, userExists } from './refresh';
import { MCP_ACCESS_TTL_SECONDS, sha256b64url, signMcpAccessToken } from './tokens';

// OAuth 2.1 token endpoint (spec/mcp.md 4.5). client_id is optional like REF: when present
// it must equal the code or refresh row's clientId.

const NO_STORE = { 'Cache-Control': 'no-store', Pragma: 'no-cache' };

export interface TokenDeps {
  database: DatabaseClient;
  secret: string;
  now?: number;
}

function json(status: number, body: Record<string, unknown>): Response {
  return Response.json(body, { status, headers: NO_STORE });
}

function oauthError(status: number, error: string, description: string): Response {
  return json(status, { error, error_description: description });
}

async function parseBody(request: Request): Promise<URLSearchParams | null> {
  const contentType = request.headers.get('content-type') ?? '';
  try {
    if (contentType.includes('application/json')) {
      const value: unknown = await request.json();
      if (!value || typeof value !== 'object' || Array.isArray(value)) return null;
      const params = new URLSearchParams();
      for (const [key, v] of Object.entries(value)) params.set(key, String(v));
      return params;
    }
    return new URLSearchParams(await request.text());
  } catch {
    return null;
  }
}

async function grantTokens(
  origin: string,
  secret: string,
  grant: { userId: string; clientId: string; scope: string; refreshToken: string },
): Promise<Response> {
  const accessToken = await signMcpAccessToken(secret, {
    origin,
    userId: grant.userId,
    scope: grant.scope,
    clientId: grant.clientId,
  });
  return json(200, {
    access_token: accessToken,
    refresh_token: grant.refreshToken,
    token_type: 'Bearer',
    expires_in: MCP_ACCESS_TTL_SECONDS,
    scope: grant.scope,
  });
}

async function authorizationCodeGrant(
  params: URLSearchParams,
  origin: string,
  deps: TokenDeps,
  now: number,
): Promise<Response> {
  const code = params.get('code') ?? '';
  const verifier = params.get('code_verifier') ?? '';
  const redirectUri = params.get('redirect_uri') ?? '';
  const clientId = params.get('client_id') ?? '';
  if (!code) return oauthError(400, 'invalid_request', 'Missing code');
  if (!verifier) return oauthError(400, 'invalid_request', 'Missing code_verifier');

  const codeHash = await sha256Hex(code);
  const row = await findAuthorizationCode(deps.database, codeHash);
  if (!row || row.usedAt !== null || row.expiresAt <= now) {
    return oauthError(400, 'invalid_grant', 'Authorization code is invalid, expired or already used');
  }
  if ((await sha256b64url(verifier)) !== row.codeChallenge) {
    return oauthError(400, 'invalid_grant', 'PKCE verifier does not match challenge');
  }
  if (redirectUri && redirectUri !== row.redirectUri) {
    return oauthError(400, 'invalid_grant', 'redirect_uri mismatch');
  }
  if (clientId && clientId !== row.clientId) return oauthError(400, 'invalid_grant', 'client_id mismatch');

  if (!(await consumeAuthorizationCode(deps.database, codeHash, now))) {
    return oauthError(400, 'invalid_grant', 'Authorization code is invalid, expired or already used');
  }
  if (!(await userExists(deps.database, row.userId))) {
    return oauthError(400, 'invalid_grant', 'User no longer exists');
  }

  // Always issue a refresh token: ChatGPT and Codex never request offline_access.
  const refreshToken = await issueRefreshToken(deps.database, {
    familyId: row.familyId,
    userId: row.userId,
    clientId: row.clientId,
    scope: row.scope,
    resource: row.resource,
    now,
  });
  return grantTokens(origin, deps.secret, { userId: row.userId, clientId: row.clientId, scope: row.scope, refreshToken });
}

async function refreshTokenGrant(
  params: URLSearchParams,
  origin: string,
  deps: TokenDeps,
  now: number,
): Promise<Response> {
  const refreshToken = params.get('refresh_token') ?? '';
  if (!refreshToken) return oauthError(400, 'invalid_request', 'Missing refresh_token');
  const result = await rotateRefreshToken(deps.database, {
    secret: deps.secret,
    refreshToken,
    clientId: params.get('client_id') || null,
    now,
  });
  if (!result.ok) return oauthError(400, 'invalid_grant', result.description);
  return grantTokens(origin, deps.secret, result);
}

export async function handleToken(request: Request, deps: TokenDeps): Promise<Response> {
  if (request.method !== 'POST') return oauthError(405, 'invalid_request', 'Use POST');
  const params = await parseBody(request);
  if (!params) return oauthError(400, 'invalid_request', 'Unparseable body');

  const origin = new URL(request.url).origin;
  const now = deps.now ?? systemNow();
  const grantType = params.get('grant_type');
  if (grantType === 'authorization_code') return authorizationCodeGrant(params, origin, deps, now);
  if (grantType === 'refresh_token') return refreshTokenGrant(params, origin, deps, now);
  return oauthError(400, 'unsupported_grant_type', `grant_type=${grantType ?? '(missing)'} not supported`);
}
