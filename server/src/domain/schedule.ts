// Port of DayDoCore Schedule.swift (fromAPI, API rendering, moved) and the
// LocalDay arithmetic it needs. Days are `YYYY-MM-DD` strings; minutes are
// minutes from 00:00 of the day. Wall clock is always derived from the zone's
// Intl date components, never from "midnight plus minutes" (DST days).

/** The five schedule columns of a task row. */
export interface Schedule {
  startDay: string;
  /** null = all-day. */
  startMinute: number | null;
  /** All-day: inclusive last day. Timed: end day (may be the next day). */
  endDay: string | null;
  endMinute: number | null;
  /** IANA zone; null = floating (follows the device). */
  timeZone: string | null;
}

export interface ScheduleAPI {
  start: string | null;
  due: string | null;
  all_day: boolean;
  timezone: string | null;
}

export class ScheduleError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'ScheduleError';
  }
}

const invalidDateTime = (raw: string) => new ScheduleError(`Invalid ISO 8601 date/time: ${raw}`);
const endBeforeStart = () => new ScheduleError('due must not be before start');
const unknownTimeZone = (tz: string) => new ScheduleError(`Unknown IANA time zone: ${tz}`);

/** Zones the App tries when inferring a zone from an offset, in order. */
export const KNOWN_TIME_ZONES = [
  'Asia/Taipei',
  'Asia/Tokyo',
  'Europe/London',
  'America/New_York',
  'America/Los_Angeles',
  'Europe/Paris',
  'Australia/Sydney',
  'Asia/Singapore',
] as const;

// MARK: - LocalDay

const DAY_MS = 86_400_000;
const DAY_RE = /^(\d{4})-(\d{2})-(\d{2})$/;

function splitDay(day: string): [number, number, number] {
  const m = DAY_RE.exec(day);
  if (!m) throw new ScheduleError(`Invalid day: ${day}`);
  return [Number(m[1]), Number(m[2]), Number(m[3])];
}

/** Midnight UTC of a calendar day (years below 100 are not shifted to 19xx). */
function utcMs(y: number, m: number, d: number): number {
  const date = new Date(0);
  date.setUTCFullYear(y, m - 1, d);
  return date.getTime();
}

function dayToMs(day: string): number {
  const [y, m, d] = splitDay(day);
  return utcMs(y, m, d);
}

function formatDay(y: number, m: number, d: number): string {
  return `${String(y).padStart(4, '0')}-${String(m).padStart(2, '0')}-${String(d).padStart(2, '0')}`;
}

function msToDay(ms: number): string {
  const date = new Date(ms);
  return formatDay(date.getUTCFullYear(), date.getUTCMonth() + 1, date.getUTCDate());
}

function monthLength(y: number, m: number): number {
  return new Date(utcMs(y, m + 1, 0)).getUTCDate();
}

/** `YYYY-MM-DD` that names a real calendar day. */
export function isValidDay(s: string): boolean {
  const m = DAY_RE.exec(s);
  if (!m) return false;
  const month = Number(m[2]);
  const day = Number(m[3]);
  return month >= 1 && month <= 12 && day >= 1 && day <= monthLength(Number(m[1]), month);
}

export function addDays(day: string, days: number): string {
  return msToDay(dayToMs(day) + days * DAY_MS);
}

/** Calendar month addition clamped to the month end (Jan 31 + 1 → Feb 28), like Foundation. */
export function addMonths(day: string, months: number): string {
  const [y, m, d] = splitDay(day);
  const index = y * 12 + (m - 1) + months;
  const ny = Math.floor(index / 12);
  const nm = index - ny * 12 + 1;
  return formatDay(ny, nm, Math.min(d, monthLength(ny, nm)));
}

export function daysBetween(from: string, to: string): number {
  return Math.round((dayToMs(to) - dayToMs(from)) / DAY_MS);
}

/** 0 = Sunday … 6 = Saturday. */
export function weekday(day: string): number {
  return new Date(dayToMs(day)).getUTCDay();
}

export function daysInMonth(day: string): number {
  const [y, m] = splitDay(day);
  return monthLength(y, m);
}

// MARK: - Time zones

const formatters = new Map<string, Intl.DateTimeFormat>();

function formatter(zone: string): Intl.DateTimeFormat {
  let f = formatters.get(zone);
  if (!f) {
    f = new Intl.DateTimeFormat('en-US', {
      timeZone: zone,
      hourCycle: 'h23',
      year: 'numeric',
      month: '2-digit',
      day: '2-digit',
      hour: '2-digit',
      minute: '2-digit',
      second: '2-digit',
    });
    formatters.set(zone, f);
  }
  return f;
}

/** IANA identifier the App can resolve: no offset forms, exact casing. */
export function isValidTimeZone(tz: string): boolean {
  if (tz === '' || /^[+-]/.test(tz)) return false;
  let resolved: string;
  try {
    resolved = formatter(tz).resolvedOptions().timeZone;
  } catch {
    return false;
  }
  // Intl accepts "asia/taipei"; Foundation does not.
  return !(resolved !== tz && resolved.toLowerCase() === tz.toLowerCase());
}

