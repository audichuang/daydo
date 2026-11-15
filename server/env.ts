import { defineEnv, string, url } from 'void/env';

export default defineEnv({
  JWT_SECRET: string(),
  APPLE_AUDIENCE: string().default('com.audichuang.daydo'),
  APPLE_JWKS_URL: url().default('https://appleid.apple.com/auth/keys'),
  GOOGLE_AUDIENCE: string().optional(),
  GOOGLE_JWKS_URL: url().default('https://www.googleapis.com/oauth2/v3/certs'),
});
