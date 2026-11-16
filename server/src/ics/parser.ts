/** RFC 5545 parsing (bounded expansion) and event-to-task-draft conversion. Fetching lives in fetch.ts. */

import ICAL from 'ical.js';
import { addDays, instantOf, isValidTimeZone, offsetAt, scheduleFromAPI } from '../domain/schedule';
import { FALLBACK_TIMEZONE, IcsError, type ParsedEvent, type TaskDraft } from './types';

type IcalTime = InstanceType<typeof ICAL.Time>;
type Component = InstanceType<typeof ICAL.Component>;

/** Slots starting in [from, to) are emitted; `includeIdentities` (JSON `[uid, occurrenceId]`) are emitted regardless. */
export interface ParseWindow { from: number; to: number; includeIdentities?: ReadonlySet<string> }
const MAX_OCCURRENCES = 2000;
const MAX_ITERATIONS = 50000;

function requireValid(ok: unknown, message: string): asserts ok {
  if (!ok) throw new IcsError(message);
}

/** ICU fallback for IANA zones omitted from VTIMEZONE; local to this parse. */
function intlZone(tzid: string): InstanceType<typeof ICAL.Timezone> {
  let formatter: Intl.DateTimeFormat;
  try { formatter = new Intl.DateTimeFormat('en-US', { timeZone: tzid, timeZoneName: 'longOffset' }); }
  catch { throw new IcsError(`Unknown TZID in ICS event: ${tzid}`); }
  const at = (ms: number) => {
    const offset = formatter.formatToParts(new Date(ms)).find(p => p.type === 'timeZoneName')?.value;
    if (offset === 'GMT') return 0;
    const match = /^GMT([+-])(\d{2}):(\d{2})$/.exec(offset ?? '');
    requireValid(match, `Unresolved TZID: ${tzid}`);
    return (match[1] === '-' ? -1 : 1) * (Number(match[2]) * 3600 + Number(match[3]) * 60);
  };
  const zone = new ICAL.Timezone({ tzid });
  zone.utcOffset = (time: IcalTime) => {
    const wall = Date.UTC(time.year, time.month - 1, time.day, time.hour, time.minute, time.second);
    return at(wall - at(wall) * 1000);
  };
  return zone;
}

/** Offset (seconds) of a floating wall-clock time read in `zone`. */
function floatingOffset(time: IcalTime, zone: string): number {
  const day = `${String(time.year).padStart(4, '0')}-${String(time.month).padStart(2, '0')}-${String(time.day).padStart(2, '0')}`;
  const instant = instantOf(day, time.hour * 60 + time.minute, zone) + time.second * 1000;
  return offsetAt(zone, instant);
}

/** ISO local time with a `+hhmm` offset. Floating times are read in `zone`. */
function iso(time: IcalTime, zone: string): string {
  if (time.isDate) return time.toString();
  const offset = time.zone.tzid === 'floating' ? floatingOffset(time, zone) : time.utcOffset();
  const sign = offset < 0 ? '-' : '+';
  const hh = String(Math.floor(Math.abs(offset) / 3600)).padStart(2, '0');
  const mm = String(Math.floor(Math.abs(offset) % 3600 / 60)).padStart(2, '0');
  return time.toString().replace(/Z$/, '') + sign + hh + mm;
}

function identity(time: IcalTime, zone: string): string {
  if (time.isDate) return `DATE:${time.toString()}`;
  if (time.zone.tzid === 'floating') return `FLOAT:${time.toString()}`;
  return `UTC:${new Date(Date.parse(iso(time, zone))).toISOString().replace('.000Z', 'Z')}`;
}

function rank(component: Component, zone: string): [number, number] {
  const sequence = Number(component.getFirstPropertyValue('sequence') ?? 0);
  requireValid(Number.isSafeInteger(sequence) && sequence >= 0, 'Invalid ICS SEQUENCE');
  const stamp = component.getFirstPropertyValue('dtstamp') as IcalTime | null;
  return [sequence, stamp ? Date.parse(iso(stamp, zone)) : 0];
}

