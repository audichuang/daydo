import { describe, expect, it } from 'vitest';
import { eventToTaskDraft, parseIcs, seriesSignatures } from '../src/ics/parser';
import { IcsError, type ParsedEvent } from '../src/ics/types';

const wrap = (vevents: string) =>
  `BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//test//EN\r\n${vevents}\r\nEND:VCALENDAR\r\n`;

describe('parseIcs', () => {
  it('parses a timed event with TZID into ISO + offset, not all-day', () => {
    const ics = wrap(
      [
        'BEGIN:VEVENT',
        'UID:timed-1@example.com',
        'SUMMARY:Standup',
        'DTSTART;TZID=Asia/Taipei:20260420T130000',
        'DTEND;TZID=Asia/Taipei:20260420T133000',
        'END:VEVENT',
      ].join('\r\n'),
    );
    const events = parseIcs(ics);
    expect(events).toHaveLength(1);
    const ev = events[0];
    expect(ev.uid).toBe('timed-1@example.com');
    expect(ev.summary).toBe('Standup');
    expect(ev.allDay).toBe(false);
    expect(ev.start).toBe('2026-04-20T13:00:00+0800');
    expect(ev.end).toBe('2026-04-20T13:30:00+0800');
  });

  it('parses an all-day event (VALUE=DATE / 8-digit date)', () => {
    const ics = wrap(
      [
        'BEGIN:VEVENT',
        'UID:allday-1',
        'SUMMARY:Holiday',
        'DTSTART;VALUE=DATE:20260501',
        'DTEND;VALUE=DATE:20260502',
        'END:VEVENT',
      ].join('\r\n'),
    );
    const [ev] = parseIcs(ics);
    expect(ev.allDay).toBe(true);
    expect(ev.start).toBe('2026-05-01');
    expect(ev.end).toBe('2026-05-02');
  });

  it('parses a bare 8-digit DTSTART as all-day', () => {
    const ics = wrap(
      ['BEGIN:VEVENT', 'UID:a2', 'SUMMARY:Day', 'DTSTART:20260601', 'END:VEVENT'].join('\r\n'),
    );
    const [ev] = parseIcs(ics);
    expect(ev.allDay).toBe(true);
    expect(ev.start).toBe('2026-06-01');
  });

  it('parses LOCATION, CATEGORIES and LAST-MODIFIED', () => {
    const ics = wrap(
      [
        'BEGIN:VEVENT',
        'UID:loc-1',
        'SUMMARY:Lunch',
        'DTSTART;TZID=Asia/Taipei:20260420T120000',
        'LOCATION:Cafe 85',
        'CATEGORIES:work,food',
        'LAST-MODIFIED:20260101T000000Z',
        'END:VEVENT',
      ].join('\r\n'),
    );
    const [ev] = parseIcs(ics);
    expect(ev.location).toBe('Cafe 85');
    expect(ev.categories).toEqual(['work', 'food']);
    expect(ev.lastModified).toBe('2026-01-01T00:00:00+0000');
  });

  it('splits CATEGORIES on unescaped commas only, then unescapes each value', () => {
    const ics = wrap(
      [
        'BEGIN:VEVENT',
        'UID:cat-esc-1',
        'SUMMARY:Escaped category',
        'DTSTART:20260420T080000Z',
        'CATEGORIES:Foo\\,Bar',
        'END:VEVENT',
      ].join('\r\n'),
    );
    const [ev] = parseIcs(ics);
    expect(ev.categories).toEqual(['Foo,Bar']);
  });

  it('unfolds folded lines and unescapes TEXT', () => {
    const ics = wrap(
      [
        'BEGIN:VEVENT',
        'UID:fold-1',
        'SUMMARY:Long meeting title that is very ',
        ' long indeed',
        'DESCRIPTION:line one\\nline two\\, still going\\; end',
        'DTSTART;TZID=Asia/Taipei:20260420T090000',
        'END:VEVENT',
      ].join('\r\n'),
    );
    const [ev] = parseIcs(ics);
    expect(ev.summary).toBe('Long meeting title that is very long indeed');
    expect(ev.description).toBe('line one\nline two, still going; end');
  });

  it("parses a UTC 'Z' time as +0000", () => {
    const ics = wrap(
      [
        'BEGIN:VEVENT',
        'UID:utc-1',
        'SUMMARY:Sync',
        'DTSTART:20260420T050000Z',
        'DTEND:20260420T053000Z',
        'END:VEVENT',
      ].join('\r\n'),
    );
    const [ev] = parseIcs(ics);
    expect(ev.allDay).toBe(false);
    expect(ev.start).toBe('2026-04-20T05:00:00+0000');
    expect(ev.end).toBe('2026-04-20T05:30:00+0000');
  });

  it('resolves an unlisted TZID (America/New_York) via Intl, not the Asia/Taipei fallback', () => {
    const ics = wrap(
      [
        'BEGIN:VEVENT',
        'UID:tz-ny-1',
        'SUMMARY:NY meeting',
        // 2026-01-15 is EST (UTC-05:00), no DST.
        'DTSTART;TZID=America/New_York:20260115T090000',
        'END:VEVENT',
      ].join('\r\n'),
    );
    const [ev] = parseIcs(ics);
    expect(ev.start).toBe('2026-01-15T09:00:00-0500');
  });

  it('resolves America/New_York DST-correctly in summer (EDT, UTC-04:00)', () => {
    const ics = wrap(
      [
        'BEGIN:VEVENT',
        'UID:tz-ny-2',
        'SUMMARY:NY summer meeting',
        'DTSTART;TZID=America/New_York:20260715T090000',
        'END:VEVENT',
      ].join('\r\n'),
    );
    const [ev] = parseIcs(ics);
    expect(ev.start).toBe('2026-07-15T09:00:00-0400');
  });

  it('resolves America/New_York across the spring-forward boundary (two-pass DST)', () => {
    // 2026-03-08 02:00 EST springs forward to 03:00 EDT, so 03:30 local is EDT
    // (-0400). A single-pass probe (wall-clock-as-UTC) would wrongly return -0500.
    const ics = wrap(
      [
        'BEGIN:VEVENT',
        'UID:tz-ny-dst',
        'SUMMARY:NY just after spring-forward',
        'DTSTART;TZID=America/New_York:20260308T033000',
        'END:VEVENT',
      ].join('\r\n'),
    );
    const [ev] = parseIcs(ics);
    expect(ev.start).toBe('2026-03-08T03:30:00-0400');
  });

  it('rejects an unresolved TZID before silently dropping an event', () => {
    // A bad TZID makes offsetMinutesFor throw; parseIcs must isolate that one
    // event, not abort the whole feed (which would fail the entire source sync).
    const ics = wrap(
      [
        'BEGIN:VEVENT',
        'UID:bad-tz',
        'SUMMARY:Bad zone',
        'DTSTART;TZID=Totally/Bogus:20260420T090000',
        'END:VEVENT',
        'BEGIN:VEVENT',
        'UID:good-tz',
        'SUMMARY:Good zone',
        'DTSTART;TZID=Asia/Taipei:20260420T090000',
        'END:VEVENT',
      ].join('\r\n'),
    );
    expect(() => parseIcs(ics)).toThrow(/Unknown TZID/);
  });

  it('treats a floating time (no TZID, no Z) as Asia/Taipei', () => {
    const ics = wrap(
      ['BEGIN:VEVENT', 'UID:f1', 'SUMMARY:Float', 'DTSTART:20260420T080000', 'END:VEVENT'].join(
        '\r\n',
      ),
    );
    const [ev] = parseIcs(ics);
    expect(ev.start).toBe('2026-04-20T08:00:00+0800');
  });

  it("flags RFC PRIORITY 1-4 and 'important' titles as high priority", () => {
    const ics = wrap(
      [
        'BEGIN:VEVENT',
        'UID:p1',
        'SUMMARY:Routine',
        'DTSTART:20260420T080000Z',
        'PRIORITY:2',
        'END:VEVENT',
        'BEGIN:VEVENT',
        'UID:p2',
        'SUMMARY:Important review',
        'DTSTART:20260420T090000Z',
        'END:VEVENT',
        'BEGIN:VEVENT',
        'UID:p3',
        'SUMMARY:Casual',
        'DTSTART:20260420T100000Z',
        'PRIORITY:7',
        'END:VEVENT',
      ].join('\r\n'),
    );
    const [a, b, c] = parseIcs(ics);
    expect(a.priorityHigh).toBe(true);
    expect(b.priorityHigh).toBe(true);
    expect(c.priorityHigh).toBeUndefined();
  });

  it('expands every occurrence of a finite RRULE', () => {
    const ics = wrap(
      [
        'BEGIN:VEVENT',
        'UID:rec-1',
        'SUMMARY:Weekly',
        'DTSTART;TZID=Asia/Taipei:20260420T090000',
        'RRULE:FREQ=WEEKLY;COUNT=5',
        'END:VEVENT',
      ].join('\r\n'),
    );
    const events = parseIcs(ics);
    expect(events).toHaveLength(5);
    expect(events[0].uid).toBe('rec-1');
    expect(new Set(events.map(e => e.occurrenceId)).size).toBe(5);
  });

  it('rejects a VEVENT with no DTSTART', () => {
    const ics = wrap(
      ['BEGIN:VEVENT', 'UID:no-start', 'SUMMARY:Broken', 'END:VEVENT'].join('\r\n'),
    );
    expect(() => parseIcs(ics)).toThrow(/Missing ICS DTSTART/);
  });

  it('parses multiple events in one calendar', () => {
    const ics = wrap(
      [
        'BEGIN:VEVENT',
        'UID:m1',
        'SUMMARY:One',
        'DTSTART:20260420T080000Z',
        'END:VEVENT',
        'BEGIN:VEVENT',
        'UID:m2',
        'SUMMARY:Two',
        'DTSTART:20260421T080000Z',
        'END:VEVENT',
      ].join('\r\n'),
    );
    expect(parseIcs(ics).map((e) => e.uid)).toEqual(['m1', 'm2']);
  });
});


