import { readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import {
  addDays,
  addMonths,
  daysBetween,
  inferTimeZone,
  isValidDay,
  isValidTimeZone,
  movedSchedule,
  type Schedule,
  ScheduleError,
  scheduleFromAPI,
  scheduleToAPI,
  scheduleWithDue,
  wallClockAt,
  weekday,
} from '../src/domain/schedule';
import {
  formatRecurrence,
  nextOccurrence,
  parseRecurrence,
  validateRepeat,
} from '../src/domain/recurrence';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const fixturePath = path.resolve(__dirname, '../../spec/fixtures/sync-ops.json');

const ctx = { defaultTimeZone: 'Asia/Taipei' };

function fromAPI(
  input: { start?: string; due?: string; allDay?: boolean; timeZone?: string },
  extra: { originalTimeZone?: string | null; defaultTimeZone?: string } = {},
): Schedule {
  const s = scheduleFromAPI(input, { ...ctx, ...extra });
  if (!s) throw new Error('expected a schedule');
  return s;
}

const sched = (
  startDay: string,
  startMinute: number | null,
  endDay: string | null = null,
  endMinute: number | null = null,
  timeZone: string | null = null,
): Schedule => ({ startDay, startMinute, endDay, endMinute, timeZone });

describe('LocalDay helpers', () => {
  it('validates real calendar dates', () => {
    expect(isValidDay('2026-11-15')).toBe(true);
    expect(isValidDay('2028-02-29')).toBe(true);
    expect(isValidDay('2026-02-29')).toBe(false);
    expect(isValidDay('2026-02-30')).toBe(false);
    expect(isValidDay('2026-04-31')).toBe(false);
    expect(isValidDay('2026-13-01')).toBe(false);
    expect(isValidDay('2026-1-5')).toBe(false);
  });

  it('does day and month arithmetic in UTC with month-end clamping', () => {
    expect(addDays('2026-11-15', 7)).toBe('2026-11-22');
    expect(addDays('2026-03-08', 1)).toBe('2026-03-09');
    expect(addDays('2026-12-31', 1)).toBe('2027-01-01');
    expect(addDays('2026-03-01', -1)).toBe('2026-02-28');
    expect(addMonths('2027-01-31', 1)).toBe('2027-02-28');
    expect(addMonths('2028-02-29', 12)).toBe('2029-02-28');
    expect(daysBetween('2026-11-15', '2026-11-22')).toBe(7);
    expect(daysBetween('2026-03-07', '2026-03-09')).toBe(2);
    expect(weekday('2026-11-15')).toBe(0);
    expect(weekday('2026-11-13')).toBe(5);
  });
});

describe('time zones', () => {
  it('accepts IANA names only', () => {
    expect(isValidTimeZone('Asia/Taipei')).toBe(true);
    expect(isValidTimeZone('UTC')).toBe(true);
    expect(isValidTimeZone('America/Los_Angeles')).toBe(true);
    expect(isValidTimeZone('Nope/Nowhere')).toBe(false);
    expect(isValidTimeZone('+08:00')).toBe(false);
    expect(isValidTimeZone('-0500')).toBe(false);
    // The App cannot resolve a wrongly cased identifier.
    expect(isValidTimeZone('asia/taipei')).toBe(false);
  });

  it('reads wall clock from Intl components', () => {
    expect(wallClockAt(Date.UTC(2026, 10, 15, 16, 30), 'Asia/Taipei')).toEqual({
      day: '2026-11-16',
      minute: 30,
    });
    expect(wallClockAt(Date.UTC(2026, 2, 8, 10, 0), 'America/Los_Angeles')).toEqual({
      day: '2026-03-08',
      minute: 3 * 60,
    });
  });

  it('infers the zone from the offset at the event instant', () => {
    // -04:00 only matches New York in summer, regardless of today's date.
    expect(inferTimeZone(-4 * 3600, Date.UTC(2026, 6, 15, 14), 'Asia/Taipei')).toBe(
      'America/New_York',
    );
    expect(inferTimeZone(-4 * 3600, Date.UTC(2026, 0, 15, 14), 'Asia/Taipei')).toBe('UTC');
    expect(inferTimeZone(-8 * 3600, Date.UTC(2026, 0, 15, 18), 'Asia/Taipei')).toBe(
      'America/Los_Angeles',
    );
    // London before Paris in summer, Paris in winter.
    expect(inferTimeZone(3600, Date.UTC(2026, 6, 15, 9), 'Asia/Taipei')).toBe('Europe/London');
    expect(inferTimeZone(3600, Date.UTC(2026, 0, 15, 9), 'Asia/Taipei')).toBe('Europe/Paris');
    // DEFAULT_TIMEZONE is tried before the fixed list.
    expect(inferTimeZone(8 * 3600, Date.UTC(2026, 6, 15), 'Asia/Shanghai')).toBe('Asia/Shanghai');
    expect(inferTimeZone(8 * 3600, Date.UTC(2026, 6, 15), 'Asia/Taipei')).toBe('Asia/Taipei');
  });
});

describe('scheduleFromAPI', () => {
  it('returns null without start or due', () => {
    expect(scheduleFromAPI({}, ctx)).toBeNull();
  });

  it('parses TickTick-style ISO with offset (Swift vector)', () => {
    const s = fromAPI({
      start: '2026-11-15T18:00:00+0800',
      due: '2026-11-15T18:30:00+0800',
      timeZone: 'Asia/Taipei',
    });
    expect(s).toEqual(sched('2026-11-15', 1080, '2026-11-15', 1110, 'Asia/Taipei'));
    expect(scheduleToAPI(s)).toEqual({
      start: '2026-11-15T18:00:00+08:00',
      due: '2026-11-15T18:30:00+08:00',
      all_day: false,
      timezone: 'Asia/Taipei',
    });
  });

  it('converts an offset into the zone (Swift vector)', () => {
    const s = fromAPI({ start: '2026-11-15T10:00:00Z', timeZone: 'Asia/Taipei' });
    expect(s).toEqual(sched('2026-11-15', 18 * 60, null, null, 'Asia/Taipei'));
  });

  it('treats wall clock without offset or zone as floating (Swift vector)', () => {
    const s = fromAPI({ start: '2026-11-15T09:30' });
    expect(s).toEqual(sched('2026-11-15', 570));
    expect(scheduleToAPI(s)).toEqual({
      start: '2026-11-15T09:30:00',
      due: null,
      all_day: false,
      timezone: null,
    });
  });

  it('builds multi-day all-day schedules with inclusive due (Swift vector)', () => {
    const s = fromAPI({ start: '2026-11-13', due: '2026-11-16' });
    expect(s).toEqual(sched('2026-11-13', null, '2026-11-16'));
    expect(scheduleToAPI(s)).toEqual({
      start: '2026-11-13',
      due: '2026-11-16',
      all_day: true,
      timezone: null,
    });
    expect(fromAPI({ start: '2026-11-13', due: '2026-11-13' })).toEqual(sched('2026-11-13', null));
  });

  it('all-day with only due uses its literal date and drops the time', () => {
    expect(fromAPI({ due: '2026-04-20T00:00:00+0800', allDay: true })).toEqual(
      sched('2026-04-20', null),
    );
    expect(fromAPI({ start: '2026-11-15T23:30:00+0800', allDay: true, timeZone: 'UTC' })).toEqual(
      sched('2026-11-15', null),
    );
  });

  it('timed with only due becomes a point at due', () => {
    expect(fromAPI({ due: '2026-11-15T17:00:00+0800' })).toEqual(
      sched('2026-11-15', 1020, null, null, 'Asia/Taipei'),
    );
  });

  it('rejects due before start with the Swift message', () => {
    expect(() => fromAPI({ start: '2026-11-15T18:00', due: '2026-11-15T17:00' })).toThrow(
      new ScheduleError('due must not be before start'),
    );
    expect(() => fromAPI({ start: '2026-11-16', due: '2026-11-15' })).toThrow(
      'due must not be before start',
    );
  });

  it('drops the end when due equals start', () => {
    expect(fromAPI({ start: '2026-11-15T18:00', due: '2026-11-15T18:00' })).toEqual(
      sched('2026-11-15', 1080),
    );
  });

  it('rejects invalid input with the Swift messages', () => {
    for (const bad of ['2026-02-30', '2026-02-30T10:00', 'tomorrow', '2026-11-15T25:00', '2026-11-15X10:00', '2026-11-15T10:00+8']) {
      expect(() => fromAPI({ start: bad }), bad).toThrow(`Invalid ISO 8601 date/time: ${bad}`);
    }
    expect(() => fromAPI({ start: '2026-11-15', timeZone: 'Nope/X' })).toThrow(
      'Unknown IANA time zone: Nope/X',
    );
    expect(() => fromAPI({ start: '2026-11-15T10:00', timeZone: '+08:00' })).toThrow(
      'Unknown IANA time zone: +08:00',
    );
  });

  it('accepts the input forms Swift accepts', () => {
    const want = sched('2026-11-15', 1080, null, null, 'Asia/Taipei');
    expect(fromAPI({ start: '2026-11-15 18:00+08:00' })).toEqual(want);
    expect(fromAPI({ start: ' 2026-11-15T18:00:00+08:00 ' })).toEqual(want);
    expect(fromAPI({ start: '2026-11-15T10:00:00.000Z', timeZone: 'Asia/Taipei' })).toEqual(want);
    expect(fromAPI({ start: '2026-11-15T10:00:00.000+0000', timeZone: 'Asia/Taipei' })).toEqual(want);
  });

  it('infers in order: timezone, original task zone, offset at event, UTC', () => {
    // 1. caller zone wins
    expect(fromAPI({ start: '2026-11-15T10:00:00Z', timeZone: 'Asia/Tokyo' }, { originalTimeZone: 'Asia/Taipei' }).timeZone).toBe('Asia/Tokyo');
    // 2. original task zone; offset converted into it, wall clock without offset kept
    expect(fromAPI({ start: '2026-11-15T10:00:00Z' }, { originalTimeZone: 'Asia/Tokyo' })).toEqual(
      sched('2026-11-15', 19 * 60, null, null, 'Asia/Tokyo'),
    );
    expect(fromAPI({ start: '2026-11-15T10:00' }, { originalTimeZone: 'Asia/Tokyo' })).toEqual(
      sched('2026-11-15', 600, null, null, 'Asia/Tokyo'),
    );
    // 3. inferred from offset at the event instant
    expect(fromAPI({ start: '2026-07-15T10:00:00-04:00' })).toEqual(
      sched('2026-07-15', 600, null, null, 'America/New_York'),
    );
    // 4. nothing matches: UTC
    expect(fromAPI({ start: '2026-01-15T10:00:00-04:00' })).toEqual(
      sched('2026-01-15', 14 * 60, null, null, 'UTC'),
    );
  });

  it('handles DST transition days (America/Los_Angeles)', () => {
    // Spring forward 2026-03-08: 01:30 PST to 03:30 PDT is one real hour, two wall hours.
    const spring = fromAPI({ start: '2026-03-08T01:30:00-08:00', due: '2026-03-08T03:30:00-07:00' });
    expect(spring).toEqual(sched('2026-03-08', 90, '2026-03-08', 210, 'America/Los_Angeles'));
    expect(scheduleToAPI(spring)).toEqual({
      start: '2026-03-08T01:30:00-08:00',
      due: '2026-03-08T03:30:00-07:00',
      all_day: false,
      timezone: 'America/Los_Angeles',
    });
    // 09:00 on the transition day stays 09:00 (not midnight plus minutes).
    const nine = fromAPI({ start: '2026-03-08T09:00', timeZone: 'America/Los_Angeles' });
    expect(scheduleToAPI(nine).start).toBe('2026-03-08T09:00:00-07:00');
    // A wall time in the gap resolves forward, like Foundation.
    expect(scheduleToAPI(sched('2026-03-08', 150, null, null, 'America/Los_Angeles')).start).toBe(
      '2026-03-08T03:30:00-07:00',
    );
    // Fall back 2026-11-01: ambiguous 01:30 picks the first occurrence, like Foundation.
    expect(scheduleToAPI(sched('2026-11-01', 90, null, null, 'America/Los_Angeles')).start).toBe(
      '2026-11-01T01:30:00-07:00',
    );
    expect(scheduleToAPI(sched('2026-11-01', 9 * 60, null, null, 'America/Los_Angeles')).start).toBe(
      '2026-11-01T09:00:00-08:00',
    );
    // Same instant after fall-back is converted to PST wall clock.
    expect(fromAPI({ start: '2026-11-01T10:00:00Z', timeZone: 'America/Los_Angeles' })).toEqual(
      sched('2026-11-01', 2 * 60, null, null, 'America/Los_Angeles'),
    );
  });

  it('handles the ambiguous hour in an eastern zone (Australia/Sydney)', () => {
    // 2026-04-05 03:00 AEDT falls back to 02:00 AEST; 02:30 occurs twice.
    expect(scheduleToAPI(sched('2026-04-05', 150, null, null, 'Australia/Sydney')).start).toBe(
      '2026-04-05T02:30:00+11:00',
    );
  });

  it('crosses midnight', () => {
    const block = fromAPI({
      start: '2026-11-15T23:30:00+08:00',
      due: '2026-11-16T00:30:00+08:00',
    });
    expect(block).toEqual(sched('2026-11-15', 1410, '2026-11-16', 30, 'Asia/Taipei'));
    expect(scheduleToAPI(block).due).toBe('2026-11-16T00:30:00+08:00');
    // UTC instant rolls into the next Taipei day.
    expect(fromAPI({ start: '2026-11-15T16:30:00Z', timeZone: 'Asia/Taipei' })).toEqual(
      sched('2026-11-16', 30, null, null, 'Asia/Taipei'),
    );
    // Ending exactly at midnight.
    expect(fromAPI({ start: '2026-11-15T23:00', due: '2026-11-16T00:00' })).toEqual(
      sched('2026-11-15', 1380, '2026-11-16', 0),
    );
  });

  it('renders zero offset as Z like ISO8601DateFormatter', () => {
    expect(scheduleToAPI(sched('2026-11-15', 720, null, null, 'UTC')).start).toBe('2026-11-15T12:00:00Z');
    expect(scheduleToAPI(sched('2026-11-15', 720, null, null, 'Europe/London')).start).toBe(
      '2026-11-15T12:00:00Z',
    );
  });
});

describe('scheduleWithDue (update with only due)', () => {
  it('moves only the end of a zoned timed task', () => {
    const cur = sched('2026-11-15', 1080, '2026-11-15', 1110, 'Asia/Taipei');
    expect(scheduleWithDue(cur, { due: '2026-11-15T20:00:00+08:00' }, ctx)).toEqual(
      sched('2026-11-15', 1080, '2026-11-15', 1200, 'Asia/Taipei'),
    );
    expect(scheduleWithDue(cur, { due: '2026-11-15T12:00:00Z' }, ctx)).toEqual(
      sched('2026-11-15', 1080, '2026-11-15', 1200, 'Asia/Taipei'),
    );
  });

  it('keeps a floating task floating (no zone inference from the start)', () => {
    const cur = sched('2026-11-15', 570);
    expect(scheduleWithDue(cur, { due: '2026-11-15T11:00' }, ctx)).toEqual(
      sched('2026-11-15', 570, '2026-11-15', 660),
    );
  });

  it('converts an offset due on a floating task via DEFAULT_TIMEZONE and stays floating', () => {
    const cur = sched('2026-11-15', 1140);
    expect(scheduleWithDue(cur, { due: '2026-11-15T12:30:00Z' }, ctx)).toEqual(
      sched('2026-11-15', 1140, '2026-11-15', 1230),
    );
    expect(scheduleWithDue(cur, { due: '2026-11-15T20:30:00+08:00' }, ctx)).toEqual(
      sched('2026-11-15', 1140, '2026-11-15', 1230),
    );
    expect(
      scheduleWithDue(cur, { due: '2026-11-15T12:30:00Z' }, { defaultTimeZone: 'Asia/Tokyo' }),
    ).toEqual(sched('2026-11-15', 1140, '2026-11-15', 1290));
  });

  it('works on wall-clock fields on a DST day', () => {
    const cur = sched('2026-03-08', 90, null, null, 'America/Los_Angeles');
    expect(scheduleWithDue(cur, { due: '2026-03-08T04:00' }, ctx)).toEqual(
      sched('2026-03-08', 90, '2026-03-08', 240, 'America/Los_Angeles'),
    );
  });

  it('extends an all-day task and rejects due before start', () => {
    const cur = sched('2026-11-13', null);
    expect(scheduleWithDue(cur, { due: '2026-11-16' }, ctx)).toEqual(sched('2026-11-13', null, '2026-11-16'));
    expect(() => scheduleWithDue(cur, { due: '2026-11-12' }, ctx)).toThrow('due must not be before start');
  });

  it('honours an explicit timezone and validates it', () => {
    const cur = sched('2026-11-15', 1080, null, null, 'Asia/Taipei');
    expect(scheduleWithDue(cur, { due: '2026-11-15T19:00', timeZone: 'Asia/Tokyo' }, ctx)).toEqual(
      sched('2026-11-15', 1080, '2026-11-15', 1140, 'Asia/Tokyo'),
    );
    expect(() => scheduleWithDue(cur, { due: '2026-11-15T19:00', timeZone: 'Bad/Zone' }, ctx)).toThrow(
      'Unknown IANA time zone: Bad/Zone',
    );
  });
});

describe('movedSchedule', () => {
  it('keeps the shape, including a cross-midnight end', () => {
    const s = sched('2026-11-15', 1410, '2026-11-16', 30, 'Asia/Taipei');
    expect(movedSchedule(s, '2026-11-22')).toEqual(sched('2026-11-22', 1410, '2026-11-23', 30, 'Asia/Taipei'));
    expect(movedSchedule(sched('2026-11-13', null, '2026-11-16'), '2026-12-01')).toEqual(
      sched('2026-12-01', null, '2026-12-04'),
    );
    expect(movedSchedule(sched('2026-11-15', 600), '2026-11-14')).toEqual(sched('2026-11-14', 600));
  });
});

describe('recurrence', () => {
  it('next occurrences (Swift vectors)', () => {
    const next = (rule: string, day: string) => {
      const r = parseRecurrence(rule);
      if (!r) throw new Error(`unparsed ${rule}`);
      return nextOccurrence(r, day);
    };
    expect(next('RRULE:FREQ=DAILY', '2026-11-15')).toBe('2026-11-16');
    expect(next('RRULE:FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR', '2026-11-13')).toBe('2026-11-16');
    expect(next('RRULE:FREQ=MONTHLY;BYMONTHDAY=31', '2027-01-31')).toBe('2027-03-31');
    expect(next('RRULE:FREQ=YEARLY', '2028-02-29')).toBe('2032-02-29');
    expect(next('RRULE:FREQ=WEEKLY', '2026-11-15')).toBe('2026-11-22');
    expect(next('FREQ=DAILY;INTERVAL=3', '2026-12-30')).toBe('2027-01-02');
    expect(next('RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=MO', '2026-11-16')).toBe('2026-11-30');
    expect(next('RRULE:FREQ=MONTHLY', '2026-01-31')).toBe('2026-03-31');
    expect(next('rrule:freq=monthly;interval=0', '2026-11-15')).toBe('2026-12-15');
    expect(next('RRULE:FREQ=WEEKLY;BYDAY=1MO', '2026-11-15')).toBe('2026-11-16');
  });

  it('parses and formats the supported subset', () => {
    expect(parseRecurrence('RRULE:FREQ=WEEKLY;BYDAY=FR,MO')).toEqual({
      frequency: 'WEEKLY',
      interval: 1,
      byWeekday: [1, 5],
      byMonthDay: null,
    });
    expect(parseRecurrence('RRULE:INTERVAL=2')).toBeNull();
    expect(parseRecurrence('RRULE:FREQ=HOURLY')).toBeNull();
    // Swift's Int() overflows to nil and falls back to 1.
    expect(validateRepeat('FREQ=DAILY;INTERVAL=99999999999999999999999')).toBe('RRULE:FREQ=DAILY');
    expect(formatRecurrence({ frequency: 'MONTHLY', interval: 2, byWeekday: [], byMonthDay: 15 })).toBe(
      'RRULE:FREQ=MONTHLY;INTERVAL=2;BYMONTHDAY=15',
    );
  });

  it('validateRepeat keeps RRULE: strings verbatim and canonicalises bare rules', () => {
    expect(validateRepeat('RRULE:FREQ=WEEKLY;COUNT=3')).toBe('RRULE:FREQ=WEEKLY;COUNT=3');
    expect(validateRepeat('rrule:freq=daily')).toBe('rrule:freq=daily');
    expect(validateRepeat('FREQ=WEEKLY;BYDAY=MO;COUNT=3')).toBe('RRULE:FREQ=WEEKLY;BYDAY=MO');
    expect(() => validateRepeat('every day')).toThrow('Unsupported repeat rule: every day');
  });

  it('rejects negative, zero and non-integer BYMONTHDAY', () => {
    for (const bad of ['RRULE:FREQ=MONTHLY;BYMONTHDAY=-1', 'RRULE:FREQ=MONTHLY;BYMONTHDAY=0', 'FREQ=MONTHLY;BYMONTHDAY=32', 'RRULE:FREQ=MONTHLY;BYMONTHDAY=1,15']) {
      expect(() => validateRepeat(bad), bad).toThrow(`Unsupported repeat rule: ${bad}`);
      expect(parseRecurrence(bad), bad).toBeNull();
    }
  });
});

describe('schedules in the sync fixture', () => {
  type Row = Record<string, unknown>;
  const ops = (JSON.parse(readFileSync(fixturePath, 'utf8')) as { ops: { entity: string; row: Row }[] }).ops;
  const tasks = ops.filter((o) => o.entity === 'task').map((o) => o.row);
  const rowSchedule = (r: Row): Schedule => ({
    startDay: r.startDay as string,
    startMinute: (r.startMinute as number | undefined) ?? null,
    endDay: (r.endDay as string | undefined) ?? null,
    endMinute: (r.endMinute as number | undefined) ?? null,
    timeZone: (r.timeZone as string | undefined) ?? null,
  });
  const find = (pred: (r: Row) => boolean): Row => {
    const r = tasks.find(pred);
    if (!r) throw new Error('fixture row missing');
    return r;
  };

  it('the App create inputs produce the stored schedule fields', () => {
    const club = find((r) => r.title === '每週讀書會' && r.status === 0 && r.startDay === '2026-11-15');
    expect(
      fromAPI({ start: '2026-11-15T19:00:00+0800', due: '2026-11-15T20:30:00+0800', timeZone: 'Asia/Taipei' }),
    ).toEqual(rowSchedule(club));
    expect(validateRepeat(club.repeatRule as string)).toBe(club.repeatRule);

    const pending = find((r) => r.title === '待定行程' && r.repeatRule === 'RRULE:FREQ=DAILY');
    expect(fromAPI({ start: '2026-11-16T10:00:00+0800', timeZone: 'Asia/Taipei' })).toEqual(rowSchedule(pending));
  });

  it('completing the weekly task moves it to the next occurrence', () => {
    const before = find((r) => r.title === '每週讀書會' && r.status === 0 && r.startDay === '2026-11-15');
    const after = find((r) => r.title === '每週讀書會' && r.status === 0 && r.startDay !== '2026-11-15');
    const rule = parseRecurrence(before.repeatRule as string);
    if (!rule) throw new Error('rule');
    const s = rowSchedule(before);
    expect(movedSchedule(s, nextOccurrence(rule, s.startDay))).toEqual(rowSchedule(after));
    expect(scheduleToAPI(rowSchedule(after))).toEqual({
      start: '2026-11-22T19:00:00+08:00',
      due: '2026-11-22T20:30:00+08:00',
      all_day: false,
      timezone: 'Asia/Taipei',
    });
  });
});