/** Reject incomplete calendars before treating missing events as meaningful. */
function validateEnvelope(text: string): string {
  const lines = text.replace(/^\uFEFF/, '').replace(/\r\n|\r/g, "\n").replace(/\n[ \t]/g, '').trim().split("\n");
  requireValid(lines[0] === 'BEGIN:VCALENDAR' && lines.at(-1) === 'END:VCALENDAR', 'Expected a complete VCALENDAR');
  const stack: string[] = [];
  for (const line of lines) {
    if (line.startsWith('BEGIN:')) stack.push(line.slice(6));
    if (line.startsWith('END:')) requireValid(stack.pop() === line.slice(4), 'Truncated or mismatched ICS component');
    // ICAL normalizes impossible dates. Reject them at the input boundary.
    if (/^(DTSTART|DTEND|RECURRENCE-ID|RDATE|EXDATE|DTSTAMP|LAST-MODIFIED)[;:]/.test(line)) {
      const value = line.slice(line.indexOf(':') + 1);
      for (const raw of value.split(',')) {
        const m = /^(\d{4})(\d{2})(\d{2})(?:T(\d{2})(\d{2})(\d{2})Z?)?$/.exec(raw);
        requireValid(m, 'Invalid ICS date/time (period RDATE is unsupported)');
        const d = new Date(Date.UTC(+m[1], +m[2] - 1, +m[3]));
        requireValid(d.getUTCFullYear() === +m[1] && d.getUTCMonth() === +m[2] - 1 && d.getUTCDate() === +m[3] && +(m[4] ?? 0) < 24 && +(m[5] ?? 0) < 60 && +(m[6] ?? 0) < 60, 'Invalid ICS date/time');
      }
    }
  }
  requireValid(stack.length === 0, 'Truncated ICS component');
  // Some feeds omit VALUE=DATE on a bare date. Preserve existing compatibility.
  return lines.join("\r\n").replace(/^(DTSTART|DTEND|RECURRENCE-ID):(\d{8})$/gm, '$1;VALUE=DATE:$2');
}

/**
 * Validated calendar as each UID's winning revision per slot ('' is the master, others are
 * RECURRENCE-ID identities), with TZIDs resolved. `zone` reads floating times.
 */
function readRevisions(text: string, zone: string): Map<string, Map<string, Component>> {
  const root = new ICAL.Component(ICAL.parse(validateEnvelope(text)));
  requireValid(root.name === 'vcalendar' && root.getFirstPropertyValue('version') === '2.0', 'Expected VCALENDAR VERSION:2.0');
  const groups = new Map<string, Component[]>();
  const zones = new Map<string, InstanceType<typeof ICAL.Timezone>>();
  for (const component of root.getAllSubcomponents('vevent')) {
    const uid = component.getFirstPropertyValue('uid');
    requireValid(typeof uid === 'string' && uid.length > 0, 'Missing ICS UID');
    for (const name of ['dtstart', 'dtend', 'recurrence-id', 'rdate', 'exdate', 'dtstamp', 'last-modified']) {
      for (const property of component.getAllProperties(name)) {
        const tzid = property.getParameter('tzid');
        for (const value of property.getValues()) {
          requireValid(value instanceof ICAL.Time, 'Invalid ICS time property');
          if (tzid && value.zone.tzid === 'floating') {
            const zoneId = String(tzid);
            if (!zones.has(zoneId)) zones.set(zoneId, intlZone(zoneId));
            value.zone = zones.get(zoneId)!;
          }
        }
      }
    }
    const group = groups.get(uid) ?? [];
    group.push(component);
    groups.set(uid, group);
  }
  const out = new Map<string, Map<string, Component>>();
  for (const [uid, components] of groups) {
    const revisions = new Map<string, Component>();
    for (const component of components) {
      const recurrence = component.getFirstPropertyValue('recurrence-id') as IcalTime | null;
      const slot = recurrence ? identity(recurrence, zone) : '';
      const previous = revisions.get(slot);
      const [seq, stamp] = rank(component, zone);
      const [oldSeq, oldStamp] = previous ? rank(previous, zone) : [-1, -1];
      if (!previous || seq > oldSeq || seq === oldSeq && stamp > oldStamp) revisions.set(slot, component);
      else if (seq === oldSeq && stamp === oldStamp) requireValid(component.toString() === previous.toString(), 'Conflicting ICS revisions');
    }
    out.set(uid, revisions);
  }
  return out;
}

