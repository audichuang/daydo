// Port of DayDoCore Recurrence.swift (RRULE subset) and LocalDayDoAPI.validateRepeat.
import { addDays, addMonths, daysBetween, daysInMonth, weekday } from './schedule';

export type Frequency = 'DAILY' | 'WEEKLY' | 'MONTHLY' | 'YEARLY';

export interface Recurrence {
  frequency: Frequency;
  interval: number;
  /** 0 = Sunday … 6 = Saturday (BYDAY). */
  byWeekday: number[];
  byMonthDay: number | null;
}

const FREQUENCIES: readonly string[] = ['DAILY', 'WEEKLY', 'MONTHLY', 'YEARLY'];
const DAY_CODES = ['SU', 'MO', 'TU', 'WE', 'TH', 'FR', 'SA'];
const INT_RE = /^[+-]?\d+$/;

/**
 * Parses the supported subset; null without a known FREQ. Unlike the App,
 * BYMONTHDAY must be a single day 1…31 (negative, zero or list values would
 * expand to an invalid day), otherwise the rule is rejected.
 */
export function parseRecurrence(rrule: string): Recurrence | null {
  let s = rrule;
  if (s.toUpperCase().startsWith('RRULE:')) s = s.slice(6);
  let frequency: Frequency | null = null;
  let interval = 1;
  let byWeekday: number[] = [];
  let byMonthDay: number | null = null;
  for (const part of s.split(';')) {
    const eq = part.indexOf('=');
    if (eq <= 0 || eq === part.length - 1) continue;
    const key = part.slice(0, eq).toUpperCase();
    const value = part.slice(eq + 1).toUpperCase();
    switch (key) {
      case 'FREQ':
        frequency = FREQUENCIES.includes(value) ? (value as Frequency) : null;
        break;
      case 'INTERVAL':
        // Swift's Int() returns nil on overflow, falling back to 1.
        interval = Math.max(1, INT_RE.test(value) && Number.isSafeInteger(Number(value)) ? Number(value) : 1);
        break;
      case 'BYDAY':
        byWeekday = value
          .split(',')
          .filter((c) => c !== '')
          .map((c) => DAY_CODES.indexOf(c.slice(-2)))
          .filter((i) => i >= 0)
          .sort((a, b) => a - b);
        break;
      case 'BYMONTHDAY': {
        const n = INT_RE.test(value) ? Number(value) : NaN;
        if (!(n >= 1 && n <= 31)) return null;
        byMonthDay = n;
        break;
      }
      default:
        break;
    }
  }
  if (frequency === null) return null;
  return { frequency, interval, byWeekday, byMonthDay };
}

/** Canonical `RRULE:` string (drops parts outside the subset). */
export function formatRecurrence(r: Recurrence): string {
  const parts = [`FREQ=${r.frequency}`];
  if (r.interval > 1) parts.push(`INTERVAL=${r.interval}`);
  if (r.byWeekday.length > 0) parts.push(`BYDAY=${r.byWeekday.map((d) => DAY_CODES[d]).join(',')}`);
  if (r.byMonthDay !== null) parts.push(`BYMONTHDAY=${r.byMonthDay}`);
  return `RRULE:${parts.join(';')}`;
}

/**
 * Largest INTERVAL we write: beyond it nextOccurrence can leave the supported year range or spend
 * seconds walking weeks. Reading stays lenient so rules written elsewhere still parse.
 */
export const MAX_INTERVAL = 999;

/**
 * Parses a rule we are willing to write; null when unsupported or the interval is too large.
 * Checks every raw INTERVAL too: parseRecurrence lowers digits beyond a safe integer to 1, but the
 * App's Int() reads them up to Int64 and overflows when computing the next occurrence.
 */
export function parseWritableRecurrence(rrule: string): Recurrence | null {
  const r = parseRecurrence(rrule);
  if (!r || r.interval > MAX_INTERVAL) return null;
  const body = rrule.toUpperCase().startsWith('RRULE:') ? rrule.slice(6) : rrule;
  for (const part of body.split(';')) {
    const eq = part.indexOf('=');
    if (eq <= 0 || part.slice(0, eq).toUpperCase() !== 'INTERVAL') continue;
    const value = part.slice(eq + 1);
    if (INT_RE.test(value) && Number(value) > MAX_INTERVAL) return null;
  }
  return r;
}

/** `RRULE:`-prefixed input is stored verbatim; bare rules are canonicalised. */
export function validateRepeat(s: string): string {
  const r = parseWritableRecurrence(s);
  if (!r) throw new Error(`Unsupported repeat rule: ${s}`);
  return s.toUpperCase().startsWith('RRULE:') ? s : formatRecurrence(r);
}

function withDay(monthDay: string, day: number): string {
  return `${monthDay.slice(0, 8)}${String(day).padStart(2, '0')}`;
}

/** First occurrence strictly after `day`. */
export function nextOccurrence(r: Recurrence, day: string): string {
  switch (r.frequency) {
    case 'DAILY':
      return addDays(day, r.interval);
    case 'WEEKLY': {
      if (r.byWeekday.length === 0) return addDays(day, 7 * r.interval);
      // Weeks are anchored on the Sunday of `day`'s week.
      const anchor = addDays(day, -weekday(day));
      let d = addDays(day, 1);
      for (let i = 0; i < 7 * r.interval + 7; i++) {
        const wd = weekday(d);
        const weeksApart = daysBetween(anchor, addDays(d, -wd)) / 7;
        if (r.byWeekday.includes(wd) && weeksApart % r.interval === 0) return d;
        d = addDays(d, 1);
      }
      return addDays(day, 7 * r.interval);
    }
    case 'MONTHLY': {
      const target = r.byMonthDay ?? Number(day.slice(8, 10));
      let m = withDay(day, 1);
      for (let i = 0; i < 48; i++) {
        m = addMonths(m, r.interval);
        if (target <= daysInMonth(m)) return withDay(m, target);
      }
      return addMonths(day, r.interval);
    }
    case 'YEARLY': {
      const [y, month, d] = [Number(day.slice(0, 4)), day.slice(5, 7), Number(day.slice(8, 10))];
      for (let i = 1; i <= 8; i++) {
        const first = `${String(y + i * r.interval).padStart(4, '0')}-${month}-01`;
        if (d <= daysInMonth(first)) return withDay(first, d);
      }
      return addMonths(day, 12 * r.interval);
    }
  }
}
