import { defineHandler } from 'void';
import { withCors } from '../../src/oauth/cors';
import { protectedResourceMetadata, requestOrigin } from '../../src/oauth/metadata';

export const GET = defineHandler((c) => withCors(c.json(protectedResourceMetadata(requestOrigin(c.req.url)))));
