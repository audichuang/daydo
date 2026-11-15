import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import net from 'node:net';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const serverDir = path.resolve(__dirname, '..');

function getFreePort() {
  return new Promise((resolve, reject) => {
    const srv = net.createServer();
    srv.unref();
    srv.on('error', reject);
    srv.listen(0, '127.0.0.1', () => {
      const addr = srv.address();
      if (!addr || typeof addr === 'string') {
        srv.close(() => reject(new Error('Failed to resolve free port')));
        return;
      }
      const port = addr.port;
      srv.close((err) => (err ? reject(err) : resolve(port)));
    });
  });
}

function killProcessTree(child) {
  if (!child || child.exitCode !== null || child.signalCode !== null) return;
  try {
    process.kill(-child.pid, 'SIGTERM');
  } catch {
    try {
      child.kill('SIGTERM');
    } catch {
      return;
    }
  }
  setTimeout(() => {
    if (child.exitCode === null && child.signalCode === null) {
      try {
        process.kill(-child.pid, 'SIGKILL');
      } catch {
        try {
          child.kill('SIGKILL');
        } catch {
          // ignore
        }
      }
    }
  }, 1500).unref();
}

async function waitForHealth(baseUrl, child, getLogs) {
  const deadline = Date.now() + 30_000;
  while (Date.now() < deadline) {
    if (child.exitCode !== null) {
      throw new Error(`Dev server exited early (${child.exitCode}):\n${getLogs()}`);
    }
    try {
      const res = await fetch(`${baseUrl}/health`);
      if (res.ok) {
        const body = await res.json();
        if (body && body.ok === true) return;
      }
    } catch {
      // Server not listening yet
    }
    await new Promise((r) => setTimeout(r, 200));
  }
  throw new Error(`Timed out waiting for dev server at ${baseUrl}:\n${getLogs()}`);
}

function parseOnlyArg(argv) {
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--only') {
      const val = argv[i + 1];
      if (!val) throw new Error('Missing value after --only');
      return val;
    }
    if (arg.startsWith('--only=')) {
      return arg.slice('--only='.length);
    }
  }
  return null;
}


const ANSI_RE = new RegExp(`${String.fromCharCode(27)}\\[[0-9;]*m`, 'g');
const stripAnsi = (s) => s.replace(ANSI_RE, '');

async function runCronRuntimeScenario({ baseUrl, getLogs }) {
  // The token hint prints after the server is ready, so it may land after /health succeeds.
  const tokenRe = /x-void-dev-trigger:\s*([0-9a-f-]{8,})/i;
  const tokenDeadline = Date.now() + 15_000;
  let tokenMatch = null;
  while (Date.now() < tokenDeadline && !(tokenMatch = stripAnsi(getLogs()).match(tokenRe))) {
    await new Promise((r) => setTimeout(r, 100));
  }
  assert(tokenMatch, `dev-trigger token not found in dev server output:\n${getLogs()}`);
  const res = await fetch(`${baseUrl}/__void/scheduled`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'x-void-dev-trigger': tokenMatch[1] },
    body: JSON.stringify({ cron: '*/5 * * * *', scheduledTime: Date.now() }),
  });
  const text = await res.text();
  assert.equal(res.status, 200, `scheduled trigger failed: ${res.status} ${text}`);

  const deadline = Date.now() + 10_000;
  let probe = null;
  while (Date.now() < deadline && !probe) {
    const m = stripAnsi(getLogs()).match(/ics\.cron\.probe (\{[^}]*\})/);
    if (m) probe = JSON.parse(m[1]);
    else await new Promise((r) => setTimeout(r, 100));
  }
  assert(probe, `ics.cron.probe log not found:\n${getLogs()}`);
  assert.deepEqual(probe, { db: 'ok', scope: 'ok', env: 'ok' });
}

const SCENARIOS = { cron_runtime: runCronRuntimeScenario };

async function main() {
  const only = parseOnlyArg(process.argv.slice(2));
  if (only !== null && !(only in SCENARIOS)) {
    throw new Error(
      `Unknown scenario '${only}'. Expected one of: ${Object.keys(SCENARIOS).join(', ')}`,
    );
  }

  const devPort = await getFreePort();
  const baseUrl = `http://127.0.0.1:${devPort}`;
  const env = {
    ...process.env,
    JWT_SECRET: 'e2e-test-jwt-secret-must-be-at-least-32-bytes',
  };

  let devChild = null;
  const logs = [];
  const appendLog = (chunk) => {
    logs.push(chunk.toString());
    if (logs.length > 400) logs.shift();
  };
  const getLogs = () => logs.join('');

  const cleanup = () => killProcessTree(devChild);
  process.on('SIGINT', cleanup);
  process.on('SIGTERM', cleanup);

  try {
    const migrateRes = spawnSync(
      path.join(serverDir, 'node_modules/.bin/void'),
      ['db', 'migrate'],
      { cwd: serverDir, env, encoding: 'utf8' },
    );
    assert.equal(
      migrateRes.status,
      0,
      `void db migrate failed:\n${migrateRes.stdout}\n${migrateRes.stderr}`,
    );

    devChild = spawn(
      path.join(serverDir, 'node_modules/.bin/vite'),
      ['--port', String(devPort), '--host', '127.0.0.1', '--strictPort'],
      { cwd: serverDir, env, detached: true, stdio: ['ignore', 'pipe', 'pipe'] },
    );
    devChild.stdout.on('data', appendLog);
    devChild.stderr.on('data', appendLog);

    await waitForHealth(baseUrl, devChild, getLogs);

    const toRun = only ? [only] : Object.keys(SCENARIOS);
    for (const name of toRun) {
      await SCENARIOS[name]({ baseUrl, getLogs });
      console.log(`e2e-ics: scenario '${name}' passed`);
    }
  } finally {
    process.off('SIGINT', cleanup);
    process.off('SIGTERM', cleanup);
    killProcessTree(devChild);
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
