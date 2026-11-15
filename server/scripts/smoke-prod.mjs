const baseUrl = (process.env.BASE_URL ?? 'https://daydo-api.audichuang.app').replace(/\/+$/, '');
const clientId = process.env.CF_ACCESS_CLIENT_ID;
const clientSecret = process.env.CF_ACCESS_CLIENT_SECRET;

if (!clientId || !clientSecret) {
  console.error('Missing CF_ACCESS_CLIENT_ID or CF_ACCESS_CLIENT_SECRET in environment.');
  process.exit(1);
}

const accessHeaders = {
  'CF-Access-Client-Id': clientId,
  'CF-Access-Client-Secret': clientSecret,
};

let failed = false;

async function check(label, run) {
  try {
    const detail = await run();
    console.log(`PASS ${label}: ${detail}`);
  } catch (error) {
    failed = true;
    const message = error instanceof Error ? error.message : String(error);
    console.error(`FAIL ${label}: ${message}`);
  }
}

await check('GET /health without Access headers -> blocked (not 2xx)', async () => {
  const res = await fetch(`${baseUrl}/health`, { redirect: 'manual' });
  const isRedirect = res.status >= 300 && res.status < 400;
  if (res.status !== 401 && res.status !== 403 && !isRedirect) {
    throw new Error(`expected 401, 403, or Access redirect, got ${res.status}`);
  }
  return `status=${res.status}`;
});

await check('GET /health with Access headers -> 200', async () => {
  const res = await fetch(`${baseUrl}/health`, {
    headers: accessHeaders,
    redirect: 'manual',
  });
  if (res.status !== 200) {
    throw new Error(`expected 200, got ${res.status}`);
  }
  const body = await res.json().catch(() => null);
  if (!body || body.ok !== true) {
    throw new Error('expected JSON { ok: true }');
  }
  return `status=${res.status}`;
});

await check('POST /auth/google with Access headers and bogus token -> 401', async () => {
  const res = await fetch(`${baseUrl}/auth/google`, {
    method: 'POST',
    headers: {
      ...accessHeaders,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ idToken: 'bogus', deviceId: 'smoke' }),
    redirect: 'manual',
  });
  if (res.status !== 401) {
    throw new Error(`expected 401, got ${res.status}`);
  }
  return `status=${res.status}`;
});

await check('POST /sync/pull with Access headers and no Bearer -> 401', async () => {
  const res = await fetch(`${baseUrl}/sync/pull`, {
    method: 'POST',
    headers: {
      ...accessHeaders,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({}),
    redirect: 'manual',
  });
  if (res.status !== 401) {
    throw new Error(`expected 401, got ${res.status}`);
  }
  return `status=${res.status}`;
});

await check('GET /test/protected with Access headers -> 404', async () => {
  const res = await fetch(`${baseUrl}/test/protected`, {
    headers: accessHeaders,
    redirect: 'manual',
  });
  if (res.status !== 404) {
    throw new Error(`expected 404, got ${res.status}`);
  }
  return `status=${res.status}`;
});

if (failed) {
  process.exit(1);
}
