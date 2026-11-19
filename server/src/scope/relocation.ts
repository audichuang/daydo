import type {
  ScopeDigest,
  ScopeExportedRow,
  ScopeExportPageInput,
  ScopeExportPageResponse,
  ScopeImportPageInput,
  ScopeImportPageResponse,
  ScopePurgeFrozenInput,
  ScopePurgeFrozenResponse,
  ScopeRelocationState,
  ScopeRelocationStatus,
  ScopeSetRelocationStateInput,
  ScopeSetRelocationStateResponse,
  ScopeTableDigest,
} from './api';
import { MAX_PULL_PAGE_CHARS } from './pull';
import { RELOCATION_PURGED_TABLE, RELOCATION_STATE_TABLE } from './schema';
import { Sha256 } from './sha256';

export const SCOPE_RELOCATING_CODE = 'SCOPE_RELOCATING';
export const RELOCATION_CONFLICT_PREFIX = 'RELOCATION_CONFLICT: ';
export const RELOCATION_BAD_REQUEST_PREFIX = 'RELOCATION_BAD_REQUEST: ';

const ROWID_ALIAS = '__scope_rowid__';
const SQL_BATCH_SIZE = 500;

export class ScopeRelocatingError extends Error {
  readonly state: ScopeRelocationState;

  constructor(state: ScopeRelocationState) {
    super(`${SCOPE_RELOCATING_CODE}: Scope is relocating (state: ${state})`);
    this.name = 'ScopeRelocatingError';
    this.state = state;
  }
}

export function isScopeRelocatingError(error: unknown): boolean {
  if (error instanceof ScopeRelocatingError) return true;
  return error instanceof Error && error.message.includes(SCOPE_RELOCATING_CODE);
}

function conflictError(message: string): Error {
  return new Error(`${RELOCATION_CONFLICT_PREFIX}${message}`);
}

function badRequestError(message: string): Error {
  return new Error(`${RELOCATION_BAD_REQUEST_PREFIX}${message}`);
}

function compareText(a: string, b: string): number {
  return a < b ? -1 : a > b ? 1 : 0;
}

export function isRelocationState(value: unknown): value is ScopeRelocationState {
  return value === 'live' || value === 'frozen' || value === 'importing';
}

export function getRelocationState(sql: SqlStorage): ScopeRelocationState {
  const rows = sql.exec(`SELECT state FROM "${RELOCATION_STATE_TABLE}" WHERE id = 1`).toArray();
  if (rows.length === 0) return 'live';
  const raw = rows[0].state;
  return isRelocationState(raw) ? raw : 'live';
}

export function assertScopeWritable(sql: SqlStorage): void {
  const state = getRelocationState(sql);
  if (state !== 'live') {
    throw new ScopeRelocatingError(state);
  }
}

export function isScopePurged(sql: SqlStorage): boolean {
  return sql.exec(`SELECT 1 FROM "${RELOCATION_PURGED_TABLE}" WHERE id = 1`).toArray().length > 0;
}

/** Reads are refused while importing, and on a purged old DO (an empty page must never look like a complete sync). */
export function assertScopeReadable(sql: SqlStorage): void {
  const state = getRelocationState(sql);
  if (state === 'importing' || isScopePurged(sql)) {
    throw new ScopeRelocatingError(state);
  }
}

/**
 * Every table created by the Scope schema that should be copied during relocation,
 * derived directly from sqlite_master (plus sqlite_sequence if present).
 * Excludes relocationState, SQLite internal tables (`sqlite_*`), and runtime internal tables
 * (`_*`, such as Cloudflare `_cf_KV` and Miniflare `__miniflare_do_name`).
 */
export function listRelocationTables(sql: SqlStorage): string[] {
  const rows = sql
    .exec("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name ASC")
    .toArray();
  const tables: string[] = [];
  for (const row of rows) {
    const name = String(row.name);
    if (name === 'sqlite_sequence') {
      tables.push(name);
      continue;
    }
    if (name === RELOCATION_STATE_TABLE || name === RELOCATION_PURGED_TABLE) continue;
    if (name.startsWith('sqlite_') || name.startsWith('_')) continue;
    tables.push(name);
  }
  tables.sort(compareText);
  return tables;
}

interface TableColumnInfo {
  columns: string[];
  integerPkAlias: string | null;
}

function readTableColumnInfo(sql: SqlStorage, table: string): TableColumnInfo {
  const rows = sql.exec(`PRAGMA table_info("${table}")`).toArray();
  const columns = rows.map((r) => String(r.name)).sort(compareText);
  const pkCols = rows.filter((r) => Number(r.pk) > 0);
  const integerPkAlias =
    pkCols.length === 1 && String(pkCols[0].type).toUpperCase() === 'INTEGER'
      ? String(pkCols[0].name)
      : null;
  return { columns, integerPkAlias };
}

