// Shared MCP tool building blocks: tool and context types, argument readers, the
// invalid-params error. Tools import this, not the registry, so the registry can import tools.

import { systemNow, type GetNow } from '../clock';
import type { FetchIcsOptions } from '../ics/fetch';
import type { IcsStore } from '../ics/store';
import type { ServerHlcClock } from '../sync/hlc';
import type { AppDb } from '../sync/push';
import type { ScopeStub } from '../scope/api';

export interface ToolSchema {
  type: 'object';
  properties: Record<
    string,
    { type?: string; description?: string; enum?: readonly string[]; items?: { type: string } }
  >;
  required?: readonly string[];
}

/** Per-request handles a tool needs to read and write the caller's data (built by the route). */
export interface ToolServices {
  db: AppDb;
  getScopeStub: (scope: string) => ScopeStub;
  storage?: R2Bucket | null;
  /** `DEFAULT_TIMEZONE`, tried first when inferring a task's zone from an offset. Defaults to Asia/Taipei. */
  defaultTimeZone?: string;
  /** ICS tool overrides. Production leaves it unset: D1 store, real fetch, shared clock. */
  ics?: { store?: IcsStore; fetchOptions?: FetchIcsOptions; clock?: ServerHlcClock };
  /** Business time source. Production leaves it unset: the system clock. */
  getNow?: GetNow;
}

/** Business "now" for a tool call: one clock read per call. */
export function nowOf(ctx: ToolContext): number {
  return (ctx.services?.getNow ?? systemNow)();
}

export interface ToolContext {
  userId: string;
  clientId: string | null;
  services?: ToolServices;
}

export type ToolContent =
  | { type: 'text'; text: string }
  | { type: 'image'; data: string; mimeType: string };

export interface ToolResult {
  content: ToolContent[];
  isError?: boolean;
}

const mcpResults = new WeakSet<object>();

/** Marks a pre-built MCP content array so handleToolCall returns it directly without JSON-wrapping. */
export function mcpResult(content: ToolContent[]): ToolResult {
  const result: ToolResult = { content };
  mcpResults.add(result);
  return result;
}

export function isMcpResult(value: unknown): value is ToolResult {
  return typeof value === 'object' && value !== null && mcpResults.has(value);
}

export interface ToolDef {
  name: string;
  description: string;
  inputSchema: ToolSchema;
  run: (args: Record<string, unknown>, ctx: ToolContext) => Promise<unknown>;
}

/** Invalid-params error for a tool call; surfaced to the model as an isError tool result. */
export class ToolValidationError extends Error {
  readonly code = -32602;
  readonly field: string;
  constructor(field: string, message: string) {
    super(message);
    this.name = 'ToolValidationError';
    this.field = field;
  }
}

/** True for undefined, null, or an empty/whitespace-only string. */
export function isEmpty(v: unknown): boolean {
  return v === undefined || v === null || (typeof v === 'string' && v.trim() === '');
}

/** Reads a required string argument instead of coercing undefined to "undefined". */
export function requireStr(args: Record<string, unknown>, field: string): string {
  const v = args[field];
  if (isEmpty(v)) throw new ToolValidationError(field, `Missing required argument '${field}'`);
  return String(v);
}

/** Reads a required integer argument (number or digit string). */
export function requireInt(args: Record<string, unknown>, field: string): number {
  const v = args[field];
  if (isEmpty(v)) throw new ToolValidationError(field, `Missing required argument '${field}'`);
  const ok = (typeof v === 'number' && Number.isInteger(v)) || (typeof v === 'string' && /^\d+$/.test(v.trim()));
  if (!ok) throw new ToolValidationError(field, `Argument '${field}' must be an integer`);
  return Number(v);
}
