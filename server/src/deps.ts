// Production wiring for entry points (routes, crons): the only place that opens a D1 session
// and resolves Scope DO stubs. Keep this file at the bottom of the import graph: no void/env,
// no src/mcp, src/ics or src/oauth.
import { createDb } from 'void/db';
import { Scope } from '../durable-objects/scope';
import { systemNow, type GetNow } from './clock';
import { selectMailer, type Mailer } from './mail/mailer';
import type { ScopeStub } from './scope/api';
import type { AppDb } from './sync/push';

/** What an entry point (route, cron) needs to reach the outside world. Tests build one with createScopeWorld(). */
export interface AppDeps {
  /** One D1 session (`first-primary`) per AppDeps. */
  db: AppDb;
  getScopeStub: (scope: string) => ScopeStub;
  getNow: GetNow;
  mailer: Mailer;
}

export interface AppBindings {
  DB: Parameters<typeof createDb>[0];
  EMAIL?: SendEmail;
}

/**
 * Call it exactly where the handler used to open its D1 session: every call opens a new one.
 * Not memoized, so one handler keeps exactly the sessions it had before.
 */
export function productionAppDeps(bindings: AppBindings): AppDeps {
  return {
    db: createDb(bindings.DB, { session: 'first-primary' }),
    getScopeStub: (scope) => Scope.get(scope),
    getNow: systemNow,
    mailer: selectMailer({ binding: bindings.EMAIL }),
  };
}