function requireRelocationTable(sql: SqlStorage, table: unknown): TableColumnInfo {
  if (typeof table !== 'string' || table.length === 0) {
    throw badRequestError('table must be a non-empty string');
  }
  const tables = listRelocationTables(sql);
  if (!tables.includes(table)) {
    throw badRequestError(`Unknown or non-relocatable table '${table}'`);
  }
  return readTableColumnInfo(sql, table);
}

function readScalarValue(value: SqlStorageValue, table: string, col: string): string | number | null {
  if (value === null || typeof value === 'string' || typeof value === 'number') {
    return value;
  }
  throw badRequestError(`Unsupported column value type in ${table}.${col}`);
}

function validateScalarInput(value: unknown, table: string, col: string): string | number | null {
  if (value === null || typeof value === 'string') return value;
  if (typeof value === 'number' && Number.isFinite(value)) return value;
  throw badRequestError(`Invalid value for ${table}.${col}`);
}

export function getRelocationStatus(sql: SqlStorage): ScopeRelocationStatus {
  const state = getRelocationState(sql);
  const tableNames = listRelocationTables(sql);
  const tables: Record<string, number> = {};
  let maxServerSeq = 0;

  for (const table of tableNames) {
    const countRows = sql.exec(`SELECT COUNT(*) AS n FROM "${table}"`).toArray();
    tables[table] = countRows.length > 0 ? Number(countRows[0].n) : 0;

    const info = readTableColumnInfo(sql, table);
    if (info.columns.includes('serverSeq')) {
      const seqRows = sql.exec(`SELECT MAX(serverSeq) AS m FROM "${table}"`).toArray();
      const seq = seqRows.length > 0 && seqRows[0].m !== null ? Number(seqRows[0].m) : 0;
      if (seq > maxServerSeq) maxServerSeq = seq;
    }
  }

  const counterRows = sql.exec('SELECT id, value FROM counter ORDER BY id ASC').toArray();
  const counter = counterRows.map((r) => ({ id: Number(r.id), value: Number(r.value) }));

  return { state, tables, maxServerSeq, counter };
}

function isAllowedTransition(from: ScopeRelocationState, to: ScopeRelocationState): boolean {
  return (
    (from === 'live' && to === 'frozen') ||
    (from === 'frozen' && to === 'live') ||
    (from === 'live' && to === 'importing') ||
    (from === 'importing' && to === 'live')
  );
}

function validateExpectDigest(
  raw: unknown,
): Record<string, ScopeTableDigest> {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) {
    throw badRequestError('expectDigest must be a table digest map');
  }
  const entries = Object.entries(raw);
  if (entries.length === 0) {
    throw badRequestError('expectDigest must not be empty');
  }
  const out: Record<string, ScopeTableDigest> = {};
  for (const [table, entry] of entries) {
    if (
      table.length === 0 ||
      !entry ||
      typeof entry !== 'object' ||
      Array.isArray(entry)
    ) {
      throw badRequestError(`Invalid expectDigest entry for '${table}'`);
    }
    const { count, sha256 } = entry as { count?: unknown; sha256?: unknown };
    if (
      typeof count !== 'number' ||
      !Number.isSafeInteger(count) ||
      count < 0 ||
      typeof sha256 !== 'string' ||
      sha256.length === 0
    ) {
      throw badRequestError(`Invalid expectDigest count/sha256 for '${table}'`);
    }
    out[table] = { count, sha256 };
  }
  return out;
}

