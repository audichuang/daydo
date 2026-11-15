// Port of DayDoCore Reminders.swift (trigger parsing and canonical output).

/** Parse a TickTick trigger string into seconds relative to the anchor; null if invalid. */
export function parseReminder(trigger: string): number | null {
  let s = trigger.toUpperCase();
  if (s.startsWith('TRIGGER:')) s = s.slice(8);
  let sign = 1;
  if (s.startsWith('-')) {
    sign = -1;
    s = s.slice(1);
  } else if (s.startsWith('+')) {
    s = s.slice(1);
  }
  if (!s.startsWith('P')) return null;
  s = s.slice(1);
  let total = 0;
  let number = '';
  let inTime = false;
  for (const ch of s) {
    if (ch === 'T') {
      inTime = true;
      continue;
    }
    if (ch >= '0' && ch <= '9') {
      number += ch;
      continue;
    }
    if (number === '') return null;
    const n = Number(number);
    number = '';
    if (ch === 'W' && !inTime) total += n * 7 * 86400;
    else if (ch === 'D' && !inTime) total += n * 86400;
    else if (ch === 'H' && inTime) total += n * 3600;
    else if (ch === 'M' && inTime) total += n * 60;
    else if (ch === 'S' && inTime) total += n;
    else return null;
  }
  if (number !== '') return null;
  return sign * total;
}

/** Canonical trigger string for an offset in seconds. */
export function formatReminder(offsetSeconds: number): string {
  if (offsetSeconds === 0) return 'TRIGGER:PT0S';
  const sign = offsetSeconds < 0 ? '-' : '';
  let r = Math.abs(offsetSeconds);
  const d = Math.floor(r / 86400);
  r %= 86400;
  const h = Math.floor(r / 3600);
  r %= 3600;
  const m = Math.floor(r / 60);
  const sec = r % 60;
  let out = `TRIGGER:${sign}P`;
  if (d > 0) out += `${d}D`;
  if (h > 0 || m > 0 || sec > 0) {
    out += 'T';
    if (h > 0) out += `${h}H`;
    if (m > 0) out += `${m}M`;
    if (sec > 0) out += `${sec}S`;
  }
  return out;
}

/** Normalize a trigger string to canonical form; throws on invalid input. */
export function canonicalReminder(trigger: string): string {
  const offset = parseReminder(trigger);
  if (offset === null) throw new Error(`Invalid reminder trigger: ${trigger}`);
  return formatReminder(offset);
}

/** Comma-separated input (empty items dropped) to canonical triggers. */
export function parseReminderCsv(csv: string): string[] {
  return csv
    .split(',')
    .map((s) => s.trim())
    .filter((s) => s !== '')
    .map(canonicalReminder);
}
