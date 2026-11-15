export const MAX_FUTURE_DRIFT_MS = 5 * 60 * 1000;
export const SERVER_HLC_DEVICE_ID = 'server';

export interface Hlc {
  ms: number;
  counter: number;
  deviceId: string;
}

const MS_PART_RE = /^\d{13}$/;
const COUNTER_PART_RE = /^\d{4}$/;

/** Normalize an HLC by folding counter overflows into ms and lowercasing deviceId. */
export function normalizeHlc(hlc: Hlc): Hlc {
  let ms = Number.isFinite(hlc.ms) ? Math.max(0, Math.floor(hlc.ms)) : 0;
  let counter = Number.isFinite(hlc.counter) ? Math.max(0, Math.floor(hlc.counter)) : 0;
  if (counter > 9999) {
    ms += Math.floor(counter / 10000);
    counter %= 10000;
  }
  return {
    ms,
    counter,
    deviceId: hlc.deviceId.toLowerCase(),
  };
}

/** Parse `<13-digit ms>:<4-digit counter>:<deviceId>` per spec/sync.md. */
export function parseHlc(raw: string): Hlc | null {
  if (typeof raw !== 'string') return null;
  const firstColon = raw.indexOf(':');
  if (firstColon === -1) return null;
  const secondColon = raw.indexOf(':', firstColon + 1);
  if (secondColon === -1) return null;

  const msPart = raw.slice(0, firstColon);
  const counterPart = raw.slice(firstColon + 1, secondColon);
  const deviceIdPart = raw.slice(secondColon + 1);

  if (!MS_PART_RE.test(msPart) || !COUNTER_PART_RE.test(counterPart)) {
    return null;
  }
  if (deviceIdPart.length === 0 || /\s/.test(deviceIdPart)) {
    return null;
  }

  return {
    ms: Number(msPart),
    counter: Number(counterPart),
    deviceId: deviceIdPart.toLowerCase(),
  };
}

/** Format an HLC to fixed-width `<13 digits>:<4 digits>:<lowercase deviceId>`. */
export function formatHlc(hlc: Hlc): string {
  const norm = normalizeHlc(hlc);
  if (norm.ms > 9_999_999_999_999) {
    throw new RangeError(`HLC ms exceeds 13-digit maximum: ${norm.ms}`);
  }
  const msStr = String(norm.ms).padStart(13, '0');
  const counterStr = String(norm.counter).padStart(4, '0');
  return `${msStr}:${counterStr}:${norm.deviceId}`;
}

function toFormatted(value: Hlc | string): string {
  if (typeof value === 'string') {
    const parsed = parseHlc(value);
    if (!parsed) {
      throw new Error(`Invalid HLC string: ${value}`);
    }
    return formatHlc(parsed);
  }
  return formatHlc(value);
}

/** Compare two HLCs causally; returns -1, 0, or 1. */
export function compareHlc(a: Hlc | string, b: Hlc | string): -1 | 0 | 1 {
  const fa = toFormatted(a);
  const fb = toFormatted(b);
  if (fa < fb) return -1;
  if (fa > fb) return 1;
  return 0;
}

/**
 * Clamp an op HLC that is more than 5 minutes ahead of server time.
 * Optional `lastClamped` keeps clamped HLCs monotonic within the same millisecond.
 */
export function clampHlc(
  hlc: Hlc | string,
  serverNowMs: number,
  lastClamped?: Hlc | null,
): { hlc: Hlc; formatted: string; clamped: boolean } {
  const parsed = typeof hlc === 'string' ? parseHlc(hlc) : normalizeHlc(hlc);
  if (!parsed) {
    throw new Error(`Invalid HLC: ${String(hlc)}`);
  }

  const now = Math.max(0, Math.floor(serverNowMs));
  if (parsed.ms <= now + MAX_FUTURE_DRIFT_MS) {
    return {
      hlc: parsed,
      formatted: formatHlc(parsed),
      clamped: false,
    };
  }

  const next =
    lastClamped && now <= lastClamped.ms
      ? normalizeHlc({
          ms: lastClamped.ms,
          counter: lastClamped.counter + 1,
          deviceId: parsed.deviceId,
        })
      : normalizeHlc({
          ms: now,
          counter: 0,
          deviceId: parsed.deviceId,
        });

  return {
    hlc: next,
    formatted: formatHlc(next),
    clamped: true,
  };
}

/**
 * Advance the server HLC so it is strictly past `last` (if provided) and strictly
 * past every HLC in `observed` (hence `>=` every HLC assigned or clamped in a batch).
 */
export function advanceServerHlc(
  nowMs: number,
  observed: ReadonlyArray<Hlc | string> = [],
  last?: Hlc | string | null,
): { hlc: Hlc; formatted: string } {
  const wall = Number.isFinite(nowMs) ? Math.max(0, Math.floor(nowMs)) : 0;

  let candidate: Hlc = { ms: wall, counter: 0, deviceId: SERVER_HLC_DEVICE_ID };
  if (last) {
    const lastHlc = typeof last === 'string' ? parseHlc(last) : normalizeHlc(last);
    if (lastHlc) {
      if (wall > lastHlc.ms) {
        candidate = { ms: wall, counter: 0, deviceId: SERVER_HLC_DEVICE_ID };
      } else {
        candidate = normalizeHlc({
          ms: lastHlc.ms,
          counter: lastHlc.counter + 1,
          deviceId: SERVER_HLC_DEVICE_ID,
        });
      }
    }
  }

  for (const item of observed) {
    const obs = typeof item === 'string' ? parseHlc(item) : normalizeHlc(item);
    if (!obs) continue;
    if (compareHlc(candidate, obs) <= 0) {
      candidate = normalizeHlc({
        ms: obs.ms,
        counter: obs.counter + 1,
        deviceId: SERVER_HLC_DEVICE_ID,
      });
    }
  }

  return {
    hlc: candidate,
    formatted: formatHlc(candidate),
  };
}

export interface ServerHlcClock {
  tick(nowMs: number, observed?: ReadonlyArray<Hlc | string>): string;
  current(): Hlc | null;
}

/** Stateful monotonic server HLC clock for a worker isolate or test harness. */
export function createServerHlcClock(): ServerHlcClock {
  let last: Hlc | null = null;
  return {
    tick(nowMs: number, observed: ReadonlyArray<Hlc | string> = []): string {
      const next = advanceServerHlc(nowMs, observed, last);
      last = next.hlc;
      return next.formatted;
    },
    current() {
      return last;
    },
  };
}
