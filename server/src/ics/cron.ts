import { createDb } from 'void/db';
import { Scope } from '../../durable-objects/scope';
import { user } from '../../db/schema';

export interface IcsCronEnv {
  DB: Parameters<typeof createDb>[0];
  JWT_SECRET?: string;
}

export interface CronProbeResult {
  db: 'ok' | 'fail';
  scope: 'ok' | 'skip' | 'fail';
  env: 'ok' | 'fail';
}

async function attempt(fn: () => Promise<void>): Promise<'ok' | 'fail'> {
  try {
    await fn();
    return 'ok';
  } catch {
    return 'fail';
  }
}

/** M2 spike: prove D1, the Scope DO and env are reachable from a scheduled handler. */
export async function probeCronRuntime(
  env: IcsCronEnv,
  isDev: boolean = import.meta.env.DEV,
): Promise<CronProbeResult> {
  const db = await attempt(async () => {
    const database = createDb(env.DB, { session: 'first-primary' });
    await database.select({ id: user.id }).from(user).limit(1);
  });
  const scope = isDev
    ? await attempt(async () => {
        await Scope.get('u:__cron_probe__').getInboxProjectId({
          readableProjectIds: ['__cron_probe__'],
        });
      })
    : 'skip';
  const envOk = typeof env.JWT_SECRET === 'string' && env.JWT_SECRET.length > 0 ? 'ok' : 'fail';
  return { db, scope, env: envOk };
}

export async function runIcsCron(env: IcsCronEnv): Promise<void> {
  const probe = await probeCronRuntime(env);
  console.log(`ics.cron.probe ${JSON.stringify(probe)}`);
}
