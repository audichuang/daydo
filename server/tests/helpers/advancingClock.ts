import type { GetNow } from '../../src/clock';

/**
 * A GetNow whose every call returns a different, increasing value. A write that is meant to
 * carry the caller's `now` then differs from one that re-reads the clock later, which a frozen
 * clock cannot tell apart. Inject it as `getNow`; it never touches the global clock.
 */
export function advancingNow(start = Date.now()): GetNow {
  let t = start;
  return () => t++;
}
