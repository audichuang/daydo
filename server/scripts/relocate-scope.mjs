import { appendFileSync, existsSync, mkdirSync, writeFileSync } from 'node:fs';
import path from 'node:path';

/** Budget per export page in JSON chars (CJK is up to 3 UTF-8 bytes/char; stays well under 32 MiB RPC limit). */
const EXPORT_MAX_CHARS = 1_000_000;

function usage() {
  console.log(`Usage: node scripts/relocate-scope.mjs <command> [args...]

Commands (nothing runs without an explicit subcommand):
  status <physical>
  freeze <oldPhysical>
  unfreeze <oldPhysical>
  copy <oldPhysical> <newPhysical> <backupDir>
  finish <oldPhysical> <newPhysical>

Required environment variables:
  SCOPE_ADMIN_TOKEN         Admin bearer token for POST /admin/scope-relocation
  CF_ACCESS_CLIENT_ID       Cloudflare Access service token client ID
  CF_ACCESS_CLIENT_SECRET   Cloudflare Access service token client secret

Optional environment variables:
  BASE_URL                  Default: https://api.daydoapp.com`);
}

function compareText(a, b) {
  return a < b ? -1 : a > b ? 1 : 0;
}

const args = process.argv.slice(2);
const command = args[0];

if (!command) {
  usage();
  process.exit(2);
}
if (command === '-h' || command === '--help') {
  usage();
  process.exit(0);
}

const expectedArgCounts = {
  status: 2,
  freeze: 2,
  unfreeze: 2,
  copy: 4,
  finish: 3,
};
if (!Object.hasOwn(expectedArgCounts, command)) {
  console.error(`Unknown subcommand: ${command}`);
  usage();
  process.exit(2);
}

if (args.length !== expectedArgCounts[command]) {
  console.error(`Wrong number of arguments for '${command}'.`);
  usage();
  process.exit(2);
}

const baseUrl = (process.env.BASE_URL ?? 'https://api.daydoapp.com').replace(/\/+$/, '');
const adminToken = process.env.SCOPE_ADMIN_TOKEN;
const accessClientId = process.env.CF_ACCESS_CLIENT_ID;
const accessClientSecret = process.env.CF_ACCESS_CLIENT_SECRET;

if (!adminToken || !accessClientId || !accessClientSecret) {
  console.error(
    'Missing required env vars: SCOPE_ADMIN_TOKEN, CF_ACCESS_CLIENT_ID, CF_ACCESS_CLIENT_SECRET.',
  );
  process.exit(1);
}

