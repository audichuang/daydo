import { spawn } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const serverDir = path.resolve(__dirname, '..');
const e2eSyncScript = path.join(__dirname, 'e2e-sync.mjs');

const EXPECTED_ERROR_KIND = 'AssertionError';
const EXPECTED_ASSERTION = "Expected highest HLC value 'title-19', got '";

function runConcurrencyWithFault(syncFault) {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [e2eSyncScript, '--only', 'concurrency'], {
      cwd: serverDir,
      env: {
        ...process.env,
        SYNC_FAULT: syncFault,
      },
      stdio: ['ignore', 'pipe', 'pipe'],
    });

    let stdout = '';
    let stderr = '';
    child.stdout.on('data', (chunk) => {
      stdout += chunk.toString();
    });
    child.stderr.on('data', (chunk) => {
      stderr += chunk.toString();
    });

    const forwardSignal = (signal) => {
      if (child.exitCode === null && child.signalCode === null) {
        child.kill(signal);
      }
    };
    process.on('SIGINT', forwardSignal);
    process.on('SIGTERM', forwardSignal);

    child.on('error', (err) => {
      process.off('SIGINT', forwardSignal);
      process.off('SIGTERM', forwardSignal);
      reject(err);
    });

    child.on('close', (code, signal) => {
      process.off('SIGINT', forwardSignal);
      process.off('SIGTERM', forwardSignal);
      resolve({ code, signal, stdout, stderr });
    });
  });
}

async function main() {
  const syncFault = process.env.SYNC_FAULT ?? 'split-txn';
  const result = await runConcurrencyWithFault(syncFault);
  const combined = `${result.stdout}\n${result.stderr}`;

  if (result.signal) {
    console.error(`e2e-fault: FAIL - child terminated by signal ${result.signal}`);
    if (result.stdout) console.error(result.stdout.trimEnd());
    if (result.stderr) console.error(result.stderr.trimEnd());
    process.exit(1);
  }

  if (result.code === 0) {
    console.error(
      `e2e-fault: FAIL - concurrency scenario passed unexpectedly (SYNC_FAULT=${syncFault} did not trigger failure)`,
    );
    if (result.stdout) console.error(result.stdout.trimEnd());
    process.exit(1);
  }

  if (!combined.includes(EXPECTED_ERROR_KIND) || !combined.includes(EXPECTED_ASSERTION)) {
    console.error(
      `e2e-fault: FAIL - concurrency exited with ${result.code}, but failure did not match expected assertion "${EXPECTED_ASSERTION}"`,
    );
    if (result.stdout) console.error(result.stdout.trimEnd());
    if (result.stderr) console.error(result.stderr.trimEnd());
    process.exit(1);
  }

  const matchedLine =
    combined
      .split(/\r?\n/)
      .find((line) => line.includes(EXPECTED_ASSERTION))
      ?.trim() ?? EXPECTED_ASSERTION;
  console.log(`e2e-fault: PASS (SYNC_FAULT=${syncFault}) - ${matchedLine}`);
}

main().catch((err) => {
  console.error('e2e-fault: FAIL - unexpected runner error:', err);
  process.exit(1);
});
