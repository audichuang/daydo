import { SignJWT, jwtVerify } from 'jose';
import { b64url } from '../base64url';

// MCP OAuth token keys and access JWTs (spec/mcp.md 4.5, 4.6). Keys are derived from
// JWT_SECRET with distinct HKDF labels, so MCP and App tokens never verify each other.

const encoder = new TextEncoder();
const HKDF_SALT = 'daydo-mcp';
const ACCESS_INFO = 'mcp-access-v1';
const REFRESH_INFO = 'mcp-refresh-v1';
export const MCP_ACCESS_TTL_SECONDS = 3600;
const ACCESS_TYP = 'at+jwt';

async function hkdf(secret: string, info: string): Promise<Uint8Array> {
  const ikm = await crypto.subtle.importKey('raw', encoder.encode(secret), 'HKDF', false, ['deriveBits']);
  const bits = await crypto.subtle.deriveBits(
    { name: 'HKDF', hash: 'SHA-256', salt: encoder.encode(HKDF_SALT), info: encoder.encode(info) },
    ikm,
    256,
  );
  return new Uint8Array(bits);
}

export function mcpAccessKey(secret: string): Promise<Uint8Array> {
  return hkdf(secret, ACCESS_INFO);
}

export function mcpRefreshKey(secret: string): Promise<Uint8Array> {
  return hkdf(secret, REFRESH_INFO);
}

/** Deterministic refresh successor: base64url(HMAC-SHA256(K_refresh, presentedToken)). */
export async function successorToken(secret: string, presentedToken: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    'raw',
    (await mcpRefreshKey(secret)) as Uint8Array<ArrayBuffer>,
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign'],
  );
  return b64url(new Uint8Array(await crypto.subtle.sign('HMAC', key, encoder.encode(presentedToken))));
}

/** Base64url SHA-256, used for PKCE S256 code_challenge checks. */
export async function sha256b64url(input: string): Promise<string> {
  return b64url(new Uint8Array(await crypto.subtle.digest('SHA-256', encoder.encode(input))));
}

export interface McpAccessClaims {
  origin: string;
  userId: string;
  scope: string;
  clientId: string;
}

export async function signMcpAccessToken(secret: string, claims: McpAccessClaims): Promise<string> {
  return new SignJWT({ scope: claims.scope, client_id: claims.clientId })
    .setProtectedHeader({ alg: 'HS256', typ: ACCESS_TYP })
    .setIssuer(claims.origin)
    .setAudience(claims.origin)
    .setSubject(claims.userId)
    .setIssuedAt()
    .setExpirationTime(`${MCP_ACCESS_TTL_SECONDS}s`)
    .sign(await mcpAccessKey(secret));
}

export interface VerifiedMcpAccess {
  userId: string;
  clientId: string | null;
  scope: string;
}

function audOrigin(aud: string): string | null {
  try {
    return new URL(aud).origin;
  } catch {
    return null;
  }
}

/**
 * Verifies an MCP access token in REF serveMcp order: signature + exp, iss === origin,
 * aud origin === origin, scope contains mcp. Throws on any failure.
 */
export async function verifyMcpAccessToken(
  token: string,
  secret: string,
  origin: string,
): Promise<VerifiedMcpAccess> {
  const { payload } = await jwtVerify(token, await mcpAccessKey(secret), {
    algorithms: ['HS256'],
    typ: ACCESS_TYP,
    requiredClaims: ['exp'],
  });
  if (payload.iss !== origin) throw new Error('iss mismatch');
  if (typeof payload.aud !== 'string' || audOrigin(payload.aud) !== origin) {
    throw new Error('aud mismatch');
  }
  const scope = typeof payload.scope === 'string' ? payload.scope : '';
  if (!scope.split(/\s+/).includes('mcp')) throw new Error('scope missing mcp');
  if (typeof payload.sub !== 'string' || payload.sub.length === 0) throw new Error('Missing subject');
  return {
    userId: payload.sub,
    clientId: typeof payload.client_id === 'string' ? payload.client_id : null,
    scope,
  };
}
