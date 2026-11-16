// Production ToolServices, shared by the MCP route (routes/index.ts) and the ICS cron.
import { Scope } from '../../durable-objects/scope';
import { parseInsecureHosts } from '../ics/fetch';
import type { AppDb, ScopeStub } from '../sync/push';
import type { ToolServices } from './registry';

export interface ToolServicesEnv {
  DEFAULT_TIMEZONE?: string;
  ICS_ALLOW_INSECURE_HOSTS?: string;
}

/** `db` is `createDb(env.DB, { session: 'first-primary' })`, reused from the caller. */
export function productionToolServices(db: AppDb, env: ToolServicesEnv): ToolServices {
  const insecureHosts = parseInsecureHosts(env.ICS_ALLOW_INSECURE_HOSTS);
  return {
    db,
    getScopeStub: (scope) => Scope.get(scope) as unknown as ScopeStub,
    ...(env.DEFAULT_TIMEZONE && { defaultTimeZone: env.DEFAULT_TIMEZONE }),
    ...(insecureHosts.length > 0 && { ics: { fetchOptions: { insecureHosts } } }),
  };
}