async function callAdmin(payload) {
  const res = await fetch(`${baseUrl}/admin/scope-relocation`, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${adminToken}`,
      'CF-Access-Client-Id': accessClientId,
      'CF-Access-Client-Secret': accessClientSecret,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify(payload),
    redirect: 'manual',
  });
  const text = await res.text();
  let json = null;
  try {
    json = JSON.parse(text);
  } catch {
    // Non-JSON response (for example Access redirect or proxy error).
  }
  if (!res.ok) {
    const detail = json && typeof json.error === 'string' ? json.error : text.slice(0, 200);
    throw new Error(`HTTP ${res.status} for action '${payload.action}': ${detail}`);
  }
  if (!json || typeof json !== 'object') {
    throw new Error(`Expected JSON object response for action '${payload.action}'`);
  }
  return json;
}

function compareDigests(oldDigest, newDigest) {
  const allTables = Array.from(
    new Set([...Object.keys(oldDigest.tables ?? {}), ...Object.keys(newDigest.tables ?? {})]),
  ).sort(compareText);

  let mismatches = 0;
  console.log('\nDigest comparison:');
  for (const table of allTables) {
    const o = oldDigest.tables?.[table];
    const n = newDigest.tables?.[table];
    const ok = Boolean(o && n && o.count === n.count && o.sha256 === n.sha256);
    if (!ok) mismatches += 1;
    const status = ok ? 'OK      ' : 'MISMATCH';
    console.log(
      `  ${status} ${table}: old=(count=${o?.count ?? 'missing'}, sha256=${o?.sha256 ?? 'missing'}) new=(count=${n?.count ?? 'missing'}, sha256=${n?.sha256 ?? 'missing'})`,
    );
  }
  return { allTables, mismatches };
}

async function runCopy(oldPhysical, newPhysical, backupDir) {
  if (oldPhysical === newPhysical) {
    throw new Error('oldPhysical and newPhysical must be different.');
  }

  const oldStatus = await callAdmin({ action: 'status', physical: oldPhysical });
  if (oldStatus.state !== 'frozen') {
    throw new Error(
      `Source '${oldPhysical}' must be frozen before copy (actual state: ${oldStatus.state}).`,
    );
  }

  const tables = Object.keys(oldStatus.tables ?? {}).sort(compareText);
  if (tables.length === 0) {
    throw new Error(`Source '${oldPhysical}' reported no tables.`);
  }
  const countsSummary = tables.map((t) => `${t}=${oldStatus.tables[t]}`).join(', ');
  console.log(
    `Source '${oldPhysical}': state=${oldStatus.state}, maxServerSeq=${oldStatus.maxServerSeq}, counts={${countsSummary}}`,
  );

  const totalSourceRows = tables.reduce((sum, t) => sum + Number(oldStatus.tables[t] ?? 0), 0);
  if (oldStatus.maxServerSeq === 0 || totalSourceRows === 0) {
    throw new Error(
      `Source '${oldPhysical}' is empty (maxServerSeq=${oldStatus.maxServerSeq}, totalRows=${totalSourceRows}); refusing to copy.`,
    );
  }

  const newStatus = await callAdmin({ action: 'status', physical: newPhysical });
  if (newStatus.state !== 'live') {
    throw new Error(
      `Target '${newPhysical}' must be in state 'live' before copy (actual state: ${newStatus.state}).`,
    );
  }
  const nonEmptyTarget = Object.entries(newStatus.tables ?? {}).filter(([, n]) => n !== 0);
  if (nonEmptyTarget.length > 0) {
    const summary = nonEmptyTarget.map(([t, n]) => `${t}=${n}`).join(', ');
    throw new Error(`Target '${newPhysical}' is not empty: ${summary}`);
  }

  mkdirSync(backupDir, { recursive: true });
  for (const table of tables) {
    const filePath = path.join(backupDir, `${table}.jsonl`);
    if (existsSync(filePath)) {
      throw new Error(`Backup file already exists: ${filePath}. Use a fresh backupDir.`);
    }
  }

  await callAdmin({ action: 'begin-import', physical: newPhysical });
  console.log(`Target '${newPhysical}' transitioned live -> importing.`);

  for (const table of tables) {
    const filePath = path.join(backupDir, `${table}.jsonl`);
    writeFileSync(filePath, '', { flag: 'wx' });

    let afterRowid = 0;
    let totalRows = 0;
    let pages = 0;
    while (true) {
      const page = await callAdmin({
        action: 'export',
        physical: oldPhysical,
        table,
        afterRowid,
        maxChars: EXPORT_MAX_CHARS,
      });
      pages += 1;
      const rows = Array.isArray(page.rows) ? page.rows : [];
      if (rows.length > 0) {
        const chunk = `${rows.map((r) => JSON.stringify(r)).join('\n')}\n`;
        appendFileSync(filePath, chunk);
        await callAdmin({
          action: 'import',
          physical: newPhysical,
          table,
          rows,
        });
        totalRows += rows.length;
      }
      if (page.done) break;
      if (typeof page.nextAfterRowid !== 'number' || page.nextAfterRowid <= afterRowid) {
        throw new Error(`Export pagination did not advance for table '${table}'.`);
      }
      afterRowid = page.nextAfterRowid;
    }
    console.log(`Copied ${table}: ${totalRows} rows (${pages} page${pages === 1 ? '' : 's'})`);
  }

  const [oldDigest, newDigest] = await Promise.all([
    callAdmin({ action: 'digest', physical: oldPhysical }),
    callAdmin({ action: 'digest', physical: newPhysical }),
  ]);

  const { allTables, mismatches } = compareDigests(oldDigest, newDigest);
  if (mismatches > 0) {
    console.error(
      `\nERROR: ${mismatches} table(s) mismatched. Did NOT run finish-import on '${newPhysical}'.`,
    );
    process.exit(1);
  }

  console.log(
    `\nAll ${allTables.length} table digests match. Backup written to ${backupDir}.\nReview the output above, then run: node scripts/relocate-scope.mjs finish ${oldPhysical} ${newPhysical}`,
  );
}

async function runFinish(oldPhysical, newPhysical) {
  if (oldPhysical === newPhysical) {
    throw new Error('oldPhysical and newPhysical must be different.');
  }

  const [oldDigest, newDigest] = await Promise.all([
    callAdmin({ action: 'digest', physical: oldPhysical }),
    callAdmin({ action: 'digest', physical: newPhysical }),
  ]);

  if (oldDigest.state !== 'frozen') {
    throw new Error(
      `Source '${oldPhysical}' must be in state 'frozen' before finish (actual state: ${oldDigest.state}).`,
    );
  }
  if (newDigest.state !== 'importing') {
    throw new Error(
      `Target '${newPhysical}' must be in state 'importing' before finish (actual state: ${newDigest.state}).`,
    );
  }

  const { allTables, mismatches } = compareDigests(oldDigest, newDigest);
  if (allTables.length === 0) {
    throw new Error(`Source '${oldPhysical}' digest reported no tables.`);
  }
  if (mismatches > 0) {
    console.error(
      `\nERROR: ${mismatches} table(s) mismatched. Refused to call finish-import on '${newPhysical}'.`,
    );
    process.exit(1);
  }

  const res = await callAdmin({
    action: 'finish-import',
    physical: newPhysical,
    expectDigest: oldDigest.tables,
  });
  console.log(JSON.stringify(res, null, 2));
}

try {
  if (command === 'status') {
    const res = await callAdmin({ action: 'status', physical: args[1] });
    console.log(JSON.stringify(res, null, 2));
  } else if (command === 'freeze') {
    const res = await callAdmin({ action: 'freeze', physical: args[1] });
    console.log(JSON.stringify(res, null, 2));
  } else if (command === 'unfreeze') {
    const res = await callAdmin({ action: 'unfreeze', physical: args[1] });
    console.log(JSON.stringify(res, null, 2));
  } else if (command === 'copy') {
    await runCopy(args[1], args[2], args[3]);
  } else if (command === 'finish') {
    await runFinish(args[1], args[2]);
  }
} catch (error) {
  console.error(error instanceof Error ? error.message : String(error));
  process.exit(1);
}