export function setRelocationState(
  sql: SqlStorage,
  input: ScopeSetRelocationStateInput,
): ScopeSetRelocationStateResponse {
  if (!isRelocationState(input.state) || !isRelocationState(input.expect)) {
    throw badRequestError('state and expect must be live, frozen, or importing');
  }
  const current = getRelocationState(sql);
  if (current !== input.expect) {
    throw conflictError(`Relocation state mismatch: expected '${input.expect}', actual '${current}'`);
  }
  if (!isAllowedTransition(current, input.state)) {
    throw conflictError(`Illegal relocation state transition: '${current}' -> '${input.state}'`);
  }
  if (isScopePurged(sql)) {
    throw conflictError('Scope data was purged after relocation; its state can no longer change');
  }

  if (current === 'live' && input.state === 'importing') {
    const nonEmpty: string[] = [];
    for (const table of listRelocationTables(sql)) {
      const rows = sql.exec(`SELECT COUNT(*) AS n FROM "${table}"`).toArray();
      if (rows.length > 0 && Number(rows[0].n) > 0) {
        nonEmpty.push(`${table}=${Number(rows[0].n)}`);
      }
    }
    if (nonEmpty.length > 0) {
      throw conflictError(`Cannot begin import into non-empty scope (${nonEmpty.join(', ')})`);
    }
  }

  if (current === 'importing' && input.state === 'live') {
    const expected = validateExpectDigest(input.expectDigest);
    const actual = computeScopeDigest(sql).tables;
    const allTables = Array.from(
      new Set([...Object.keys(expected), ...Object.keys(actual)]),
    ).sort(compareText);
    const diffs: string[] = [];
    for (const table of allTables) {
      const e = expected[table];
      const a = actual[table];
      if (!e) {
        diffs.push(`${table} (extra on target: count=${a.count})`);
      } else if (!a) {
        diffs.push(`${table} (missing on target: expected count=${e.count})`);
      } else if (e.count !== a.count || e.sha256 !== a.sha256) {
        diffs.push(`${table} (expected count=${e.count} sha256=${e.sha256}, actual count=${a.count} sha256=${a.sha256})`);
      }
    }
    if (diffs.length > 0) {
      throw conflictError(`Digest mismatch on finish-import: ${diffs.join('; ')}`);
    }
  }

  sql.exec(
    `INSERT INTO "${RELOCATION_STATE_TABLE}" (id, state) VALUES (1, ?) ON CONFLICT (id) DO UPDATE SET state = excluded.state`,
    input.state,
  );
  return { previous: current, state: input.state };
}

export function exportTablePage(
  sql: SqlStorage,
  input: ScopeExportPageInput,
): ScopeExportPageResponse {
  const state = getRelocationState(sql);
  if (state !== 'frozen') {
    throw conflictError(`exportPage requires state 'frozen' (actual: '${state}')`);
  }
  const { columns } = requireRelocationTable(sql, input.table);

  const afterRowid = input.afterRowid ?? 0;
  if (typeof afterRowid !== 'number' || !Number.isSafeInteger(afterRowid) || afterRowid < 0) {
    throw badRequestError('afterRowid must be a non-negative integer');
  }
  const maxChars = input.maxChars ?? MAX_PULL_PAGE_CHARS;
  if (typeof maxChars !== 'number' || !Number.isSafeInteger(maxChars) || maxChars < 1) {
    throw badRequestError('maxChars must be a positive integer');
  }

  const colSelect = columns.map((c) => `"${c}"`).join(', ');
  const rows: ScopeExportedRow[] = [];
  let cursor = afterRowid;
  let chars = 0;

  while (true) {
    const batch = sql
      .exec(
        `SELECT rowid AS "${ROWID_ALIAS}", ${colSelect} FROM "${input.table}" WHERE rowid > ? ORDER BY rowid ASC LIMIT ?`,
        cursor,
        SQL_BATCH_SIZE + 1,
      )
      .toArray();
    const hasMoreInSql = batch.length > SQL_BATCH_SIZE;
    const slice = hasMoreInSql ? batch.slice(0, SQL_BATCH_SIZE) : batch;

    for (const raw of slice) {
      const rowid = Number(raw[ROWID_ALIAS]);
      const values: Record<string, string | number | null> = {};
      for (const col of columns) {
        values[col] = readScalarValue(raw[col], input.table, col);
      }
      const entry: ScopeExportedRow = { rowid, values };
      const entryLen = JSON.stringify(entry).length;
      if (chars + entryLen > maxChars && rows.length > 0) {
        return { table: input.table, rows, nextAfterRowid: cursor, done: false };
      }
      rows.push(entry);
      chars += entryLen;
      cursor = rowid;
    }

    if (!hasMoreInSql) {
      return { table: input.table, rows, nextAfterRowid: cursor, done: true };
    }
    if (chars >= maxChars) {
      return { table: input.table, rows, nextAfterRowid: cursor, done: false };
    }
  }
}

