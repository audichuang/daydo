// Structured logs for MCP calls (spec/mcp.md 4.7). Only argument key names are recorded,
// never values, tokens or task text.

export function logEvent(level: 'log' | 'warn' | 'error', event: string, fields: Record<string, unknown> = {}): void {
  console[level](JSON.stringify({ event, ...fields }));
}

export interface CallMeta {
  clientId: string | null;
  userId: string | null;
  ray: string | null;
}

export interface LoggedRequest {
  method: string;
  params?: unknown;
}

export interface LoggedResponse {
  error?: { message: string };
  result?: unknown;
}

/** One `mcp.call` line per meaningful call. Pings and notifications are not logged. */
export function logCall(req: LoggedRequest, response: LoggedResponse | null, ms: number, meta: CallMeta): void {
  if (req.method === 'ping' || req.method.startsWith('notifications/')) return;
  const params = (req.params ?? {}) as { name?: unknown; arguments?: unknown };
  const isToolCall = req.method === 'tools/call';
  const result = response?.result as { isError?: boolean; content?: { text?: string }[] } | undefined;
  const outcome = response?.error ? 'rpc_error' : result?.isError ? 'tool_error' : 'ok';
  logEvent(outcome === 'ok' ? 'log' : 'warn', 'mcp.call', {
    method: req.method,
    ...(isToolCall && {
      tool: typeof params.name === 'string' ? params.name : null,
      arg_keys:
        params.arguments && typeof params.arguments === 'object' ? Object.keys(params.arguments).sort() : [],
    }),
    outcome,
    ms,
    client_id: meta.clientId,
    userId: meta.userId,
    ray: meta.ray,
  });
}