describe('parseIcs identity and revisions', () => {
const wrapEvents = (events: string[]) => ['BEGIN:VCALENDAR', 'VERSION:2.0', ...events, 'END:VCALENDAR'].join('\r\n');
  const vevent = (lines: string[]) => ['BEGIN:VEVENT', ...lines, 'END:VEVENT'].join('\r\n');
  const window = { from: Date.parse('2026-10-01T00:00:00Z'), to: Date.parse('2026-11-01T00:00:00Z') };
  
  it("keeps each recurrence's original identity when an exception moves and the feed is reordered", () => {
    const master = vevent(['UID:series', 'DTSTART:20261005T010000Z', 'DTEND:20261005T020000Z', 'RRULE:FREQ=WEEKLY;COUNT=3', 'EXDATE:20261019T010000Z', 'RDATE:20261026T010000Z']);
    const moved = vevent(['UID:series', 'RECURRENCE-ID:20261012T010000Z', 'SEQUENCE:2', 'DTSTART:20261013T030000Z', 'DTEND:20261013T040000Z']);
    const before = parseIcs(wrapEvents([master, moved]), window).filter(e => !e.cancelled);
    expect(before.map(e => e.start).sort()).toEqual(['2026-10-05T01:00:00+0000', '2026-10-13T03:00:00+0000', '2026-10-26T01:00:00+0000']);
    const after = parseIcs(wrapEvents([moved.replaceAll('20261013', '20261014'), master]), window).filter(e => !e.cancelled);
    expect(after.map(e => e.occurrenceId).sort()).toEqual(before.map(e => e.occurrenceId).sort());
    expect(after.find(e => e.occurrenceId === 'UTC:2026-10-12T01:00:00Z')?.start).toBe('2026-10-14T03:00:00+0000');
  });
  
  it('includes DTSTART in an RDATE-only series, and EXDATE on DTSTART removes it', () => {
    const lines = ['UID:rdate', 'DTSTART:20261005T010000Z', 'DTEND:20261005T020000Z', 'RDATE:20261012T010000Z,20261019T010000Z'];
    const live = (events: string[]) => parseIcs(wrapEvents(events), window).filter(e => !e.cancelled);
    const all = live([vevent(lines)]);
    expect(all.map(e => e.start).sort()).toEqual(['2026-10-05T01:00:00+0000', '2026-10-12T01:00:00+0000', '2026-10-19T01:00:00+0000']);
    expect(all.map(e => e.occurrenceId).sort()).toEqual(['UTC:2026-10-05T01:00:00Z', 'UTC:2026-10-12T01:00:00Z', 'UTC:2026-10-19T01:00:00Z']);
    const excluded = parseIcs(wrapEvents([vevent([...lines, 'EXDATE:20261005T010000Z'])]), window);
    expect(excluded.filter(e => !e.cancelled).map(e => e.start).sort()).toEqual(['2026-10-12T01:00:00+0000', '2026-10-19T01:00:00+0000']);
    expect(excluded.find(e => e.occurrenceId === 'UTC:2026-10-05T01:00:00Z')?.cancelled).toBe(true);
    const moved = vevent(['UID:rdate', 'RECURRENCE-ID:20261005T010000Z', 'SEQUENCE:1', 'DTSTART:20261006T030000Z', 'DTEND:20261006T040000Z']);
    expect(live([vevent(lines), moved]).map(e => e.start).sort()).toEqual(['2026-10-06T03:00:00+0000', '2026-10-12T01:00:00+0000', '2026-10-19T01:00:00+0000']);
  });

  it('applies RANGE=THISANDFUTURE and cancellation without DTSTART to original slots', () => {
    const master = vevent(['UID:range', 'DTSTART:20261005T010000Z', 'DTEND:20261005T020000Z', 'RRULE:FREQ=WEEKLY;COUNT=3']);
    const shifted = vevent(['UID:range', 'RECURRENCE-ID;RANGE=THISANDFUTURE:20261012T010000Z', 'DTSTART:20261012T030000Z', 'DTEND:20261012T040000Z']);
    const result = parseIcs(wrapEvents([master, shifted]), window);
    expect(result.map(e => e.start).sort()).toEqual(['2026-10-05T01:00:00+0000', '2026-10-12T03:00:00+0000', '2026-10-19T03:00:00+0000']);
    const cancelled = vevent(['UID:range', 'RECURRENCE-ID:20261019T010000Z', 'STATUS:CANCELLED', 'SEQUENCE:2']);
    expect(parseIcs(wrapEvents([master, shifted, cancelled]), window).find(e => e.occurrenceId === 'UTC:2026-10-19T01:00:00Z')?.cancelled).toBe(true);
  });
  
  it("uses a feed's VTIMEZONE across DST without leaking it to another parse", () => {
    const zone = ['BEGIN:VTIMEZONE', 'TZID:Test/DST', 'BEGIN:STANDARD', 'DTSTART:19701025T030000', 'RRULE:FREQ=YEARLY;BYMONTH=10;BYDAY=-1SU', 'TZOFFSETFROM:+0200', 'TZOFFSETTO:+0100', 'END:STANDARD', 'BEGIN:DAYLIGHT', 'DTSTART:19700329T020000', 'RRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=-1SU', 'TZOFFSETFROM:+0100', 'TZOFFSETTO:+0200', 'END:DAYLIGHT', 'END:VTIMEZONE'].join('\r\n');
    const series = vevent(['UID:dst', 'DTSTART;TZID=Test/DST:20261024T090000', 'DTEND;TZID=Test/DST:20261024T100000', 'RRULE:FREQ=DAILY;COUNT=3']);
    const result = parseIcs(wrapEvents([zone, series]), window);
    expect(result.map(e => new Date(e.start).toISOString())).toEqual(['2026-10-24T07:00:00.000Z', '2026-10-25T08:00:00.000Z', '2026-10-26T08:00:00.000Z']);
    expect(() => parseIcs(wrapEvents([series]), window)).toThrow(/Unknown TZID/);
  });
  
  it('selects newer SEQUENCE independently of ordering and rejects equal-version conflicts', () => {
    const older = vevent(['UID:revision', 'SEQUENCE:1', 'SUMMARY:Old', 'DTSTART:20261005T010000Z']);
    const newer = older.replace('SEQUENCE:1', 'SEQUENCE:2').replace('SUMMARY:Old', 'SUMMARY:New');
    for (const pair of [[older, newer], [newer, older]]) expect(parseIcs(wrapEvents(pair), window)[0].summary).toBe('New');
    expect(() => parseIcs(wrapEvents([older, older.replace('SUMMARY:Old', 'SUMMARY:Conflict')]), window)).toThrow(/Conflicting/);
  });
  
  it('preserves all-day exclusive end and DURATION while rejecting impossible dates', () => {
    const result = parseIcs(wrapEvents([vevent(['UID:day', 'DTSTART;VALUE=DATE:20261005', 'DTEND;VALUE=DATE:20261007']), vevent(['UID:duration', 'DTSTART:20261005T010000Z', 'DURATION:PT30M'])]), window);
    expect(result[0]).toMatchObject({ allDay: true, start: '2026-10-05', end: '2026-10-07' });
    expect(result[1].end).toBe('2026-10-05T01:30:00+0000');
    expect(() => parseIcs(wrapEvents([vevent(['UID:bad', 'DTSTART:20260230T010000Z'])]), window)).toThrow(/Invalid ICS date/);
    expect(() => parseIcs(wrapEvents([vevent(['DTSTART:20261005T010000Z'])]), window)).toThrow(/Missing ICS UID/);
  });
});

