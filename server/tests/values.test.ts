import { describe, expect, it } from 'vitest';
import { isNil, rowSchedule, sameSchedule, sameValue, scheduleColumns } from '../src/serverops/values';

const timed = { startDay: '2026-11-20', startMinute: 540, endDay: '2026-11-20', endMinute: 600, timeZone: 'Asia/Taipei' };

describe('serverops values', () => {
  it('treats null and undefined alike', () => {
    expect([null, undefined, 0, '', false].map(isNil)).toEqual([true, true, false, false, false]);
    expect(sameValue(null, undefined)).toBe(true);
    expect(sameValue(0, null)).toBe(false);
    expect(sameValue(['a'], ['a'])).toBe(true);
    expect(sameValue(['a'], [])).toBe(false);
    expect(sameValue('x', 'x')).toBe(true);
  });

  it('writes all five schedule columns, nulls when cleared', () => {
    expect(scheduleColumns(timed)).toEqual(timed);
    expect(scheduleColumns(null)).toEqual({ startDay: null, startMinute: null, endDay: null, endMinute: null, timeZone: null });
  });

  it('reads a row schedule and compares schedules', () => {
    expect(rowSchedule({ ...timed, title: 't' })).toEqual(timed);
    expect(rowSchedule({ startDay: null })).toBeNull();
    expect(rowSchedule({ startDay: '2026-11-20' })).toEqual({ startDay: '2026-11-20', startMinute: null, endDay: null, endMinute: null, timeZone: null });
    expect(sameSchedule(timed, { ...timed })).toBe(true);
    expect(sameSchedule(timed, { ...timed, timeZone: null })).toBe(false);
    expect(sameSchedule(null, null)).toBe(true);
    expect(sameSchedule(timed, null)).toBe(false);
  });
});
