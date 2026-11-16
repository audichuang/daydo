import { oauthClient } from '@schema';
import { and, count, eq, gt } from 'void/db';
import { sha256Hex } from '../auth/crypto';
import type { DatabaseClient } from '../auth/session';
import { randomB64url } from './tokens';

// Dynamic Client Registration (RFC 7591, spec/mcp.md 4.3). Clients are persisted so
// /authorize can require an exact redirect_uri match.

export const DCR_LIMIT_PER_HOUR = 10;
const WINDOW_MS = 60 * 60 * 1000;
const MAX_REDIRECT_URIS = 5;
const MAX_CLIENT_NAME = 100;
const DEFAULT_CLIENT_NAME = 'mcp-client';

/** Parses an IPv6 address into its eight 16-bit groups, or null when it is not one. */
function ipv6Groups(ip: string): number[] | null {
  const halves = ip.split('::');
  if (halves.length > 2) return null;
  const parse = (part: string): number[] | null => {
    if (part === '') return [];
    const out: number[] = [];
    const pieces = part.split(':');
    for (const [i, piece] of pieces.entries()) {
      // An embedded IPv4 tail (e.g. ::ffff:1.2.3.4) fills the last two groups.
      if (i === pieces.length - 1 && piece.includes('.')) {
        const octets = piece.split('.').map(Number);
        if (octets.length !== 4 || octets.some((o) => !Number.isInteger(o) || o < 0 || o > 255)) return null;
        out.push((octets[0] << 8) | octets[1], (octets[2] << 8) | octets[3]);
      } else if (/^[0-9a-f]{1,4}$/.test(piece)) {
        out.push(parseInt(piece, 16));
      } else {
        return null;
      }
    }
    return out;
  };
  const head = parse(halves[0]);
  const tail = halves.length === 2 ? parse(halves[1]) : [];
  if (!head || !tail) return null;
  if (halves.length === 1) return head.length === 8 ? head : null;
  const fill = 8 - head.length - tail.length;
  return fill >= 1 ? [...head, ...Array<number>(fill).fill(0), ...tail] : null;
}

/**
 * Rate-limit key for a client address (CF-Connecting-IP): IPv4 as is, IPv6 reduced to its /64
 * (one host usually owns a whole /64), `local` without the header (dev builds).
 */
export function ipRateKey(ip: string | null): string {
  if (!ip) return 'local';
  if (!ip.includes(':')) return ip;
  const lower = ip.toLowerCase();
  const groups = ipv6Groups(lower);
  if (!groups) return lower;
  return `${groups
    .slice(0, 4)
    .map((g) => g.toString(16))
    .join(':')}::/64`;
}

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
  const now = params.now ?? Date.now();
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
