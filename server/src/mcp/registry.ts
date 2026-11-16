// MCP tool registry: definitions, behaviour hints, argument validation (spec/mcp.md 5, 8).

import { icsTools } from './tools/ics';
import { projectTools } from './tools/projects';
import { tagTools } from './tools/tags';
import { taskReadTools, taskWriteTools } from './tools/tasks';
import { isEmpty, ToolValidationError, type ToolContext, type ToolDef, type ToolSchema } from './toolkit';

export type Hint = 'read' | 'write' | 'idempotent-write' | 'idempotent-overwrite' | 'destructive';

/** Behaviour hints in one table so a new tool cannot ship without them. Hints are not a security boundary. */
export const HINTS: Record<string, Hint> = {
  list_projects: 'read',
  get_project: 'read',
  get_project_data: 'read',
  create_project: 'write',
  update_project: 'idempotent-overwrite',
  delete_project: 'destructive',
  list_tags: 'read',
  create_tag: 'write',
  list_recent_tasks: 'read',
  list_tasks: 'read',
  search_tasks: 'read',
  get_task: 'read',
  get_completed_tasks: 'read',
  create_task: 'write',
  update_task: 'idempotent-overwrite',
  complete_task: 'idempotent-write',
  delete_task: 'destructive',
  move_task: 'idempotent-write',
  move_all: 'idempotent-write',
  add_ics_source: 'write',
  list_ics_sources: 'read',
  remove_ics_source: 'destructive',
  sync_ics_now: 'destructive',
  get_ics_sync_status: 'read',
};

/** Only tools that fetch caller-supplied external URLs. */
export const OPEN_WORLD = new Set<string>(['add_ics_source', 'sync_ics_now']);

export const TOOLS: readonly ToolDef[] = [...projectTools(), ...tagTools(), ...taskReadTools(), ...taskWriteTools(), ...icsTools()];

export interface ToolDescriptor {
  name: string;
  description: string;
  inputSchema: ToolSchema;
  annotations: {
    readOnlyHint: boolean;
    destructiveHint?: boolean;
    idempotentHint?: boolean;
    openWorldHint: boolean;
  };
}

export function annotationsFor(name: string, hints: Record<string, Hint>, openWorld: ReadonlySet<string>) {
  const hint = hints[name];
  if (!hint) throw new Error(`Tool '${name}' has no HINTS entry`);
  return {
    readOnlyHint: hint === 'read',
    ...(hint !== 'read' && { destructiveHint: hint === 'destructive' || hint === 'idempotent-overwrite' }),
    ...(hint !== 'read' && {
      idempotentHint: hint === 'idempotent-write' || hint === 'idempotent-overwrite' || hint === 'destructive',
    }),
    openWorldHint: openWorld.has(name),
  };
}

export function describeTools(
  tools: readonly ToolDef[],
  hints: Record<string, Hint> = HINTS,
  openWorld: ReadonlySet<string> = OPEN_WORLD,
): ToolDescriptor[] {
  return tools.map((t) => ({
    name: t.name,
    description: t.description,
    inputSchema: t.inputSchema,
    annotations: annotationsFor(t.name, hints, openWorld),
  }));
}

export const TOOL_DEFS: ToolDescriptor[] = describeTools(TOOLS);

/**
 * Rejects calls whose arguments do not match the schema, before dispatch:
 * required fields present, no undeclared fields (they would be dropped silently),
 * enum fields carry one of their values.
 */
export function validateArgs(
  name: string,
  schema: ToolSchema | undefined,
  args: Record<string, unknown>,
): void {
  for (const field of schema?.required ?? []) {
    if (isEmpty(args[field])) {
      throw new ToolValidationError(field, `Missing required argument '${field}' for tool '${name}'`);
    }
  }
  const props = schema?.properties;
  if (!props) return;
  const accepted = Object.keys(props);
  for (const key of Object.keys(args)) {
    if (!Object.hasOwn(props, key)) {
      throw new ToolValidationError(
        key,
        `Unknown argument '${key}' for tool '${name}'; it would be dropped silently. Accepted arguments: ${accepted.join(', ')}`,
      );
    }
    const allowed = props[key]?.enum;
    if (allowed && !isEmpty(args[key]) && !allowed.includes(args[key] as string)) {
      throw new ToolValidationError(
        key,
        `Invalid value ${JSON.stringify(args[key])} for '${key}'; accepted: ${allowed.join(' | ')}`,
      );
    }
  }
}

export interface ToolResult {
  content: { type: 'text'; text: string }[];
  isError?: boolean;
}

/** Validates, runs and wraps a tool call; tool-level failures become isError results. */
export async function handleToolCall(
  name: string,
  args: Record<string, unknown>,
  ctx: ToolContext,
  tools: readonly ToolDef[] = TOOLS,
): Promise<ToolResult> {
  try {
    const def = tools.find((t) => t.name === name);
    if (!def) throw new Error(`Unknown tool '${name}'`);
    validateArgs(name, def.inputSchema, args);
    const result = await def.run(args, ctx);
    return { content: [{ type: 'text', text: typeof result === 'string' ? result : JSON.stringify(result) }] };
  } catch (e) {
    return { content: [{ type: 'text', text: `Error: ${e instanceof Error ? e.message : String(e)}` }], isError: true };
  }
}
