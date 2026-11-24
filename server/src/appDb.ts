import type * as schema from '@schema';
import type { DrizzleD1Database } from 'void/db';

/** The Drizzle D1 session every server module takes; kept in a leaf file so modules don't depend on sync/push for it. */
export type AppDb = DrizzleD1Database<typeof schema>;
