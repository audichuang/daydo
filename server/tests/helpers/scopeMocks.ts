import { vi } from 'vitest';

vi.mock('cloudflare:workers', () => ({
  DurableObject: class {
    ctx: unknown;
    env: unknown;
    constructor(ctx: unknown, env: unknown) {
      this.ctx = ctx;
      this.env = env;
    }
  },
}));

vi.mock('void/durable', () => ({
  defineDurableObject: (def: unknown) => def,
}));

vi.mock('void/db', async () => {
  const [{ drizzle }, orm, schema] = await Promise.all([
    import('drizzle-orm/d1'),
    import('drizzle-orm'),
    import('../../db/schema'),
  ]);
  return {
    ...orm,
    createDb: (d1: D1Database) => drizzle(d1, { schema }),
  };
});
