// ICS subscription tools (spec/mcp.md 8, 9): add_ics_source, list_ics_sources, remove_ics_source,
// sync_ics_now, get_ics_sync_status. Everything is scoped to the caller; the feed URL only ever
// appears in list_ics_sources.
import { isValidTimeZone } from '../../domain/schedule';
import { ICS_MAX_WINDOW_DAYS, syncSource, type IcsEngineDeps } from '../../ics/engine';
import { assertFetchableUrl } from '../../ics/fetch';
import { D1IcsStore, MIN_SYNC_INTERVAL_SEC, type AddSourceInput, type IcsSource, type IcsStore } from '../../ics/store';
import type { IcsFilter } from '../../ics/types';
import { NO_DATA_MESSAGE } from '../../serverops/writer';
import { isEmpty, nowOf, requireInt, requireStr, ToolValidationError, type ToolContext, type ToolDef, type ToolServices } from '../toolkit';
import { openSession, requireWritableList } from './projects';

function servicesOf(ctx: ToolContext): ToolServices {
  if (!ctx.services) throw new Error('MCP tool services are not configured');
  return ctx.services;
}

function storeOf(ctx: ToolContext): IcsStore {
  const services = servicesOf(ctx);
  return services.ics?.store ?? new D1IcsStore(services.db);
}

function engineDeps(ctx: ToolContext, store: IcsStore): IcsEngineDeps {
  const services = servicesOf(ctx);
  return {
    store,
    db: services.db,
    getScopeStub: services.getScopeStub,
    ...(services.ics?.clock && { clock: services.ics.clock }),
    ...(services.ics?.fetchOptions && { fetchOptions: services.ics.fetchOptions }),
    ...(services.defaultTimeZone && { defaultTimeZone: services.defaultTimeZone }),
  };
}

const FILTER_KEYS = new Set(['future_days', 'past_days', 'exclude_keywords']);

function parseFilter(raw: unknown): IcsFilter | undefined {
  if (isEmpty(raw)) return undefined;
  if (typeof raw !== 'object' || Array.isArray(raw)) throw new ToolValidationError('filter', "Argument 'filter' must be an object");
  const f = raw as Record<string, unknown>;
  const bad = Object.keys(f).filter((k) => !FILTER_KEYS.has(k));
  if (bad.length > 0) throw new ToolValidationError('filter', `Unknown filter key(s): ${bad.join(', ')}`);
  const filter: IcsFilter = {};
  if (!isEmpty(f.future_days)) {
    const days = requireInt(f, 'future_days');
    if (days < 1 || days > ICS_MAX_WINDOW_DAYS) {
      throw new ToolValidationError('future_days', `future_days must be between 1 and ${ICS_MAX_WINDOW_DAYS}`);
    }
    filter.futureDays = days;
  }
  if (!isEmpty(f.past_days)) {
    const days = requireInt(f, 'past_days');
    if (days < 0 || days > ICS_MAX_WINDOW_DAYS) {
      throw new ToolValidationError('past_days', `past_days must be between 0 and ${ICS_MAX_WINDOW_DAYS}`);
    }
    filter.pastDays = days;
  }
  if (Array.isArray(f.exclude_keywords)) filter.excludeKeywords = f.exclude_keywords.map((k) => String(k));
  return Object.keys(filter).length > 0 ? filter : undefined;
}

function optionalId(args: Record<string, unknown>): number | undefined {
  return isEmpty(args.source_id) ? undefined : requireInt(args, 'source_id');
}

function describeSource(s: IcsSource) {
  return {
    id: s.id,
    name: s.name,
    url: s.url,
    projectId: s.projectId,
    enabled: s.enabled,
    syncIntervalSec: s.syncIntervalSec,
    filter: s.filter,
    timezone: s.timezone,
    lastSyncAt: s.lastSyncAt,
    lastStatus: s.lastStatus,
    lastStats: s.lastStats,
  };
}

async function requireOwnSource(store: IcsStore, userId: string, id: number): Promise<IcsSource> {
  const source = await store.getSource(userId, id);
  if (!source) throw new Error(`Unknown source_id ${id}; call list_ics_sources first`);
  return source;
}

const SOURCE_ID = { type: 'integer', description: 'The ICS source id (from list_ics_sources).' };

