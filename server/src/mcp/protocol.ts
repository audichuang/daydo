// MCP JSON-RPC handler: protocol 2025-06-18 over Streamable HTTP, pure JSON subset
// (no SSE, no session). Auth is enforced upstream (auth.ts); this only dispatches.
import pkg from '../../package.json' with { type: 'json' };
import { logCall, type CallMeta } from './log';
import { handleToolCall, TOOL_DEFS, type ToolContext, type ToolDescriptor, type ToolResult } from './registry';

export const PROTOCOL_VERSION = '2025-06-18';
export const SERVER_INFO = { name: 'daydo', version: pkg.version };

type RpcId = string | number | null;

interface JsonRpcRequest {
  jsonrpc: '2.0';
  id?: RpcId;
  method: string;
  params?: unknown;
}

interface JsonRpcResponse {
  jsonrpc: '2.0';
  id: RpcId;
  result?: unknown;
  error?: { code: number; message: string };
}

/** Injection points for tests; production uses the registry. */
export interface ProtocolDeps {
  defs: ToolDescriptor[];
  call: (name: string, args: Record<string, unknown>, ctx: ToolContext) => Promise<ToolResult>;
}

const defaultDeps: ProtocolDeps = { defs: TOOL_DEFS, call: (n, a, c) => handleToolCall(n, a, c) };

export async function handleMcpPost(
  request: Request,
  ctx: ToolContext,
  ray: string | null = null,
  deps: ProtocolDeps = defaultDeps,
): Promise<Response> {
  let parsed: unknown;
  try {
    parsed = await request.json();
  } catch {
    return Response.json(rpcError(null, -32700, 'Parse error'), { status: 400 });
  }
  if (!isJsonRpcRequest(parsed)) {
    return Response.json(rpcError(extractId(parsed), -32600, 'Invalid Request'), { status: 400 });
  }
  const started = Date.now();
  const response = await dispatch(parsed, ctx, deps);
  const meta: CallMeta = { clientId: ctx.clientId, userId: ctx.userId, ray };
  logCall(parsed, response, Date.now() - started, meta);
  if (!response) return new Response(null, { status: 202 });
  return Response.json(response);
}

async function dispatch(req: JsonRpcRequest, ctx: ToolContext, deps: ProtocolDeps): Promise<JsonRpcResponse | null> {
  const isNotification = req.id === undefined || req.id === null;
  const id = req.id ?? null;
  try {
    switch (req.method) {
      case 'initialize':
        return ok(id, { protocolVersion: PROTOCOL_VERSION, capabilities: { tools: {} }, serverInfo: SERVER_INFO });
      case 'notifications/initialized':
      case 'notifications/cancelled':
        return null;
      case 'ping':
        return ok(id, {});
      case 'tools/list':
        return ok(id, { tools: deps.defs });
      case 'tools/call': {
        const params = (req.params ?? {}) as { name?: string; arguments?: Record<string, unknown> };
        if (!params.name) return rpcError(id, -32602, 'Missing tool name');
        return ok(id, await deps.call(params.name, params.arguments ?? {}, ctx));
      }
      default:
        if (isNotification) return null;
        return rpcError(id, -32601, `Method not found: ${req.method}`);
    }
  } catch (e) {
    if (isNotification) return null;
    return rpcError(id, -32603, `Internal error: ${e instanceof Error ? e.message : String(e)}`);
  }
}

function isJsonRpcRequest(value: unknown): value is JsonRpcRequest {
  return (
    typeof value === 'object' &&
    value !== null &&
    !Array.isArray(value) &&
    typeof (value as { method?: unknown }).method === 'string'
  );
}

function extractId(value: unknown): RpcId {
  if (typeof value === 'object' && value !== null && !Array.isArray(value)) {
    const id = (value as { id?: unknown }).id;
    if (typeof id === 'string' || typeof id === 'number') return id;
  }
  return null;
}

function ok(id: RpcId, result: unknown): JsonRpcResponse {
  return { jsonrpc: '2.0', id, result };
}

function rpcError(id: RpcId, code: number, message: string): JsonRpcResponse {
  return { jsonrpc: '2.0', id, error: { code, message } };
}
