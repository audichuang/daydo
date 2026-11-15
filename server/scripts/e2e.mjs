import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { createHash, randomUUID } from 'node:crypto';
import http from 'node:http';
import net from 'node:net';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { exportJWK, generateKeyPair, SignJWT } from 'jose';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const serverDir = path.resolve(__dirname, '..');

function sha256Hex(input) {
  return createHash('sha256').update(input, 'utf8').digest('hex');
}

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

async function startJwksServer() {
  const applePair = await generateKeyPair('RS256');
  const appleJwk = await exportJWK(applePair.publicKey);
  appleJwk.kid = 'apple-e2e-1';
  appleJwk.alg = 'RS256';
  appleJwk.use = 'sig';

  const googlePair = await generateKeyPair('ES256');
  const googleJwk = await exportJWK(googlePair.publicKey);
  googleJwk.kid = 'google-e2e-1';
  googleJwk.alg = 'ES256';
  googleJwk.use = 'sig';

  const server = http.createServer((req, res) => {
    res.setHeader('Content-Type', 'application/json');
    if (req.url === '/apple/keys') {
      res.end(JSON.stringify({ keys: [appleJwk] }));
      return;
    }
    if (req.url === '/google/keys') {
      res.end(JSON.stringify({ keys: [googleJwk] }));
      return;
    }
    res.statusCode = 404;
    res.end(JSON.stringify({ error: 'Not found' }));
  });

  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const addr = server.address();
  assert(addr && typeof addr !== 'string', 'JWKS server failed to bind');

  return {
    baseUrl: `http://127.0.0.1:${addr.port}`,
    applePrivateKey: applePair.privateKey,
    googlePrivateKey: googlePair.privateKey,
    close: () => new Promise((resolve) => server.close(() => resolve())),
  };
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

async function postJson(baseUrl, routePath, body) {
  const res = await fetch(`${baseUrl}${routePath}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });
  const data = await res.json().catch(() => null);
  return { status: res.status, data };
}

async function main() {
  const jwks = await startJwksServer();
  const devPort = await getFreePort();
  const baseUrl = `http://127.0.0.1:${devPort}`;

  const env = {
    ...process.env,
    JWT_SECRET: 'e2e-test-jwt-secret-must-be-at-least-32-bytes',
    APPLE_AUDIENCE: 'com.audichuang.daydo',
    APPLE_JWKS_URL: `${jwks.baseUrl}/apple/keys`,
    GOOGLE_AUDIENCE: 'daydo-ios-e2e-client-id',
    GOOGLE_JWKS_URL: `${jwks.baseUrl}/google/keys`,
  };

  let devChild = null;
  const logs = [];
  const appendLog = (chunk) => {
    logs.push(chunk.toString());
    if (logs.length > 200) logs.shift();
  };

  const cleanup = () => {
    killProcessTree(devChild);
  };
  process.on('SIGINT', cleanup);
  process.on('SIGTERM', cleanup);

  try {
    // Ensure local D1 migrations are applied before booting the Worker.
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
      {
        cwd: serverDir,
        env,
        detached: true,
        stdio: ['ignore', 'pipe', 'pipe'],
      },
    );
    devChild.stdout.on('data', appendLog);
    devChild.stderr.on('data', appendLog);

    await waitForHealth(baseUrl, devChild, () => logs.join(''));

    const sharedEmail = `user-${randomUUID()}@example.com`;
    const appleSub = `apple-${randomUUID()}`;
    const googleSub = `google-${randomUUID()}`;
    const deviceId = `device-${randomUUID()}`;

    const signApple = async (rawNonce) =>
      new SignJWT({
        nonce: sha256Hex(rawNonce),
        email: sharedEmail,
      })
        .setProtectedHeader({ alg: 'RS256', kid: 'apple-e2e-1' })
        .setIssuer('https://appleid.apple.com')
        .setAudience(env.APPLE_AUDIENCE)
        .setSubject(appleSub)
        .setIssuedAt()
        .setExpirationTime('10m')
        .sign(jwks.applePrivateKey);

    // 1. Apple login creates user (isNewAccount true)
    const rawNonce1 = `nonce-1-${randomUUID()}`;
    const appleToken1 = await signApple(rawNonce1);
    const appleLogin1 = await postJson(baseUrl, '/auth/apple', {
      identityToken: appleToken1,
      nonce: rawNonce1,
      deviceId,
    });
    assert.equal(appleLogin1.status, 200, `Expected 200, got ${appleLogin1.status}`);
    assert.equal(appleLogin1.data.isNewAccount, true);
    assert.equal(typeof appleLogin1.data.accessToken, 'string');
    assert.equal(typeof appleLogin1.data.refreshToken, 'string');
    assert.equal(typeof appleLogin1.data.user?.id, 'string');

    // 2. Second login same sub returns same user (isNewAccount false)
    const rawNonce2 = `nonce-2-${randomUUID()}`;
    const appleToken2 = await signApple(rawNonce2);
    const appleLogin2 = await postJson(baseUrl, '/auth/apple', {
      identityToken: appleToken2,
      nonce: rawNonce2,
      deviceId,
    });
    assert.equal(appleLogin2.status, 200);
    assert.equal(appleLogin2.data.isNewAccount, false);
    assert.equal(appleLogin2.data.user.id, appleLogin1.data.user.id);

    // 3. Google login (different provider, even same email) makes a different user
    const googleToken = await new SignJWT({ email: sharedEmail })
      .setProtectedHeader({ alg: 'ES256', kid: 'google-e2e-1' })
      .setIssuer('https://accounts.google.com')
      .setAudience(env.GOOGLE_AUDIENCE)
      .setSubject(googleSub)
      .setIssuedAt()
      .setExpirationTime('10m')
      .sign(jwks.googlePrivateKey);

    const googleLogin = await postJson(baseUrl, '/auth/google', {
      idToken: googleToken,
      deviceId,
    });
    assert.equal(googleLogin.status, 200);
    assert.equal(googleLogin.data.isNewAccount, true);
    assert.notEqual(googleLogin.data.user.id, appleLogin1.data.user.id);

    // 4. Bad nonce returns 401
    const badNonce = await postJson(baseUrl, '/auth/apple', {
      identityToken: appleToken1,
      nonce: 'wrong-nonce',
      deviceId,
    });
    assert.equal(badNonce.status, 401);

    // 5. Refresh rotation works
    const refreshed = await postJson(baseUrl, '/auth/refresh', {
      refreshToken: appleLogin1.data.refreshToken,
    });
    assert.equal(refreshed.status, 200);
    assert.equal(typeof refreshed.data.accessToken, 'string');
    assert.equal(typeof refreshed.data.refreshToken, 'string');
    assert.notEqual(refreshed.data.refreshToken, appleLogin1.data.refreshToken);

    // 6. Reusing an old refresh token returns 401 and revokes that session chain
    const replayOld = await postJson(baseUrl, '/auth/refresh', {
      refreshToken: appleLogin1.data.refreshToken,
    });
    assert.equal(replayOld.status, 401);

    const useRevokedChain = await postJson(baseUrl, '/auth/refresh', {
      refreshToken: refreshed.data.refreshToken,
    });
    assert.equal(useRevokedChain.status, 401);

    // Separate login session chain on the same user/device remains valid.
    const otherChainRefresh = await postJson(baseUrl, '/auth/refresh', {
      refreshToken: appleLogin2.data.refreshToken,
    });
    assert.equal(otherChainRefresh.status, 200);

    // 7. Protected test route returns 401 without bearer and 200 with it
    const unauthRes = await fetch(`${baseUrl}/test/protected`);
    assert.equal(unauthRes.status, 401);

    const authRes = await fetch(`${baseUrl}/test/protected`, {
      headers: { Authorization: `Bearer ${refreshed.data.accessToken}` },
    });
    assert.equal(authRes.status, 200);
    const authData = await authRes.json();
    assert.equal(authData.userId, appleLogin1.data.user.id);

    console.log('e2e: all 7 auth & session assertions passed');
  } finally {
    process.off('SIGINT', cleanup);
    process.off('SIGTERM', cleanup);
    killProcessTree(devChild);
    await jwks.close();
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
