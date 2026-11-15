import type { CloudContext } from 'void';

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
