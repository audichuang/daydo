// `/`, `/register`, `/token` and `/.well-known/*` are Bearer-authenticated, so CORS `*`
// is intentional (spec/mcp.md 4.1). `/authorize*` must not use this.
export function withCors(response: Response): Response {
  const headers = new Headers(response.headers);
  headers.set('Access-Control-Allow-Origin', '*');
  return new Response(response.body, { status: response.status, statusText: response.statusText, headers });
}
