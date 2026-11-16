/** Writes one structured JSON log line for worker events (never log secrets, codes, or task text). */
export function logEvent(level: 'log' | 'warn' | 'error', event: string, fields: Record<string, unknown> = {}): void {
  console[level](JSON.stringify({ event, ...fields }));
}
