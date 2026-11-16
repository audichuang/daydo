// ToolServices from AppDeps, shared by the MCP route (routes/index.ts) and the ICS cron.
import type { AppDeps } from '../deps';
import { parseInsecureHosts } from '../ics/fetch';
import type { ToolServices } from './toolkit';

export interface ToolServicesEnv {
  DEFAULT_TIMEZONE?: string;
  ICS_ALLOW_INSECURE_HOSTS?: string;
}

/** `deps.db` is the caller's AppDeps session, reused as is. */
export function toolServices(deps: Pick<AppDeps, 'db' | 'getScopeStub' | 'getNow'>, env: ToolServicesEnv): ToolServices {
  const insecureHosts = parseInsecureHosts(env.ICS_ALLOW_INSECURE_HOSTS);
  return {
    db: deps.db,
    getScopeStub: deps.getScopeStub,
    getNow: deps.getNow,
    ...(env.DEFAULT_TIMEZONE && { defaultTimeZone: env.DEFAULT_TIMEZONE }),
    ...(insecureHosts.length > 0 && { ics: { fetchOptions: { insecureHosts } } }),
  };
}
