// Row value helpers shared by the server-side writers (writer, MCP tools, ICS engine).
import type { Schedule } from '../domain/schedule';
import { SCHEDULE_FIELDS } from '../sync/entities';

/** null and undefined both mean "no value" in a row or a write. */
export function isNil(v: unknown): v is null | undefined {
  return v === null || v === undefined;
}

/** Row value equality: nil equals nil, arrays compare by content. */
export function sameValue(a: unknown, b: unknown): boolean {
  const x = isNil(a) ? null : a;
  const y = isNil(b) ? null : b;
  if (Array.isArray(x) || Array.isArray(y)) return JSON.stringify(x) === JSON.stringify(y);
  return x === y;
}

/** All five schedule columns (null when cleared); the writer sends them as one LWW group. */
export function scheduleColumns(s: Schedule | null): Record<string, unknown> {
  return Object.fromEntries(SCHEDULE_FIELDS.map((k) => [k, s ? s[k] : null]));
}

/** The row's schedule, or null when it has no start day. Wrongly typed columns read as null. */
export function rowSchedule(row: Record<string, unknown>): Schedule | null {
  if (typeof row.startDay !== 'string') return null;
  return {
    startDay: row.startDay,
    startMinute: typeof row.startMinute === 'number' ? row.startMinute : null,
    endDay: typeof row.endDay === 'string' ? row.endDay : null,
    endMinute: typeof row.endMinute === 'number' ? row.endMinute : null,
    timeZone: typeof row.timeZone === 'string' ? row.timeZone : null,
  };
}

export function sameSchedule(a: Schedule | null, b: Schedule | null): boolean {
  if (a === null || b === null) return a === b;
  return SCHEDULE_FIELDS.every((k) => a[k] === b[k]);
}
