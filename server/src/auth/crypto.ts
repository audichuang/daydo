import { SignJWT, jwtVerify } from 'jose';

const encoder = new TextEncoder();

export async function sha256Hex(input: string): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', encoder.encode(input));
  return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, '0')).join('');
}

export function generateRefreshToken(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  let binary = '';
  for (const byte of bytes) {
    binary += String.fromCharCode(byte);
  }
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

export async function signAccessToken(userId: string, secret: string): Promise<string> {
  return new SignJWT({})
    .setProtectedHeader({ alg: 'HS256' })
    .setSubject(userId)
    .setIssuedAt()
    .setExpirationTime('1h')
    .sign(encoder.encode(secret));
}

export async function verifyAccessToken(
  token: string,
  secret: string,
): Promise<{ userId: string }> {
  const { payload, protectedHeader } = await jwtVerify(token, encoder.encode(secret), {
    algorithms: ['HS256'],
  });
  // Defense in depth (spec/mcp.md 4.6): App tokens never carry aud or typ=at+jwt;
  // MCP access tokens always do, so refuse them even if the key were shared.
  const typ = typeof protectedHeader.typ === 'string' ? protectedHeader.typ.toLowerCase() : '';
  if (payload.aud !== undefined || typ === 'at+jwt' || typ === 'application/at+jwt') {
    throw new Error('Not an App access token');
  }
  if (typeof payload.sub !== 'string' || payload.sub.length === 0) {
    throw new Error('Missing subject');
  }
  return { userId: payload.sub };
}
