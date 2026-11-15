import { defineScheduled } from 'void';
import { runIcsCron } from '../src/ics/cron';

export const cron = '*/5 * * * *';

// Await directly: Void's handleScheduled aggregates handler failures, ctx.waitUntil would swallow them.
export default defineScheduled(async (_controller, env) => {
  await runIcsCron(env);
});
