import { describe, it, expect } from 'vitest';
import { applyFilter } from '../src/ics/filters';
import type { IcsFilter, ParsedEvent } from '../src/ics/types';

// Deterministic clock: 2026-06-11T00:00:00Z
const NOW_MS = Date.parse('2026-06-11T00:00:00Z');
const DAY = 24 * 60 * 60 * 1000;

function ev(partial: Partial<ParsedEvent> & { uid: string; start: string }): ParsedEvent {
  return {
    summary: partial.summary ?? 'Event',
    allDay: partial.allDay ?? false,
    ...partial,
  };
}

function isoFromNow(deltaDays: number): string {
  return new Date(NOW_MS + deltaDays * DAY).toISOString();
}

describe('applyFilter', () => {
  it('returns all events unchanged when filter is null', () => {
    const events = [ev({ uid: 'a', start: isoFromNow(1) }), ev({ uid: 'b', start: isoFromNow(-1) })];
    expect(applyFilter(events, null, NOW_MS)).toEqual(events);
  });

  it('returns all events unchanged when filter is undefined', () => {
    const events = [ev({ uid: 'a', start: isoFromNow(1) })];
    expect(applyFilter(events, undefined, NOW_MS)).toEqual(events);
  });

  it('returns all events unchanged for an empty filter object', () => {
    const events = [ev({ uid: 'a', start: isoFromNow(100) }), ev({ uid: 'b', start: isoFromNow(-100) })];
    expect(applyFilter(events, {}, NOW_MS)).toEqual(events);
  });

  it('treats an empty excludeKeywords array as no rule', () => {
    const events = [ev({ uid: 'a', start: isoFromNow(100) })];
    expect(applyFilter(events, { excludeKeywords: [] }, NOW_MS)).toEqual(events);
  });

  describe('futureDays', () => {
    const filter: IcsFilter = { futureDays: 7 };

    it('drops events starting after now + futureDays', () => {
      const events = [
        ev({ uid: 'soon', start: isoFromNow(3) }),
        ev({ uid: 'far', start: isoFromNow(10) }),
      ];
      const out = applyFilter(events, filter, NOW_MS);
      expect(out.map((e) => e.uid)).toEqual(['soon']);
    });

    it('keeps an event exactly at the cutoff boundary', () => {
      const events = [ev({ uid: 'edge', start: isoFromNow(7) })];
      expect(applyFilter(events, filter, NOW_MS).map((e) => e.uid)).toEqual(['edge']);
    });

    it('keeps past events (not constrained by futureDays)', () => {
      const events = [ev({ uid: 'past', start: isoFromNow(-30) })];
      expect(applyFilter(events, filter, NOW_MS).map((e) => e.uid)).toEqual(['past']);
    });
  });

  describe('pastDays', () => {
    const filter: IcsFilter = { pastDays: 7 };

    it('drops events starting before now - pastDays', () => {
      const events = [
        ev({ uid: 'recent', start: isoFromNow(-3) }),
        ev({ uid: 'old', start: isoFromNow(-10) }),
      ];
      const out = applyFilter(events, filter, NOW_MS);
      expect(out.map((e) => e.uid)).toEqual(['recent']);
    });

    it('keeps an event exactly at the past cutoff boundary', () => {
      const events = [ev({ uid: 'edge', start: isoFromNow(-7) })];
      expect(applyFilter(events, filter, NOW_MS).map((e) => e.uid)).toEqual(['edge']);
    });

    it('keeps far-future events (not constrained by pastDays)', () => {
      const events = [ev({ uid: 'future', start: isoFromNow(365) })];
      expect(applyFilter(events, filter, NOW_MS).map((e) => e.uid)).toEqual(['future']);
    });
  });

  describe('excludeKeywords', () => {
    it('drops events whose summary contains a keyword (case-insensitive)', () => {
      const events = [
        ev({ uid: 'keep', summary: 'Team standup', start: isoFromNow(1) }),
        ev({ uid: 'drop', summary: 'LUNCH with Bob', start: isoFromNow(1) }),
      ];
      const out = applyFilter(events, { excludeKeywords: ['lunch'] }, NOW_MS);
      expect(out.map((e) => e.uid)).toEqual(['keep']);
    });

    it('matches against description and location too', () => {
      const events = [
        ev({ uid: 'desc', summary: 'Mtg', description: 'Optional sync', start: isoFromNow(1) }),
        ev({ uid: 'loc', summary: 'Mtg', location: 'Optional room', start: isoFromNow(1) }),
        ev({ uid: 'keep', summary: 'Mtg', description: 'Required', start: isoFromNow(1) }),
      ];
      const out = applyFilter(events, { excludeKeywords: ['optional'] }, NOW_MS);
      expect(out.map((e) => e.uid)).toEqual(['keep']);
    });

    it('drops if any of several keywords matches', () => {
      const events = [
        ev({ uid: 'a', summary: 'Holiday party', start: isoFromNow(1) }),
        ev({ uid: 'b', summary: 'Sprint review', start: isoFromNow(1) }),
        ev({ uid: 'c', summary: 'Birthday lunch', start: isoFromNow(1) }),
      ];
      const out = applyFilter(events, { excludeKeywords: ['holiday', 'lunch'] }, NOW_MS);
      expect(out.map((e) => e.uid)).toEqual(['b']);
    });
  });

  describe('combined rules (AND semantics)', () => {
    it('requires an event to pass every rule', () => {
      const filter: IcsFilter = { futureDays: 7, pastDays: 7, excludeKeywords: ['skip'] };
      const events = [
        ev({ uid: 'good', summary: 'Real work', start: isoFromNow(2) }),
        ev({ uid: 'tooFar', summary: 'Real work', start: isoFromNow(20) }),
        ev({ uid: 'tooOld', summary: 'Real work', start: isoFromNow(-20) }),
        ev({ uid: 'keyword', summary: 'skip this', start: isoFromNow(2) }),
        ev({ uid: 'windowOkButKw', summary: 'please skip', start: isoFromNow(-2) }),
      ];
      const out = applyFilter(events, filter, NOW_MS);
      expect(out.map((e) => e.uid)).toEqual(['good']);
    });
  });

  it('keeps events with an unparseable start date for window rules but still applies keywords', () => {
    const filter: IcsFilter = { futureDays: 1, excludeKeywords: ['bad'] };
    const events = [
      ev({ uid: 'unparseable', summary: 'ok', start: 'not-a-date' }),
      ev({ uid: 'unparseableKw', summary: 'bad one', start: 'garbage' }),
    ];
    const out = applyFilter(events, filter, NOW_MS);
    expect(out.map((e) => e.uid)).toEqual(['unparseable']);
  });

  it('does not mutate the input array', () => {
    const events = [ev({ uid: 'drop', start: isoFromNow(100) }), ev({ uid: 'keep', start: isoFromNow(1) })];
    const copy = [...events];
    applyFilter(events, { futureDays: 7 }, NOW_MS);
    expect(events).toEqual(copy);
  });
});
