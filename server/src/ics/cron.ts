import { systemNow } from '../clock';
import { productionAppDeps, type AppBindings } from '../deps';
import { logEvent } from '../log';
import { toolServices } from '../mcp/services';
import { syncDueSources, ICS_SOURCES_PER_RUN, type IcsEngineDeps } from './engine';
import { D1IcsStore } from './store';

export interface IcsCronEnv {
  DB: AppBindings['DB'];
  DEFAULT_TIMEZONE?: string;
  ICS_ALLOW_INSECURE_HOSTS?: string;
}

function productionDeps(env: IcsCronEnv): IcsEngineDeps {
  const app = productionAppDeps(env);
  const services = toolServices(app, env);
  return {
    store: new D1IcsStore(services.db),
    db: services.db,
    getScopeStub: services.getScopeStub,
    getNow: app.getNow,
    ...(services.defaultTimeZone && { defaultTimeZone: services.defaultTimeZone }),
    ...(services.ics?.fetchOptions && { fetchOptions: services.ics.fetchOptions }),
  };
}

/**
 * Syncs the due sources, at most ICS_SOURCES_PER_RUN per run and never with allowMassDelete.
 * The engine absorbs per-source failures (recorded on the source), so only a run-level failure,
 * such as the due query, throws. `deps` is injected by tests.
 */
export async function runIcsCron(env: IcsCronEnv, deps: IcsEngineDeps = productionDeps(env)): Promise<void> {
  const results = await syncDueSources(deps, (deps.getNow ?? systemNow)(), ICS_SOURCES_PER_RUN);
  // Source ids only: feed URLs are secrets and never reach the logs.
  for (const r of results) {
    logEvent(r.stats.errors > 0 ? 'warn' : 'log', 'ics.sync', {
      source_id: r.source,
      ms: r.ms,
      created: r.stats.created,
      updated: r.stats.updated,
      skipped: r.stats.skipped,
      deleted: r.stats.deleted,
      errors: r.stats.errors,
      ...(r.stats.busy && { busy: true }),
      ...(r.stats.lastError && { error: r.stats.lastError }),
    });
  }
  logEvent('log', 'ics.cron.run', { due: results.length });
}
