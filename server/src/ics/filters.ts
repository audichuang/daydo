/**
 * Event filtering for ICS sync.
 *
 * Mirrors a subset of the Python `filter_manager.py`, but does *real*
 * timezone-aware comparisons instead of the Python silent no-op: `ev.start`
 * is an ISO 8601 string parsed to epoch ms via `Date.parse`, and the caller
 * supplies `nowMs` so the rules are deterministic under test.
 *
 * All rules combine with AND semantics: an event survives only if it passes
 * every configured rule. A null/empty filter passes everything through.
 */
import type { IcsFilter, ParsedEvent } from './types';

const MS_PER_DAY = 24 * 60 * 60 * 1000;

function hasRules(filter: IcsFilter | null | undefined): filter is IcsFilter {
  if (!filter) return false;
  return (
    filter.futureDays != null ||
    filter.pastDays != null ||
    (filter.excludeKeywords != null && filter.excludeKeywords.length > 0)
  );
}

/**
 * Returns the subset of `events` that survive `filter` relative to `nowMs`.
 *
 * - futureDays: drop events starting after now + futureDays days.
 * - pastDays: drop events starting before now - pastDays days.
 * - excludeKeywords: drop events whose summary/description/location contains
 *   any keyword (case-insensitive substring match).
 *
 * Events whose `start` is not a parseable ISO date are kept (we can't make a
 * confident windowing decision) but are still subject to keyword exclusion.
 */
export function applyFilter(
  events: ParsedEvent[],
  filter: IcsFilter | null | undefined,
  nowMs: number,
): ParsedEvent[] {
  if (!hasRules(filter)) return events;

  const keywords =
    filter.excludeKeywords?.map((k) => k.toLowerCase()).filter((k) => k.length > 0) ?? [];

  const futureCutoff =
    filter.futureDays != null ? nowMs + filter.futureDays * MS_PER_DAY : null;
  const pastCutoff =
    filter.pastDays != null ? nowMs - filter.pastDays * MS_PER_DAY : null;

  return events.filter((ev) => {
    if (keywords.length > 0) {
      const haystack = [ev.summary, ev.description, ev.location]
        .filter((s): s is string => typeof s === 'string')
        .join('\n')
        .toLowerCase();
      if (keywords.some((kw) => haystack.includes(kw))) return false;
    }

    if (futureCutoff != null || pastCutoff != null) {
      const startMs = Date.parse(ev.start);
      if (!Number.isNaN(startMs)) {
        if (futureCutoff != null && startMs > futureCutoff) return false;
        if (pastCutoff != null && startMs < pastCutoff) return false;
      }
    }

    return true;
  });
}
