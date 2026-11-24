import { systemNow } from '../clock';
import { productionAppDeps, type AppBindings } from '../deps';
import { logEvent } from '../log';
import { syncDueSources, ICS_SOURCES_PER_RUN, type IcsEngineDeps } from './engine';
import { parseInsecureHosts } from './fetch';
import { D1IcsStore } from './store';

export interface IcsCronEnv {
  DB: AppBindings['DB'];
  SCOPE?: AppBindings['SCOPE'];
  SCOPE_PHYSICAL_NAMES?: string;
  DEFAULT_TIMEZONE?: string;
  ICS_ALLOW_INSECURE_HOSTS?: string;
}

function productionDeps(env: IcsCronEnv): IcsEngineDeps {
  const app = productionAppDeps(env);
  const insecureHosts = parseInsecureHosts(env.ICS_ALLOW_INSECURE_HOSTS);
  return {
    store: new D1IcsStore(app.db),
    db: app.db,
    getScopeStub: app.getScopeStub,
    getNow: app.getNow,
    ...(env.DEFAULT_TIMEZONE && { defaultTimeZone: env.DEFAULT_TIMEZONE }),
    ...(insecureHosts.length > 0 && { fetchOptions: { insecureHosts } }),
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
