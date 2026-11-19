// Production wiring for entry points (routes, crons): the only place that opens a D1 session
// and resolves Scope DO stubs. Keep this file at the bottom of the import graph: no void/env,
// no src/mcp, src/ics or src/oauth.
import { createDb } from 'void/db';
import { createStorage } from 'void/storage';
import { Scope } from '../durable-objects/scope';
import { systemNow, type GetNow } from './clock';
import { logEvent } from './log';
import { selectMailer, type Mailer } from './mail/mailer';
import type { ScopeRelocationStub, ScopeStub } from './scope/api';
import type { AppDb } from './sync/push';

const SCOPE_LOCATION_HINT: DurableObjectLocationHint = 'apac-ne';
const EMPTY_PHYSICAL_NAMES: ReadonlyMap<string, string> = new Map();

let cachedPhysicalNamesRaw: string | undefined;
let cachedPhysicalNamesMap: ReadonlyMap<string, string> = EMPTY_PHYSICAL_NAMES;

interface ScopeNamespace {
  idFromName(name: string): DurableObjectId;
  get(
    id: DurableObjectId,
    options?: DurableObjectNamespaceGetDurableObjectOptions,
  ): ScopeStub & ScopeRelocationStub;
}

function isScopeNamespace(value: unknown): value is ScopeNamespace {
  return (
    typeof value === 'object' &&
    value !== null &&
    typeof (value as ScopeNamespace).idFromName === 'function' &&
    typeof (value as ScopeNamespace).get === 'function'
  );
}

/**
 * Parses `SCOPE_PHYSICAL_NAMES` (`{ "<logical>": "<physical>" }`).
 * Absent, empty, or malformed values fall back to identity routing (empty map), logging once
 * per distinct bad value so a bad config cannot take production down.
 */
export function parseScopePhysicalNames(raw: string | undefined): ReadonlyMap<string, string> {
  if (!raw || raw.trim().length === 0) return EMPTY_PHYSICAL_NAMES;
  if (raw === cachedPhysicalNamesRaw) return cachedPhysicalNamesMap;

  const fail = (reason: string): ReadonlyMap<string, string> => {
    logEvent('error', 'scope.physical_names.invalid', { reason });
    cachedPhysicalNamesRaw = raw;
    cachedPhysicalNamesMap = EMPTY_PHYSICAL_NAMES;
    return EMPTY_PHYSICAL_NAMES;
  };

  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return fail('invalid_json');
  }
  if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
    return fail('not_an_object');
  }

  const map = new Map<string, string>();
  for (const [logical, physical] of Object.entries(parsed)) {
    if (
      logical.length === 0 ||
      logical === '__proto__' ||
      typeof physical !== 'string' ||
      physical.length === 0
    ) {
      return fail('invalid_entry');
    }
    map.set(logical, physical);
  }
  cachedPhysicalNamesRaw = raw;
  cachedPhysicalNamesMap = map;
  return map;
}

function getNativeScopeStub(
  bindings: AppBindings,
  physical: string,
): ScopeStub & ScopeRelocationStub {
  if (!isScopeNamespace(bindings.SCOPE)) {
    throw new Error('SCOPE Durable Object binding is not available');
  }
  return bindings.SCOPE.get(bindings.SCOPE.idFromName(physical), {
    locationHint: SCOPE_LOCATION_HINT,
  });
}

/** What an entry point (route, cron) needs to reach the outside world. Tests build one with createScopeWorld(). */
export interface AppDeps {
  /** One D1 session (`first-primary`) per AppDeps. */
  db: AppDb;
  getScopeStub: (scope: string) => ScopeStub;
  getPhysicalScopeStub: (physical: string) => ScopeRelocationStub;
  /** Physical DO name the logical scope is routed to, when SCOPE_PHYSICAL_NAMES maps it. */
  resolveScopePhysical: (logical: string) => string | undefined;
  getNow: GetNow;
  mailer: Mailer;
  storage: R2Bucket | null;
}

export interface AppBindings {
  DB: Parameters<typeof createDb>[0];
  EMAIL?: SendEmail;
  STORAGE?: Parameters<typeof createStorage>[0];
  SCOPE?: unknown;
  SCOPE_PHYSICAL_NAMES?: string;
}

/**
 * Call it exactly where the handler used to open its D1 session: every call opens a new one.
 * Not memoized, so one handler keeps exactly the sessions it had before.
 */
export function productionAppDeps(bindings: AppBindings): AppDeps {
  const physicalNames = parseScopePhysicalNames(bindings.SCOPE_PHYSICAL_NAMES);
  return {
    db: createDb(bindings.DB, { session: 'first-primary' }),
    getScopeStub: (scope) => {
      const physical = physicalNames.get(scope);
      return physical !== undefined ? getNativeScopeStub(bindings, physical) : Scope.get(scope);
    },
    getPhysicalScopeStub: (physical) => getNativeScopeStub(bindings, physical),
    resolveScopePhysical: (logical) => physicalNames.get(logical),
    getNow: systemNow,
    mailer: selectMailer({ binding: bindings.EMAIL }),
    storage: bindings.STORAGE ? createStorage(bindings.STORAGE) : null,
  };
}
