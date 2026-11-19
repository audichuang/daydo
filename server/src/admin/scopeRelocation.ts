import { nonEmptyString } from '../http';
import type { ScopeExportedRow, ScopeRelocationStub, ScopeTableDigest } from '../scope/api';
import {
  RELOCATION_BAD_REQUEST_PREFIX,
  RELOCATION_CONFLICT_PREFIX,
} from '../scope/relocation';

const encoder = new TextEncoder();

async function constantTimeEqual(a: string, b: string): Promise<boolean> {
  const [ha, hb] = await Promise.all([
    crypto.subtle.digest('SHA-256', encoder.encode(a)),
    crypto.subtle.digest('SHA-256', encoder.encode(b)),
  ]);
  const ba = new Uint8Array(ha);
  const bb = new Uint8Array(hb);
  let diff = 0;
  for (let i = 0; i < ba.length; i += 1) {
    diff |= ba[i] ^ bb[i];
  }
  return diff === 0;
}

function extractBearerToken(header: string | undefined): string | null {
  if (!header || !header.startsWith('Bearer ')) return null;
  const token = header.slice('Bearer '.length);
  return token.length > 0 ? token : null;
}

export interface ScopeRelocationAdminResult {
  status: 200 | 400 | 404 | 409;
  body: Record<string, unknown>;
}

export interface ScopeRelocationAdminParams {
  adminToken: string | undefined;
  authorizationHeader: string | undefined;
  readBody: () => Promise<Record<string, unknown> | null>;
  getPhysicalScopeStub: (physical: string) => ScopeRelocationStub;
  resolveScopePhysical: (logical: string) => string | undefined;
}

function stripPrefixedMessage(message: string, prefix: string): string | null {
  const idx = message.indexOf(prefix);
  if (idx === -1) return null;
  return message.slice(idx + prefix.length);
}

export async function handleScopeRelocationAdmin(
  params: ScopeRelocationAdminParams,
): Promise<ScopeRelocationAdminResult> {
  const expected = nonEmptyString(params.adminToken);
  const provided = extractBearerToken(params.authorizationHeader);
  if (!expected || !provided || !(await constantTimeEqual(provided, expected))) {
    return { status: 404, body: { error: 'Not found' } };
  }

  const body = await params.readBody();
  if (!body) {
    return { status: 400, body: { error: 'Invalid JSON body' } };
  }

  const action = nonEmptyString(body.action);
  const physical = nonEmptyString(body.physical);
  if (!action || !physical) {
    return { status: 400, body: { error: 'action and physical are required' } };
  }

  const stub = params.getPhysicalScopeStub(physical);

  try {
    switch (action) {
      case 'status':
        return { status: 200, body: { ...(await stub.relocationStatus()) } };
      case 'freeze':
        return {
          status: 200,
          body: { ...(await stub.setRelocationState({ state: 'frozen', expect: 'live' })) },
        };
      case 'unfreeze':
        return {
          status: 200,
          body: { ...(await stub.setRelocationState({ state: 'live', expect: 'frozen' })) },
        };
      case 'begin-import':
        return {
          status: 200,
          body: { ...(await stub.setRelocationState({ state: 'importing', expect: 'live' })) },
        };
      case 'finish-import': {
        if (!body.expectDigest || typeof body.expectDigest !== 'object' || Array.isArray(body.expectDigest)) {
          return { status: 400, body: { error: 'expectDigest is required for finish-import' } };
        }
        return {
          status: 200,
          body: {
            ...(await stub.setRelocationState({
              state: 'live',
              expect: 'importing',
              expectDigest: body.expectDigest as Record<string, ScopeTableDigest>,
            })),
          },
        };
      }
      case 'export': {
        const table = nonEmptyString(body.table);
        if (!table) {
          return { status: 400, body: { error: 'table is required for export' } };
        }
        const afterRowid = body.afterRowid === undefined ? 0 : body.afterRowid;
        if (
          typeof afterRowid !== 'number' ||
          !Number.isSafeInteger(afterRowid) ||
          afterRowid < 0
        ) {
          return { status: 400, body: { error: 'afterRowid must be a non-negative integer' } };
        }
        let maxChars: number | undefined;
        if (body.maxChars !== undefined) {
          if (
            typeof body.maxChars !== 'number' ||
            !Number.isSafeInteger(body.maxChars) ||
            body.maxChars < 1
          ) {
            return { status: 400, body: { error: 'maxChars must be a positive integer' } };
          }
          maxChars = body.maxChars;
        }
        return {
          status: 200,
          body: { ...(await stub.exportPage({ table, afterRowid, maxChars })) },
        };
      }
      case 'import': {
        const table = nonEmptyString(body.table);
        if (!table) {
          return { status: 400, body: { error: 'table is required for import' } };
        }
        if (!Array.isArray(body.rows)) {
          return { status: 400, body: { error: 'rows must be an array for import' } };
        }
        return {
          status: 200,
          body: {
            ...(await stub.importPage({
              table,
              rows: body.rows as ScopeExportedRow[],
            })),
          },
        };
      }
      case 'digest':
        return { status: 200, body: { ...(await stub.digest()) } };
      case 'purge-frozen': {
        const expectMaxServerSeq = body.expectMaxServerSeq;
        if (typeof expectMaxServerSeq !== 'number' || !Number.isSafeInteger(expectMaxServerSeq) || expectMaxServerSeq < 0) {
          return { status: 400, body: { error: 'expectMaxServerSeq must be a non-negative integer for purge-frozen' } };
        }
        // `physical` is the old DO, named after the logical scope it served. Purge only once that
        // scope is routed elsewhere and the copy there is live and at least as far along.
        const target = params.resolveScopePhysical(physical);
        if (!target || target === physical) {
          return { status: 409, body: { error: `'${physical}' is not routed to another physical DO; refusing to purge` } };
        }
        const targetStatus = await params.getPhysicalScopeStub(target).relocationStatus();
        if (targetStatus.state !== 'live' || targetStatus.maxServerSeq < expectMaxServerSeq) {
          return {
            status: 409,
            body: { error: `Target '${target}' is not a live copy at or beyond seq ${expectMaxServerSeq} (state ${targetStatus.state}, seq ${targetStatus.maxServerSeq})` },
          };
        }
        // The target must be a copy of this source: the source's op log (append-only, rowids kept by
        // the copy) must equal the target's log up to the same rowid. Another account's DO fails this.
        const sourceLog = await stub.opLogDigest({});
        if (sourceLog.count === 0) {
          return { status: 409, body: { error: `'${physical}' has an empty op log; nothing proves '${target}' is its copy` } };
        }
        const targetLog = await params.getPhysicalScopeStub(target).opLogDigest({ maxRowid: sourceLog.maxRowid });
        if (targetLog.count !== sourceLog.count || targetLog.sha256 !== sourceLog.sha256) {
          return { status: 409, body: { error: `'${target}' does not contain '${physical}' op log; refusing to purge` } };
        }
        return { status: 200, body: { ...(await stub.purgeFrozenData({ expectMaxServerSeq })) } };
      }
      default:
        return { status: 400, body: { error: `Unknown action '${action}'` } };
    }
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    const conflict = stripPrefixedMessage(message, RELOCATION_CONFLICT_PREFIX);
    if (conflict !== null) {
      return { status: 409, body: { error: conflict } };
    }
    const badReq = stripPrefixedMessage(message, RELOCATION_BAD_REQUEST_PREFIX);
    if (badReq !== null) {
      return { status: 400, body: { error: badReq } };
    }
    throw err;
  }
}
