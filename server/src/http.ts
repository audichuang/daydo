import type { CloudContext } from 'void';
import { isScopeRelocatingError } from './scope/relocation';
import { SharingError } from './sharing';

export async function readJsonObject(c: CloudContext): Promise<Record<string, unknown> | null> {
  try {
    const value: unknown = await c.req.json();
    if (!value || typeof value !== 'object' || Array.isArray(value)) {
      return null;
    }
    return value as Record<string, unknown>;
  } catch {
    return null;
  }
}

export function nonEmptyString(value: unknown): string | null {
  return typeof value === 'string' && value.length > 0 ? value : null;
}

export async function withScopeRelocating503(
  c: CloudContext,
  run: () => Promise<Response>,
): Promise<Response> {
  try {
    return await run();
  } catch (err) {
    if (isScopeRelocatingError(err)) {
      return c.json({ error: 'Scope is relocating; retry shortly' }, 503);
    }
    throw err;
  }
}

/** Maps a SharingError to its JSON error response; anything else is rethrown. */
export async function withSharingErrors(c: CloudContext, run: () => Promise<Response>): Promise<Response> {
  try {
    return await run();
  } catch (err) {
    if (err instanceof SharingError) {
      return c.json({ error: err.message }, err.status as 400 | 403 | 404);
    }
    throw err;
  }
}
