import { defineEnv, oneOf, string, url } from 'void/env';

export default defineEnv({
  JWT_SECRET: string(),
  APPLE_AUDIENCE: string().default('com.audichuang.daydo'),
  APPLE_JWKS_URL: url().default('https://appleid.apple.com/auth/keys'),
  GOOGLE_AUDIENCE: string().optional(),
  GOOGLE_JWKS_URL: url().default('https://www.googleapis.com/oauth2/v3/certs'),
  ACCESS_TEAM_DOMAIN: string().optional(),
  ACCESS_AUD: string().optional(),
  MCP_HOST: string().default('mcp.daydoapp.com'),
  GOOGLE_WEB_CLIENT_ID: string().default(
    '710830841029-i2n5hhd9kgg56r3svnmb0c5g32no5lmv.apps.googleusercontent.com',
  ),
  GOOGLE_WEB_CLIENT_SECRET: string().optional(),
  GOOGLE_AUTH_URL: url().default('https://accounts.google.com/o/oauth2/v2/auth'),
  GOOGLE_TOKEN_URL: url().default('https://oauth2.googleapis.com/token'),
  APPLE_WEB_AUDIENCE: string().default('com.audichuang.daydo.web'),
  APPLE_AUTH_URL: url().default('https://appleid.apple.com/auth/authorize'),
  DEFAULT_TIMEZONE: string().default('Asia/Taipei'),
  ICS_ALLOW_INSECURE_HOSTS: string().optional(),
  SYNC_FAULT: oneOf(['none', 'split-txn']).default('none'),
});
