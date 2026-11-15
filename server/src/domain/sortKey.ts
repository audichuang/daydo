// Port of DayDoCore SortKey.swift: fractional-index keys over base36.

const DIGITS = '0123456789abcdefghijklmnopqrstuvwxyz';
const BASE = DIGITS.length;

function value(c: string): number {
  const v = DIGITS.indexOf(c);
  if (v < 0) throw new Error(`Invalid sort key character: ${c}`);
  return v;
}

/** A key between `a` and `b` (null = open end). Throws when a >= b. */
export function between(a: string | null, b: string | null): string {
  const lo = a ?? '';
  if (b !== null && !(lo < b)) throw new Error('SortKey.between requires a < b');
  let result = '';
  let i = 0;
  for (;;) {
    const l = i < lo.length ? value(lo[i]!) : 0;
    const h = b !== null && i < b.length ? value(b[i]!) : BASE;
    if (h - l > 1) {
      return result + DIGITS[Math.floor((l + h) / 2)];
    }
    // Gap too small at this digit: keep lo's digit and go deeper.
    result += DIGITS[l];
    if (b !== null && i < b.length && h > l) {
      // From here on the upper bound is open.
      return result + between(lo.slice(i + 1), null);
    }
    i += 1;
  }
}

export function after(a: string | null): string {
  return between(a, null);
}

export function before(b: string | null): string {
  return between(null, b);
}

/** Keys the server generates never end in '0'; used only for generated keys. */
export function isGeneratedKeyValid(key: string): boolean {
  return /^[0-9a-z]*[1-9a-z]$/.test(key);
}

/** Unique project key: after(max) plus 2 random base36 chars, last char never '0'. */
export function uniqueProjectKey(
  max: string | null,
  random: () => number = Math.random,
): string {
  const pick = (from: string) => from[Math.floor(random() * from.length)]!;
  return after(max) + pick(DIGITS) + pick(DIGITS.slice(1));
}
