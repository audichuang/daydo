import { defineHandler } from 'void';
import { withCors } from '../../src/oauth/cors';
import { authorizationServerMetadata, requestOrigin } from '../../src/oauth/metadata';

export const GET = defineHandler((c) => withCors(c.json(authorizationServerMetadata(requestOrigin(c.req.url)))));
