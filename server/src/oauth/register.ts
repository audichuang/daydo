import { oauthClient } from '@schema';
import { and, count, eq, gt } from 'void/db';
import { sha256Hex } from '../auth/crypto';
import type { DatabaseClient } from '../auth/session';
import { randomB64url } from '../base64url';
import { systemNow } from '../clock';
import { ipRateKey } from '../ipRateKey';

// Dynamic Client Registration (RFC 7591, spec/mcp.md 4.3). Clients are persisted so
// /authorize can require an exact redirect_uri match.

export const DCR_LIMIT_PER_HOUR = 10;
const WINDOW_MS = 60 * 60 * 1000;
const MAX_REDIRECT_URIS = 5;
const MAX_CLIENT_NAME = 100;
const DEFAULT_CLIENT_NAME = 'mcp-client';

export interface RegisterResult {
  status: 201 | 400 | 429;
  body: Record<string, unknown>;
}

function error(status: 400 | 429, code: string, description: string): RegisterResult {
  return { status, body: { error: code, error_description: description } };
}

function isAllowedRedirect(value: unknown): value is string {
  if (typeof value !== 'string' || value.includes('#')) return false;
  let url: URL;
  try {
    url = new URL(value);
  } catch {
    return false;
  }
  if (url.protocol === 'https:') return true;
  return url.protocol === 'http:' && (url.hostname === 'localhost' || url.hostname === '127.0.0.1');
}

export async function registerClient(
  database: DatabaseClient,
  params: { body: Record<string, unknown> | null; ip: string | null; now?: number },
): Promise<RegisterResult> {
  const now = params.now ?? systemNow();
  const body = params.body;
  if (!body) return error(400, 'invalid_client_metadata', 'Body must be a JSON object');

  const redirectUris = body.redirect_uris;
  if (
    !Array.isArray(redirectUris) ||
    redirectUris.length < 1 ||
    redirectUris.length > MAX_REDIRECT_URIS ||
    !redirectUris.every(isAllowedRedirect)
  ) {
    return error(
      400,
      'invalid_redirect_uri',
      'redirect_uris must be 1-5 https (or http localhost/127.0.0.1) URIs without fragment',
    );
  }

  const rawName = body.client_name;
  if (rawName !== undefined && (typeof rawName !== 'string' || rawName.length > MAX_CLIENT_NAME)) {
    return error(400, 'invalid_client_metadata', 'client_name must be a string of at most 100 characters');
  }
  const clientName = rawName && rawName.length > 0 ? rawName : DEFAULT_CLIENT_NAME;

  const ipHash = await sha256Hex(`dcr|${ipRateKey(params.ip)}`);
  const [{ n }] = await database
    .select({ n: count() })
    .from(oauthClient)
    .where(and(eq(oauthClient.ipHash, ipHash), gt(oauthClient.createdAt, now - WINDOW_MS)));
  if (n >= DCR_LIMIT_PER_HOUR) {
    return error(429, 'too_many_requests', 'Too many client registrations from this address; retry later');
  }

  const clientId = `mcp-${randomB64url(16)}`;
  await database.insert(oauthClient).values({
    clientId,
    clientName,
    redirectUris: JSON.stringify(redirectUris),
    ipHash,
    createdAt: now,
  });

  return {
    status: 201,
    body: {
      client_id: clientId,
      client_id_issued_at: Math.floor(now / 1000),
      client_name: clientName,
      redirect_uris: redirectUris,
      token_endpoint_auth_method: 'none',
      grant_types: ['authorization_code', 'refresh_token'],
      response_types: ['code'],
      client_secret_expires_at: 0,
      scope: 'mcp',
    },
  };
}
