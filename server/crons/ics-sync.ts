import { defineScheduled } from 'void';
import { createDb } from 'void/db';
import { runIcsCron } from '../src/ics/cron';
import { runOAuthCleanup } from '../src/oauth/cleanup';

export const cron = '*/5 * * * *';

// Await directly: Void's handleScheduled aggregates handler failures, ctx.waitUntil would swallow them.
// The hourly OAuth cleanup never throws, so it cannot stop the ICS run.
export default defineScheduled(async (controller, env) => {
  await runOAuthCleanup(createDb(env.DB, { session: 'first-primary' }), controller.scheduledTime);
  await runIcsCron(env);
});