/** DTSTART plus the RRULEs of a master that recurs (RRULE or RDATE); undefined otherwise. */
function seriesSignature(master: Component | undefined): string | undefined {
  return master && new ICAL.Event(master, { exceptions: [] }).isRecurring()
    ? JSON.stringify([master.getFirstProperty('dtstart')?.toICALString(), ...master.getAllProperties('rrule').map(p => p.toICALString()).sort()]) : undefined;
}

/**
 * The `seriesSignature` of every UID whose master (with DTSTART) recurs, read from the master
 * itself, so it does not depend on which slots fall inside an expansion window.
 */
export function seriesSignatures(text: string, zone: string = FALLBACK_TIMEZONE): Map<string, string> {
  requireValid(isValidTimeZone(zone), `Unknown time zone: ${zone}`);
  const out = new Map<string, string>();
  for (const [uid, revisions] of readRevisions(text, zone)) {
    const master = revisions.get('');
    const signature = master?.hasProperty('dtstart') ? seriesSignature(master) : undefined;
    if (signature !== undefined) out.set(uid, signature);
  }
  return out;
}

/**
 * Expand RFC recurrence slots, applying exceptions independently of feed order.
 * `zone` is the IANA zone floating times are read in (the source's timezone).
 */
export function parseIcs(
  text: string,
  window: ParseWindow = { from: -Infinity, to: Date.now() + 90 * 86400000 },
  zone: string = FALLBACK_TIMEZONE,
): ParsedEvent[] {
  requireValid(isValidTimeZone(zone), `Unknown time zone: ${zone}`);
  requireValid(window.from < window.to && Number.isFinite(window.to), 'Invalid ICS expansion window');
  const output = new Map<string, ParsedEvent>();
  let iterations = 0;
  for (const [uid, revisions] of readRevisions(text, zone)) {
    const master = revisions.get('');
    const exceptions = [...revisions].filter(([slot]) => slot !== '').map(([, c]) => c);
    const signature = seriesSignature(master);
    const emit = (item: InstanceType<typeof ICAL.Event>, start: IcalTime, end: IcalTime, recurrence?: IcalTime, excluded = false) => {
      const cancelled = excluded || String(item.component.getFirstPropertyValue('status')).toUpperCase() === 'CANCELLED';
      const startIso = iso(start, zone);
      const stamp = start.isDate ? instantOf(startIso, 0, zone) : Date.parse(startIso);
      requireValid(Number.isFinite(stamp) && (end.isDate === start.isDate) && Date.parse(iso(end, zone)) >= Date.parse(startIso), 'Invalid ICS event interval');
      // Cancellation must reach existing mappings even outside the rolling window.
      const occurrenceId = recurrence ? identity(recurrence, zone) : '';
      if (!cancelled && (stamp < window.from || stamp >= window.to) && !window.includeIdentities?.has(JSON.stringify([uid, occurrenceId]))) return;
      const [sequence] = rank(item.component, zone);
      const dtstamp = item.component.getFirstPropertyValue('dtstamp') as IcalTime | null;
      const lastModified = item.component.getFirstPropertyValue('last-modified') as IcalTime | null;
      const categories = item.component.getAllProperties('categories').flatMap(p => p.getValues()).map(String).filter(Boolean);
      const priority = Number(item.component.getFirstPropertyValue('priority'));
      const ev: ParsedEvent = { uid, occurrenceId, summary: item.summary || '', start: startIso, end: iso(end, zone), allDay: start.isDate, cancelled, sequence, seriesSignature: signature };
      if (item.description) ev.description = item.description;
      if (item.location) ev.location = item.location;
      const tzid = start.isDate ? undefined : start.zone.tzid;
      if (tzid && tzid !== 'floating' && tzid !== 'UTC') ev.tzid = tzid;
      if (dtstamp) ev.dtstamp = iso(dtstamp, zone);
      if (lastModified) ev.lastModified = iso(lastModified, zone);
      if (categories.length) ev.categories = categories;
      if (item.summary?.toLowerCase().includes('important') || priority >= 1 && priority <= 4) ev.priorityHigh = true;
      output.set(JSON.stringify([uid, ev.occurrenceId]), ev);
      requireValid(output.size <= MAX_OCCURRENCES, 'ICS occurrence cap exceeded');
    };
    for (const component of revisions.values()) {
      if (!component.hasProperty('dtstart')) {
        requireValid(String(component.getFirstPropertyValue('status')).toUpperCase() === 'CANCELLED', 'Missing ICS DTSTART');
        const recurrence = component.getFirstPropertyValue('recurrence-id') as IcalTime | null;
        // A bare cancelled master targets all previously mapped slots of its UID.
        if (!recurrence) {
          const [sequence] = rank(component, zone);
          const dtstamp = component.getFirstPropertyValue('dtstamp') as IcalTime | null;
          output.set(JSON.stringify([uid, '']), { uid, occurrenceId: '', summary: '', start: '1970-01-01', allDay: true, cancelled: true, sequence, dtstamp: dtstamp ? iso(dtstamp, zone) : undefined });
          continue;
        }
        component.addPropertyWithValue('dtstart', recurrence.clone());
      }
      requireValid(!(component.hasProperty('dtend') && component.hasProperty('duration')), 'ICS event has both DTEND and DURATION');
    }
    if (master?.hasProperty('dtstart')) {
      const item = new ICAL.Event(master, { exceptions, strictExceptions: true });
      if (item.isRecurring()) {
        const iterator = item.iterator();
        for (let occurrence; (occurrence = iterator.next());) {
          requireValid(++iterations <= MAX_ITERATIONS, 'ICS expansion budget exceeded');
          const detail = item.getOccurrenceDetails(occurrence);
          // RANGE shifts may move a later original occurrence into the window.
          if (Date.parse(iso(occurrence, zone)) >= window.to && Date.parse(iso(detail.startDate, zone)) >= window.to) break;
          emit(detail.item, detail.startDate, detail.endDate, occurrence);
        }
      } else emit(item, item.startDate, item.endDate);
    }
    for (const component of exceptions) {
      const item = new ICAL.Event(component);
      emit(item, item.startDate, item.endDate, item.recurrenceId);
    }
    if (master?.hasProperty('dtstart')) {
      const item = new ICAL.Event(master, { exceptions: [] });
      for (const property of master.getAllProperties('exdate')) {
        for (const value of property.getValues()) {
          requireValid(value instanceof ICAL.Time, 'Invalid EXDATE');
          const end = value.clone();
          end.addDuration(item.duration);
          emit(item, value, end, value, true);
        }
      }
    }
  }
  requireValid(output.size <= MAX_OCCURRENCES, 'ICS occurrence cap exceeded');
  return [...output.values()];
}