interface Components {
  y: number;
  mo: number;
  d: number;
  h: number;
  mi: number;
  s: number;
}

function components(instant: number, zone: string): Components {
  const out: Record<string, number> = {};
  for (const p of formatter(zone).formatToParts(new Date(instant))) {
    if (p.type !== 'literal') out[p.type] = Number(p.value);
  }
  return { y: out.year, mo: out.month, d: out.day, h: out.hour, mi: out.minute, s: out.second };
}

/** Wall-clock day and minute of an instant in `zone`. */
export function wallClockAt(instant: number, zone: string): { day: string; minute: number } {
  const c = components(instant, zone);
  return { day: formatDay(c.y, c.mo, c.d), minute: c.h * 60 + c.mi };
}

/** Seconds east of UTC in `zone` at `instant`. */
export function offsetAt(zone: string, instant: number): number {
  const c = components(instant, zone);
  const wall = utcMs(c.y, c.mo, c.d) + ((c.h * 60 + c.mi) * 60 + c.s) * 1000;
  return Math.round((wall - Math.floor(instant / 1000) * 1000) / 1000);
}

/**
 * Instant of a wall-clock time in `zone`. Ambiguous times (fall back) take
 * the first occurrence; skipped times (spring forward) move forward by the
 * gap. Both match Foundation's `Calendar.date(from:)`.
 */
export function instantOf(day: string, minute: number, zone: string): number {
  const wall = dayToMs(day) + minute * 60_000;
  const before = offsetAt(zone, wall - DAY_MS);
  const after = offsetAt(zone, wall + DAY_MS);
  const matches = [...new Set([before, after])]
    .map((off) => wall - off * 1000)
    .filter((t) => {
      const w = wallClockAt(t, zone);
      return w.day === day && w.minute === minute;
    });
  if (matches.length > 0) return Math.min(...matches);
  return wall - before * 1000;
}

/**
 * Zone for an offset, compared at the event instant: `defaultTimeZone`
 * first, then the App's fixed list, else `UTC`.
 */
export function inferTimeZone(offsetSeconds: number, instant: number, defaultTimeZone: string): string {
  for (const zone of [defaultTimeZone, ...KNOWN_TIME_ZONES]) {
    if (offsetAt(zone, instant) === offsetSeconds) return zone;
  }
  return 'UTC';
}

// MARK: - ISO 8601 input

interface ParsedTime {
  day: string;
  minute: number | null;
  offsetSeconds: number | null;
}

/**
 * Accepts `2026-11-15`, `2026-11-15T18:00`, `2026-11-15T18:00:00(.sss)`
 * (`T` or space), optionally followed by `Z`, `+08:00` or `+0800`.
 */
function parse(raw: string): ParsedTime {
  const s = raw.trim();
  const day = s.slice(0, 10);
  if (!isValidDay(day)) throw invalidDateTime(raw);
  if (s.length === 10) return { day, minute: null, offsetSeconds: null };
  if (s[10] !== 'T' && s[10] !== ' ') throw invalidDateTime(raw);
  let body = s.slice(11);
  let offsetSeconds: number | null = null;
  if (body.endsWith('Z')) {
    offsetSeconds = 0;
    body = body.slice(0, -1);
  } else {
    const idx = Math.max(body.lastIndexOf('+'), body.lastIndexOf('-'));
    if (idx >= 0) {
      const sign = body[idx] === '-' ? -1 : 1;
      const digits = body.slice(idx + 1).replace(':', '');
      body = body.slice(0, idx);
      if (!/^\d{4}$/.test(digits)) throw invalidDateTime(raw);
      const hh = Number(digits.slice(0, 2));
      const mm = Number(digits.slice(2));
      if (hh > 23 || mm > 59) throw invalidDateTime(raw);
      offsetSeconds = sign * (hh * 3600 + mm * 60);
    }
  }
  const m = /^(\d{1,2}):(\d{2})(?::\d{2}(?:\.\d+)?)?$/.exec(body);
  if (!m) throw invalidDateTime(raw);
  const h = Number(m[1]);
  const mi = Number(m[2]);
  if (h > 23 || mi > 59) throw invalidDateTime(raw);
  return { day, minute: h * 60 + mi, offsetSeconds };
}

function eventInstant(p: ParsedTime): number {
  return dayToMs(p.day) + (p.minute ?? 0) * 60_000 - (p.offsetSeconds ?? 0) * 1000;
}

function allDay(day: string, through: string): Schedule {
  return { startDay: day, startMinute: null, endDay: through > day ? through : null, endMinute: null, timeZone: null };
}