export function icsTools(): ToolDef[] {
  return [
    {
      name: 'add_ics_source',
      description:
        'Register an ICS calendar feed to sync into one of your projects. Events become tasks. `url` is the https (or webcal) feed URL; `project_id` must be a project you can write to (use list_projects first). Optional `sync_interval_sec` controls how often the cron re-syncs (default 900, minimum 300). Optional `timezone` (IANA, e.g. Asia/Taipei) is used for floating times. Optional `filter` narrows which events sync: future_days (1-3650) / past_days (0-3650) bound the time window and exclude_keywords drops events whose text matches any keyword.',
      inputSchema: {
        type: 'object',
        required: ['name', 'url', 'project_id'],
        properties: {
          name: { type: 'string', description: 'Human label for this source.' },
          url: { type: 'string', description: 'ICS feed URL (https or webcal).' },
          project_id: { type: 'string', description: 'Project to sync events into; you must be able to write to it.' },
          sync_interval_sec: { type: 'integer', description: 'Re-sync interval in seconds (default 900, minimum 300).' },
          timezone: { type: 'string', description: 'IANA time zone for floating times. Defaults to the server default.' },
          filter: {
            type: 'object',
            description:
              'Optional event filter: future_days (integer 1-3650), past_days (integer 0-3650), exclude_keywords (array of strings).',
          },
        },
      },
      run: async (args, ctx) => {
        const name = requireStr(args, 'name').trim();
        const url = requireStr(args, 'url').trim();
        const projectId = requireStr(args, 'project_id');
        const input: AddSourceInput = { name, url, projectId };
        if (!isEmpty(args.sync_interval_sec)) {
          const sec = requireInt(args, 'sync_interval_sec');
          if (sec < MIN_SYNC_INTERVAL_SEC) {
            throw new ToolValidationError('sync_interval_sec', `sync_interval_sec must be at least ${MIN_SYNC_INTERVAL_SEC}`);
          }
          input.syncIntervalSec = sec;
        }
        if (!isEmpty(args.timezone)) {
          const tz = requireStr(args, 'timezone').trim();
          if (!isValidTimeZone(tz)) throw new ToolValidationError('timezone', "Argument 'timezone' must be an IANA time zone such as Asia/Taipei");
          input.timezone = tz;
        }
        const filter = parseFilter(args.filter);
        if (filter) input.filter = filter;
        assertFetchableUrl(url, servicesOf(ctx).ics?.fetchOptions?.insecureHosts ?? []);

        const { snapshot } = await openSession(ctx);
        if (snapshot.meMemberId === null) throw new Error(NO_DATA_MESSAGE);
        requireWritableList(snapshot, projectId);
        return describeSource(await storeOf(ctx).addSource(ctx.userId, input));
      },
    },
    {
      name: 'list_ics_sources',
      description: 'List your registered ICS calendar sources with their url, sync settings and last status.',
      inputSchema: { type: 'object', properties: {} },
      run: async (_args, ctx) => (await storeOf(ctx).listSources(ctx.userId)).map(describeSource),
    },
    {
      name: 'remove_ics_source',
      description: 'Remove an ICS source (and its sync mappings) by id. Does not delete already-synced tasks.',
      inputSchema: { type: 'object', required: ['source_id'], properties: { source_id: SOURCE_ID } },
      run: async (args, ctx) => {
        const id = requireInt(args, 'source_id');
        if (!(await storeOf(ctx).removeSource(ctx.userId, id))) throw new Error(`Unknown source_id ${id}; call list_ics_sources first`);
        return { removed: id };
      },
    },
    {
      name: 'sync_ics_now',
      description:
        'Sync ICS occurrences into real tasks using stable UID and original recurrence identity. ICS controls titles, dates and managed content: an unchanged event is skipped, and manual edits to those fields are overwritten only when that event changes in the feed. Set dry_run=true to preview changes without writing; include_changes=true reports task IDs and before/after dates. With source_id, sync that source; otherwise sync all your due sources. DESTRUCTIVE: tasks whose events were removed from a complete, valid feed are moved to the trash (a pass that would remove at least 5 and more than half of the imported events is refused before any write as a safety check; sources with fewer imported events are not protected; pass allow_mass_delete=true together with source_id to override after reviewing dry_run); explicit cancellation marks tasks completed with a cancellation label. Run dry_run=true first when unsure.',
      inputSchema: {
        type: 'object',
        properties: {
          source_id: { type: 'integer', description: 'Optional. Sync only this source; omit to sync all your due sources.' },
          dry_run: { type: 'boolean', description: 'Preview only; no task or source-state writes.' },
          include_changes: { type: 'boolean', description: 'Include occurrence identity, task ID and before/after dates in the result.' },
          allow_mass_delete: {
            type: 'boolean',
            description:
              'Manual override: apply deletions even when the mass-delete safety check would refuse the pass. Requires source_id; review with dry_run=true first.',
          },
        },
      },
      run: async (args, ctx) => {
        for (const field of ['dry_run', 'include_changes', 'allow_mass_delete']) {
          if (args[field] !== undefined && typeof args[field] !== 'boolean') {
            throw new ToolValidationError(field, `${field} must be a boolean`);
          }
        }
        const sourceId = optionalId(args);
        if (args.allow_mass_delete === true && sourceId === undefined) {
          throw new ToolValidationError('allow_mass_delete', 'allow_mass_delete requires source_id');
        }
        const options = {
          dryRun: args.dry_run === true,
          includeChanges: args.include_changes === true,
          allowMassDelete: args.allow_mass_delete === true,
        };
        const store = storeOf(ctx);
        const deps = engineDeps(ctx, store);
        const run = async (source: IcsSource) => ({
          source_id: source.id,
          name: source.name,
          ...(await syncSource(deps, ctx.userId, source.id, nowOf(ctx), options)),
        });
        if (sourceId !== undefined) return run(await requireOwnSource(store, ctx.userId, sourceId));
        const now = nowOf(ctx);
        const due = (await store.listSources(ctx.userId)).filter(
          (s) => s.enabled && (s.lastSyncAt === null || now >= s.lastSyncAt + s.syncIntervalSec * 1000),
        );
        const out = [];
        for (const source of due) out.push(await run(source));
        return out;
      },
    },
    {
      name: 'get_ics_sync_status',
      description:
        'Report sync status for your ICS sources: last sync time, last status, last stats (a JSON string) and the number of synced event mappings. Optionally restrict to one source_id.',
      inputSchema: {
        type: 'object',
        properties: { source_id: { type: 'integer', description: 'Optional. Restrict to this source.' } },
      },
      run: async (args, ctx) => {
        const store = storeOf(ctx);
        const filterId = optionalId(args);
        const sources = (await store.listSources(ctx.userId)).filter((s) => filterId === undefined || s.id === filterId);
        return Promise.all(
          sources.map(async (s) => ({
            id: s.id,
            name: s.name,
            enabled: s.enabled,
            lastSyncAt: s.lastSyncAt,
            lastStatus: s.lastStatus,
            lastStats: s.lastStats,
            mappingCount: await store.countMappings(ctx.userId, s.id),
          })),
        );
      },
    },
  ];
}
