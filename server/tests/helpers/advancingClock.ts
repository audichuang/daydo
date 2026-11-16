import { vi } from 'vitest';

/**
 * Makes every Date.now() call return a different, increasing value. A write that is meant to
 * carry the caller's `now` then differs from one that re-reads the clock later, which a frozen
 * clock cannot tell apart. Call mockRestore() on the result when done.
 */
export function advancingNow(start = Date.now()) {
  let t = start;
  return vi.spyOn(Date, 'now').mockImplementation(() => t++);
}