export function importTablePage(
  sql: SqlStorage,
  input: ScopeImportPageInput,
): ScopeImportPageResponse {
  const state = getRelocationState(sql);
  if (state !== 'importing') {
    throw conflictError(`importPage requires state 'importing' (actual: '${state}')`);
  }
  const { columns, integerPkAlias } = requireRelocationTable(sql, input.table);
  if (!Array.isArray(input.rows)) {
    throw badRequestError('rows must be an array');
  }

  const validCols = new Set(columns);
  for (const row of input.rows) {
    if (!row || typeof row !== 'object' || Array.isArray(row)) {
      throw badRequestError('Each row must be an object with rowid and values');
    }
    if (typeof row.rowid !== 'number' || !Number.isSafeInteger(row.rowid)) {
      throw badRequestError('row.rowid must be a safe integer');
    }
    if (!row.values || typeof row.values !== 'object' || Array.isArray(row.values)) {
      throw badRequestError('row.values must be a plain object');
    }
    const keys = Object.keys(row.values);
    for (const col of keys) {
      if (!validCols.has(col)) {
        throw badRequestError(`Unknown column '${col}' for table '${input.table}'`);
      }
    }

    if (integerPkAlias !== null) {
      const insertCols = keys.includes(integerPkAlias) ? keys : [integerPkAlias, ...keys];
      const params: Array<string | number | null> = insertCols.map((col) => {
        if (col === integerPkAlias) {
          if (Object.hasOwn(row.values, col)) {
            const v = validateScalarInput(row.values[col], input.table, col);
            if (v !== row.rowid) {
              throw badRequestError(`row.rowid must match ${input.table}.${integerPkAlias}`);
            }
            return v;
          }
          return row.rowid;
        }
        return validateScalarInput(row.values[col], input.table, col);
      });
      const colList = insertCols.map((c) => `"${c}"`).join(', ');
      const placeholders = insertCols.map(() => '?').join(', ');
      sql.exec(`INSERT INTO "${input.table}" (${colList}) VALUES (${placeholders})`, ...params);
    } else {
      const params: Array<string | number | null> = [
        row.rowid,
        ...keys.map((col) => validateScalarInput(row.values[col], input.table, col)),
      ];
      const colList = ['rowid', ...keys.map((c) => `"${c}"`)].join(', ');
      const placeholders = params.map(() => '?').join(', ');
      sql.exec(`INSERT INTO "${input.table}" (${colList}) VALUES (${placeholders})`, ...params);
    }
  }

  return { table: input.table, imported: input.rows.length };
}

export function computeScopeDigest(sql: SqlStorage): ScopeDigest {
  const state = getRelocationState(sql);
  const tables: Record<string, ScopeTableDigest> = {};

  for (const table of listRelocationTables(sql)) {
    const { columns } = readTableColumnInfo(sql, table);
    const colSelect = columns.map((c) => `"${c}"`).join(', ');
    const hasher = new Sha256();
    hasher.updateText(`${JSON.stringify(columns)}\n`);

    let cursor = 0;
    let count = 0;
    while (true) {
      const batch = sql
        .exec(
          `SELECT rowid AS "${ROWID_ALIAS}", ${colSelect} FROM "${table}" WHERE rowid > ? ORDER BY rowid ASC LIMIT ?`,
          cursor,
          SQL_BATCH_SIZE,
        )
        .toArray();
      if (batch.length === 0) break;
      for (const raw of batch) {
        const rowid = Number(raw[ROWID_ALIAS]);
        const tuple: Array<string | number | null> = [rowid];
        for (const col of columns) {
          tuple.push(readScalarValue(raw[col], table, col));
        }
        hasher.updateText(`${JSON.stringify(tuple)}\n`);
        count += 1;
        cursor = rowid;
      }
      if (batch.length < SQL_BATCH_SIZE) break;
    }

    tables[table] = { count, sha256: hasher.hex() };
  }

  return { state, tables };
}

/**
 * Deletes every row of a relocated (frozen) old DO and keeps it frozen, so the empty object still
 * rejects writes instead of silently accepting them. The caller runs it in one storage transaction.
 */
export function purgeFrozenData(
  sql: SqlStorage,
  input: ScopePurgeFrozenInput,
  nowMs: number,
): ScopePurgeFrozenResponse {
  const state = getRelocationState(sql);
  if (state !== 'frozen') {
    throw conflictError(`purgeFrozenData requires state 'frozen' (actual: '${state}')`);
  }
  const expect = input?.expectMaxServerSeq;
  if (typeof expect !== 'number' || !Number.isSafeInteger(expect) || expect < 0) {
    throw badRequestError('expectMaxServerSeq must be a non-negative integer');
  }
  const actual = getRelocationStatus(sql).maxServerSeq;
  if (actual !== expect) {
    throw conflictError(`maxServerSeq mismatch: expected ${expect}, actual ${actual}`);
  }
  const deleted: Record<string, number> = {};
  for (const table of listRelocationTables(sql)) {
    const rows = sql.exec(`SELECT COUNT(*) AS n FROM "${table}"`).toArray();
    deleted[table] = rows.length > 0 ? Number(rows[0].n) : 0;
    sql.exec(`DELETE FROM "${table}"`);
  }
  sql.exec(`INSERT OR IGNORE INTO "${RELOCATION_PURGED_TABLE}" (id, purgedAt) VALUES (1, ?)`, nowMs);
  return { deleted, state: getRelocationState(sql) };
}
