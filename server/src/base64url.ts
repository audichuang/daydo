export function b64url(bytes: Uint8Array): string {
  let binary = '';
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

export function randomB64url(byteLength = 32): string {
  return b64url(crypto.getRandomValues(new Uint8Array(byteLength)));
}
