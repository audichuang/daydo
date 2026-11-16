/**
 * ICS sync data-layer types shared by the parser, filters and (later) the engine.
 * Everything handled internally is camelCase. The source and mapping row types
 * live with the store, next to the D1 tables.
 */

import type { Schedule } from '../domain/schedule';

/** Zone used for floating times and for UTC events when a source sets none. */
export const FALLBACK_TIMEZONE = 'Asia/Taipei';

/** Malformed, unsupported or unfetchable ICS input. The message is safe to show the user. */
export class IcsError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'IcsError';
  }
}

/** Per-source filtering rules; stored as JSON on the source. */
export interface IcsFilter {
  futureDays?: number;
  pastDays?: number;
  excludeKeywords?: string[];
}

/** A single VEVENT (or one expanded occurrence) parsed out of an ICS feed. */
export interface ParsedEvent {
  uid: string;
  occurrenceId?: string;
  cancelled?: boolean;
  sequence?: number;
  dtstamp?: string;
  seriesSignature?: string;
  summary: string;
  description?: string;
  location?: string;
  /** `YYYY-MM-DD` for all-day, otherwise ISO local time with a `+hhmm` offset. */
  start: string;
  /** All-day: exclusive end date (RFC 5545 DTEND). */
  end?: string;
  allDay: boolean;
  /** IANA TZID of the DTSTART when it named one; absent for UTC and floating times. */
  tzid?: string;
  lastModified?: string;
  categories?: string[];
  priorityHigh?: boolean;
}

/** What the engine writes for an event. Only the fields ICS owns plus the create-only defaults. */
export interface TaskDraft {
  title: string;
  /** Empty string when the event has neither description nor location. */
  content: string;
  schedule: Schedule;
  /** 5 for high, otherwise 0. Applied on create only. */
  priority: 0 | 5;
  /** Applied on create only. Timed events get `TRIGGER:-PT15M`. */
  reminders: string[];
}

/** Outcome counters for a single sync run. */
export interface SyncStats {
  created: number;
  updated: number;
  skipped: number;
  deleted: number;
  errors: number;
  /** Another run owns the source. No writes were attempted. */
  busy?: boolean;
  missing?: number;
  dryRun?: boolean;
  changes?: SyncChange[];
  /** Failure reason when the whole source failed (fetch/parse/setup). */
  lastError?: string;
}

export interface SyncChange {
  uid: string;
  occurrenceId: string;
  taskId?: string;
  action: 'create' | 'update' | 'skip' | 'cancel' | 'delete' | 'missing' | 'error';
  summary?: string;
  start?: string;
  end?: string;
  previousStart?: string;
  previousEnd?: string;
  reason?: string;
}
