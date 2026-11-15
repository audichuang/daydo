import { spawn, spawnSync } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import http from 'node:http';
import net from 'node:net';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { exportJWK, generateKeyPair, SignJWT } from 'jose';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const serverDir = path.resolve(__dirname, '..');

const GOOGLE_AUDIENCE = 'daydo-ios-e2e-client-id';
const APPLE_AUDIENCE = 'com.audichuang.daydo';
const JWT_SECRET = 'e2e-swift-jwt-secret-please-change-in-prod';

async function getFreePort() {
  return new Promise((resolve, reject) => {
    const srv = net.createServer();
    srv.unref();
    srv.on('error', reject);
    srv.listen(0, '127.0.0.1', () => {
      const addr = srv.address();
      const port = typeof addr === 'object' && addr ? addr.port : 0;
      srv.close(() => resolve(port));
    });
  });
}

async function startJwksServer() {
  const { publicKey, privateKey } = await generateKeyPair('ES256');
  const jwk = await exportJWK(publicKey);
  jwk.kid = 'google-e2e-swift-1';
  jwk.use = 'sig';
  jwk.alg = 'ES256';
  const jwksPayload = JSON.stringify({ keys: [jwk] });

  const server = http.createServer((req, res) => {
    if (req.url === '/google/keys') {
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(jwksPayload);
      return;
    }
    res.writeHead(404);
    res.end();
  });

  await new Promise((resolve, reject) => {
    server.on('error', reject);
    server.listen(0, '127.0.0.1', resolve);
  });
  const addr = server.address();
  const port = typeof addr === 'object' && addr ? addr.port : 0;

  return {
    baseUrl: `http://127.0.0.1:${port}`,
    async signGoogleToken(sub) {
      return new SignJWT({
        email: `${sub}@example.test`,
        name: 'Swift E2E User',
      })
        .setProtectedHeader({ alg: 'ES256', kid: jwk.kid })
        .setIssuer('https://accounts.google.com')
        .setAudience(GOOGLE_AUDIENCE)
        .setSubject(sub)
        .setIssuedAt()
        .setExpirationTime('10m')
        .sign(privateKey);
    },
    close() {
      return new Promise((resolve) => server.close(() => resolve()));
    },
  };
}

function killProcessTree(child) {
  if (!child || child.killed || child.exitCode !== null) return;
  try {
    process.kill(-child.pid, 'SIGTERM');
  } catch {
    try {
      child.kill('SIGTERM');
    } catch {
      // ignore
    }
  }
}

async function waitForHealth(baseUrl, timeoutMs = 20_000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try {
      const res = await fetch(`${baseUrl}/health`);
      if (res.ok) {
        const body = await res.json();
        if (body?.ok) return;
      }
    } catch {
      // server not ready yet
    }
    await new Promise((r) => setTimeout(r, 250));
  }
  throw new Error(`Dev server did not become healthy at ${baseUrl}/health within ${timeoutMs}ms`);
}

function runCommand(cmd, args, opts = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(cmd, args, {
      stdio: 'inherit',
      ...opts,
    });
    child.on('error', reject);
    child.on('exit', (code, signal) => {
      if (signal) {
        resolve(1);
      } else {
        resolve(code ?? 1);
      }
    });
  });
}

async function main() {
  const jwks = await startJwksServer();
  const devPort = await getFreePort();
  const baseUrl = `http://127.0.0.1:${devPort}`;
  const env = {
    ...process.env,
    JWT_SECRET,
    APPLE_AUDIENCE,
    GOOGLE_AUDIENCE,
    GOOGLE_JWKS_URL: `${jwks.baseUrl}/google/keys`,
  };

  let devChild = null;
  try {
    const voidBin = path.join(serverDir, 'node_modules', '.bin', 'void');
    const viteBin = path.join(serverDir, 'node_modules', '.bin', 'vite');

    const migrate = spawnSync(voidBin, ['db', 'migrate'], {
      cwd: serverDir,
      env,
      stdio: 'inherit',
    });
    if (migrate.status !== 0) {
      throw new Error(`void db migrate failed with status ${migrate.status}`);
    }

    devChild = spawn(viteBin, ['--port', String(devPort), '--host', '127.0.0.1', '--strictPort'], {
      cwd: serverDir,
      env,
      detached: true,
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    let devLogs = '';
    devChild.stdout?.on('data', (chunk) => {
      devLogs += chunk.toString();
    });
    devChild.stderr?.on('data', (chunk) => {
      devLogs += chunk.toString();
    });

    try {
      await waitForHealth(baseUrl);
    } catch (err) {
      console.error(devLogs);
      throw err;
    }

    const sub = `google-swift-${randomUUID()}`;
    const googleToken = await jwks.signGoogleToken(sub);

    const exitCode = await runCommand(
      'swift',
      ['test', '--package-path', path.resolve(serverDir, '../DayDoCore'), '--filter', 'TwoDeviceConvergence'],
      {
        cwd: serverDir,
        env: {
          ...env,
          DAYDO_SYNC_BASE_URL: baseUrl,
          DAYDO_SYNC_GOOGLE_ID_TOKEN: googleToken,
        },
      },
    );

    if (exitCode !== 0) {
      process.exitCode = exitCode;
    }
  } finally {
    killProcessTree(devChild);
    await jwks.close();
  }
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