const FIFTEEN_MINUTES_BEFORE = 'TRIGGER:-PT15M';

/**
 * Map a ParsedEvent to the fields ICS writes onto a DayDo task.
 *
 * - The title is the summary as is; DayDo lists already show the time.
 * - All-day: `endDay` is the inclusive last day (DTEND is exclusive) and is
 *   dropped when it equals the start day.
 * - Timed: wall clock in the event's TZID, or in `timeZone` (the source zone)
 *   for UTC and floating times.
 * - Categories are not turned into tags and no repeat rule is set; recurring
 *   events are already expanded into separate tasks.
 */
export function eventToTaskDraft(ev: ParsedEvent, timeZone: string = FALLBACK_TIMEZONE): TaskDraft {
  const parts: string[] = [];
  if (ev.description) parts.push(ev.description);
  if (ev.location) parts.push(`📍 ${ev.location}`);

  const zone = ev.tzid && isValidTimeZone(ev.tzid) ? ev.tzid : timeZone;
  const schedule = scheduleFromAPI(
    ev.allDay
      ? { start: ev.start, due: ev.end ? addDays(ev.end, -1) : ev.start, allDay: true }
      : { start: ev.start, due: ev.end ?? null, allDay: false, timeZone: zone },
    { defaultTimeZone: timeZone },
  );

  return {
    title: ev.summary,
    content: parts.join('\n\n'),
    // start is always set, so scheduleFromAPI never returns null here.
    schedule: schedule!,
    priority: ev.priorityHigh ? 5 : 0,
    reminders: ev.allDay ? [] : [FIFTEEN_MINUTES_BEFORE],
  };
}