describe('parseIcs time zone parameter', () => {
  const floating = wrap(
    ['BEGIN:VEVENT', 'UID:f2', 'SUMMARY:Float', 'DTSTART:20260420T080000', 'DTEND:20260420T090000', 'END:VEVENT'].join('\r\n'),
  );

  it('reads a floating time in the given zone, with that zone\'s offset', () => {
    const [ev] = parseIcs(floating, undefined, 'America/New_York');
    expect(ev.start).toBe('2026-04-20T08:00:00-0400');
    expect(ev.end).toBe('2026-04-20T09:00:00-0400');
  });

  it('applies the zone\'s DST offset at the event, not a fixed offset', () => {
    const winter = floating.replaceAll('20260420', '20260120');
    const [ev] = parseIcs(winter, undefined, 'America/New_York');
    expect(ev.start).toBe('2026-01-20T08:00:00-0500');
  });

  it('keeps UTC and TZID times unchanged by the zone parameter', () => {
    const ics = wrap(
      ['BEGIN:VEVENT', 'UID:u2', 'SUMMARY:U', 'DTSTART:20260420T050000Z', 'END:VEVENT', 'BEGIN:VEVENT', 'UID:t2', 'SUMMARY:T', 'DTSTART;TZID=Asia/Taipei:20260420T130000', 'END:VEVENT'].join('\r\n'),
    );
    const [utc, taipei] = parseIcs(ics, undefined, 'America/New_York');
    expect(utc.start).toBe('2026-04-20T05:00:00+0000');
    expect(taipei.start).toBe('2026-04-20T13:00:00+0800');
  });

  it('places an all-day event in the window by the given zone\'s midnight', () => {
    const ics = wrap(
      ['BEGIN:VEVENT', 'UID:d2', 'SUMMARY:Day', 'DTSTART;VALUE=DATE:20261001', 'END:VEVENT'].join('\r\n'),
    );
    // 2026-10-01T00:00 in Asia/Taipei is 2026-09-30T16:00Z, so a window opening at 2026-10-01T00:00Z
    // excludes it for Taipei but includes it for UTC.
    const window = { from: Date.parse('2026-10-01T00:00:00Z'), to: Date.parse('2026-11-01T00:00:00Z') };
    expect(parseIcs(ics, window, 'Asia/Taipei')).toHaveLength(0);
    expect(parseIcs(ics, window, 'UTC')).toHaveLength(1);
  });

  it('rejects an unknown zone', () => {
    expect(() => parseIcs(floating, undefined, 'Totally/Bogus')).toThrow(IcsError);
  });

  it('records the TZID of a zoned event and none for UTC or floating times', () => {
    const ics = wrap(
      ['BEGIN:VEVENT', 'UID:z1', 'SUMMARY:Z', 'DTSTART;TZID=America/New_York:20260115T090000', 'END:VEVENT', 'BEGIN:VEVENT', 'UID:z2', 'SUMMARY:U', 'DTSTART:20260115T090000Z', 'END:VEVENT', 'BEGIN:VEVENT', 'UID:z3', 'SUMMARY:F', 'DTSTART:20260115T090000', 'END:VEVENT'].join('\r\n'),
    );
    const [zoned, utc, float] = parseIcs(ics);
    expect(zoned.tzid).toBe('America/New_York');
    expect(utc.tzid).toBeUndefined();
    expect(float.tzid).toBeUndefined();
  });

  it('throws IcsError for malformed input', () => {
    expect(() => parseIcs('not a calendar')).toThrow(IcsError);
  });
});