/** Shared core of `scheduleFromAPI` and `scheduleWithDue`. */
function build(ps: ParsedTime | null, pd: ParsedTime | null, isAllDay: boolean, zone: string | null): Schedule {
  const first = ps ?? pd;
  if (!first) throw new ScheduleError('start or due is required');
  if (isAllDay) {
    const s = first.day;
    const e = (ps && pd ? pd.day : null) ?? s;
    if (e < s) throw endBeforeStart();
    return allDay(s, e);
  }
  const wall = (p: ParsedTime): { day: string; minute: number } => {
    const minute = p.minute ?? 0;
    if (p.offsetSeconds === null || zone === null) return { day: p.day, minute };
    return wallClockAt(eventInstant(p), zone);
  };
  const start = wall(first);
  const out: Schedule = { startDay: start.day, startMinute: start.minute, endDay: null, endMinute: null, timeZone: zone };
  if (ps && pd) {
    const end = wall(pd);
    const offset = daysBetween(start.day, end.day) * 1440 + end.minute;
    if (offset < start.minute) throw endBeforeStart();
    if (offset > start.minute) {
      out.endDay = end.day;
      out.endMinute = end.minute;
    }
  }
  return out;
}

function checkZone(tz: string | null | undefined): void {
  if (tz != null && !isValidTimeZone(tz)) throw unknownTimeZone(tz);
}

export interface ScheduleInput {
  start?: string | null;
  due?: string | null;
  allDay?: boolean | null;
  timeZone?: string | null;
}

export interface ScheduleContext {
  /** The task's current `timeZone` when updating. */
  originalTimeZone?: string | null;
  /** `DEFAULT_TIMEZONE`, tried first when inferring a zone from an offset. */
  defaultTimeZone: string;
}

/**
 * `Schedule.fromAPI`: builds the schedule from TickTick-style fields.
 * - No offset: wall clock in the zone (floating when there is none).
 * - With an offset: converted into the zone; zone order is `timeZone`,
 *   the original task's zone, then inferred from the offset at the event.
 * - All-day: dates only, `due` is the inclusive last day.
 */
export function scheduleFromAPI(input: ScheduleInput, ctx: ScheduleContext): Schedule | null {
  const { start, due } = input;
  if (start == null && due == null) return null;
  checkZone(input.timeZone);
  const ps = start == null ? null : parse(start);
  const pd = due == null ? null : parse(due);
  const first = (ps ?? pd) as ParsedTime;
  const isAllDay = input.allDay ?? first.minute === null;
  let zone = input.timeZone ?? ctx.originalTimeZone ?? null;
  if (zone === null && !isAllDay && first.offsetSeconds !== null) {
    zone = inferTimeZone(first.offsetSeconds, eventInstant(first), ctx.defaultTimeZone);
  }
  return build(ps, pd, isAllDay, zone);
}

/**
 * Update with only `due`: keeps the current start's wall-clock fields and
 * zone (a floating task stays floating) and rebuilds the end from `due`.
 */
export function scheduleWithDue(
  cur: Schedule,
  input: { due: string; allDay?: boolean | null; timeZone?: string | null },
): Schedule {
  checkZone(input.timeZone);
  const pd = parse(input.due);
  const isAllDay = input.allDay ?? cur.startMinute === null;
  const ps: ParsedTime = { day: cur.startDay, minute: isAllDay ? null : cur.startMinute, offsetSeconds: null };
  return build(ps, pd, isAllDay, input.timeZone ?? cur.timeZone);
}

// MARK: - Output

function pad2(n: number): string {
  return String(n).padStart(2, '0');
}

function iso(day: string, minute: number, zone: string | null): string {
  if (zone === null) return `${day}T${pad2(Math.floor(minute / 60))}:${pad2(minute % 60)}:00`;
  const t = instantOf(day, minute, zone);
  const w = wallClockAt(t, zone);
  const off = offsetAt(zone, t);
  const abs = Math.abs(off);
  const suffix =
    off === 0 ? 'Z' : `${off < 0 ? '-' : '+'}${pad2(Math.floor(abs / 3600))}:${pad2(Math.floor((abs % 3600) / 60))}`;
  return `${w.day}T${pad2(Math.floor(w.minute / 60))}:${pad2(w.minute % 60)}:00${suffix}`;
}

/** `start`/`due`/`all_day`/`timezone`: dates for all-day, ISO with offset when zoned, no offset when floating. */
export function scheduleToAPI(s: Schedule): ScheduleAPI {
  if (s.startMinute === null) {
    return { start: s.startDay, due: s.endDay, all_day: true, timezone: s.timeZone };
  }
  const due = s.endDay !== null && s.endMinute !== null ? iso(s.endDay, s.endMinute, s.timeZone) : null;
  return { start: iso(s.startDay, s.startMinute, s.timeZone), due, all_day: false, timezone: s.timeZone };
}

/** `Schedule.moved(to:)`: new start day, same shape. */
export function movedSchedule(s: Schedule, day: string): Schedule {
  const delta = daysBetween(s.startDay, day);
  return { ...s, startDay: day, endDay: s.endDay === null ? null : addDays(s.endDay, delta) };
}
