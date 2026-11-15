import { defineMiddleware } from 'void';
import { env } from 'void/env';
import { createAccessMiddleware } from '../src/auth/access';

export default defineMiddleware(
  createAccessMiddleware({
    getConfig: () => ({
      teamDomain: env.ACCESS_TEAM_DOMAIN,
      aud: env.ACCESS_AUD,
    }),
  }),
);
