import { defineMiddleware } from 'void';
import { env } from 'void/env';
import { createHostGateMiddleware } from '../src/auth/host';

export default defineMiddleware(
  createHostGateMiddleware({
    getMcpHost: () => env.MCP_HOST,
  }),
);
