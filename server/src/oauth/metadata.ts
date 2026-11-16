// OAuth discovery metadata (spec/mcp.md 4.1). Origin always comes from the request URL;
// the host gate guarantees it is the MCP host.

export const SCOPES = ['mcp', 'offline_access'];

export function requestOrigin(requestUrl: string): string {
  return new URL(requestUrl).origin;
}

export function protectedResourceMetadata(origin: string) {
  return {
    resource: origin,
    authorization_servers: [origin],
    scopes_supported: SCOPES,
    bearer_methods_supported: ['header'],
  };
}

export function authorizationServerMetadata(origin: string) {
  return {
    issuer: origin,
    authorization_endpoint: `${origin}/authorize`,
    token_endpoint: `${origin}/token`,
    registration_endpoint: `${origin}/register`,
    response_types_supported: ['code'],
    grant_types_supported: ['authorization_code', 'refresh_token'],
    code_challenge_methods_supported: ['S256'],
    token_endpoint_auth_methods_supported: ['none'],
    scopes_supported: SCOPES,
  };
}