describe('seriesSignatures', () => {
  const vevent = (uid: string, lines: string[]) => ['BEGIN:VEVENT', `UID:${uid}`, 'SUMMARY:x', ...lines, 'END:VEVENT'].join('\r\n');

  it('matches the signature parseIcs stamps on slots, for recurring masters only', () => {
    const ics = wrap(
      [
        vevent('bare-date', ['DTSTART:20260105', 'RRULE:FREQ=WEEKLY;COUNT=2']),
        vevent('zoned', ['DTSTART;TZID=America/New_York:20260105T090000', 'RRULE:FREQ=DAILY;COUNT=2']),
        vevent('rdate', ['DTSTART:20260105T010000Z', 'RDATE:20260110T010000Z']),
        vevent('single', ['DTSTART:20260105T010000Z']),
      ].join('\r\n'),
    );
    const fromSlots = new Map(parseIcs(ics, { from: 0, to: Date.parse('2027-01-01') }).map((e) => [e.uid, e.seriesSignature]));
    const signatures = seriesSignatures(ics);
    expect([...signatures.keys()].sort()).toEqual(['bare-date', 'rdate', 'zoned']);
    for (const [uid, signature] of signatures) expect(signature).toBe(fromSlots.get(uid));
  });
});

describe('eventToTaskDraft', () => {
  const parseOne = (lines: string[], tz?: string): ParsedEvent =>
    parseIcs(wrap(['BEGIN:VEVENT', ...lines, 'END:VEVENT'].join('\r\n')), undefined, tz)[0];

  it('maps a timed event: bare title, wall clock in the TZID, reminder, content with location', () => {
    const ev = parseOne([
      'UID:t1',
      'SUMMARY:Standup',
      'DTSTART;TZID=Asia/Taipei:20260420T130000',
      'DTEND;TZID=Asia/Taipei:20260420T133000',
      'LOCATION:Room 3',
      'DESCRIPTION:bring notes',
      'CATEGORIES:work',
    ]);
    expect(eventToTaskDraft(ev)).toEqual({
      title: 'Standup',
      content: 'bring notes\n\n📍 Room 3',
      schedule: { startDay: '2026-04-20', startMinute: 780, endDay: '2026-04-20', endMinute: 810, timeZone: 'Asia/Taipei' },
      priority: 0,
      reminders: ['TRIGGER:-PT15M'],
    });
  });

  it('does not turn categories into tags or set a repeat rule', () => {
    const draft = eventToTaskDraft(
      parseOne(['UID:c1', 'SUMMARY:Busy', 'DTSTART:20260420T080000Z', 'CATEGORIES:Busy,Meeting', 'RRULE:FREQ=DAILY;COUNT=2']),
    );
    expect(Object.keys(draft).sort()).toEqual(['content', 'priority', 'reminders', 'schedule', 'title']);
  });

  it('uses the event TZID wall clock, not the source zone', () => {
    const ev = parseOne(['UID:ny', 'SUMMARY:NY', 'DTSTART;TZID=America/New_York:20260115T090000', 'DTEND;TZID=America/New_York:20260115T100000']);
    const draft = eventToTaskDraft(ev, 'Asia/Taipei');
    expect(draft.schedule).toEqual({ startDay: '2026-01-15', startMinute: 540, endDay: '2026-01-15', endMinute: 600, timeZone: 'America/New_York' });
  });

  it('shows UTC and TZID representations of one moment as the same title and, for UTC, source-zone wall clock', () => {
    const utc = eventToTaskDraft(parseOne(['UID:utc', 'SUMMARY:Meeting', 'DTSTART:20261005T010000Z']));
    const local = eventToTaskDraft(parseOne(['UID:local', 'SUMMARY:Meeting', 'DTSTART;TZID=Asia/Taipei:20261005T090000']));
    expect(utc.title).toBe('Meeting');
    expect(local.title).toBe('Meeting');
    expect(utc.schedule).toEqual(local.schedule);
    expect(utc.schedule).toMatchObject({ startDay: '2026-10-05', startMinute: 540, timeZone: 'Asia/Taipei' });
  });

  it('converts a UTC event into the source zone when one is given', () => {
    const ev = parseOne(['UID:utc2', 'SUMMARY:Sync', 'DTSTART:20260420T050000Z', 'DTEND:20260420T060000Z']);
    expect(eventToTaskDraft(ev, 'America/New_York').schedule).toEqual({
      startDay: '2026-04-20', startMinute: 60, endDay: '2026-04-20', endMinute: 120, timeZone: 'America/New_York',
    });
  });

  it('reads a floating event in the source zone', () => {
    const ev = parseOne(['UID:fl', 'SUMMARY:Float', 'DTSTART:20260420T080000'], 'America/New_York');
    expect(eventToTaskDraft(ev, 'America/New_York').schedule).toMatchObject({
      startDay: '2026-04-20', startMinute: 480, endDay: null, endMinute: null, timeZone: 'America/New_York',
    });
  });

  it('falls back to the source zone when the TZID is not an IANA zone', () => {
    const ev = { ...parseOne(['UID:x', 'SUMMARY:X', 'DTSTART:20260420T050000Z']), tzid: 'Custom/Zone' };
    expect(eventToTaskDraft(ev, 'Asia/Taipei').schedule.timeZone).toBe('Asia/Taipei');
  });

  it('keeps an overnight timed event as start day plus next end day', () => {
    const ev = parseOne(['UID:night', 'SUMMARY:Night', 'DTSTART;TZID=Asia/Taipei:20260420T230000', 'DTEND;TZID=Asia/Taipei:20260421T010000']);
    expect(eventToTaskDraft(ev).schedule).toEqual({ startDay: '2026-04-20', startMinute: 1380, endDay: '2026-04-21', endMinute: 60, timeZone: 'Asia/Taipei' });
  });

  it('drops the end of a zero-length timed event', () => {
    const ev = parseOne(['UID:zero', 'SUMMARY:Zero', 'DTSTART;TZID=Asia/Taipei:20260420T130000', 'DTEND;TZID=Asia/Taipei:20260420T130000']);
    expect(eventToTaskDraft(ev).schedule).toMatchObject({ startMinute: 780, endDay: null, endMinute: null });
  });

  it('maps a single-day all-day event: no endDay, no reminder, empty content, no zone', () => {
    const ev = parseOne(['UID:t2', 'SUMMARY:Holiday', 'DTSTART;VALUE=DATE:20260704', 'DTEND;VALUE=DATE:20260705']);
    expect(eventToTaskDraft(ev)).toEqual({
      title: 'Holiday',
      content: '',
      schedule: { startDay: '2026-07-04', startMinute: null, endDay: null, endMinute: null, timeZone: null },
      priority: 0,
      reminders: [],
    });
  });

  it('keeps an all-day event without DTEND on the start day', () => {
    const ev = parseOne(['UID:t3', 'SUMMARY:Holiday', 'DTSTART;VALUE=DATE:20260501']);
    expect(eventToTaskDraft(ev).schedule).toMatchObject({ startDay: '2026-05-01', endDay: null });
  });

  it('makes a multi-day all-day endDay the inclusive last day (DTEND is exclusive)', () => {
    const ev = parseOne(['UID:t4', 'SUMMARY:Trip', 'DTSTART;VALUE=DATE:20261005', 'DTEND;VALUE=DATE:20261008']);
    expect(eventToTaskDraft(ev).schedule).toEqual({ startDay: '2026-10-05', startMinute: null, endDay: '2026-10-07', endMinute: null, timeZone: null });
  });

  it('maps RFC PRIORITY 1-4 and "important" titles to 5, others to 0', () => {
    expect(eventToTaskDraft(parseOne(['UID:p1', 'SUMMARY:Routine', 'DTSTART:20260420T080000Z', 'PRIORITY:2'])).priority).toBe(5);
    expect(eventToTaskDraft(parseOne(['UID:p2', 'SUMMARY:Important deadline', 'DTSTART:20260420T080000Z'])).priority).toBe(5);
    expect(eventToTaskDraft(parseOne(['UID:p3', 'SUMMARY:Casual', 'DTSTART:20260420T080000Z', 'PRIORITY:7'])).priority).toBe(0);
  });

  it('puts only the location in content when there is no description', () => {
    expect(eventToTaskDraft(parseOne(['UID:l1', 'SUMMARY:Lunch', 'DTSTART:20260420T080000Z', 'LOCATION:Cafe'])).content).toBe('📍 Cafe');
  });

  it('puts only the description in content when there is no location', () => {
    expect(eventToTaskDraft(parseOne(['UID:l2', 'SUMMARY:Lunch', 'DTSTART:20260420T080000Z', 'DESCRIPTION:notes'])).content).toBe('notes');
  });
});
