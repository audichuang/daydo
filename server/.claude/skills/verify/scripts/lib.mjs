// Shared helpers for the DayDo verify scripts: config, state paths, Access headers,
// HTTP, redaction, UUIDv7/HLC. No secrets are ever printed by anything in here.
import { execFileSync } from 'node:child_process';
import { createHash, randomBytes } from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const SCRIPTS_DIR = path.dirname(fileURLToPath(import.meta.url));

const PROD_API = 'https://api.daydoapp.com';
const PROD_MCP = 'https://mcp.daydoapp.com/';

export const cfg = {
  api: (process.env.DAYDO_API ?? PROD_API).replace(/\/$/, ''),
  mcp: process.env.DAYDO_MCP ?? PROD_MCP,
  email: (process.env.DAYDO_VERIFY_EMAIL ?? 'pokemongo030501@gmail.com').trim().toLowerCase(),
  // gmail: read codes from Gmail in ego-browser; devmail: GET <api>/test/mail (dev builds only).
  codeSource: process.env.DAYDO_CODE_SOURCE ?? 'gmail',
  gmailIndex: process.env.DAYDO_GMAIL_INDEX ?? '8',
  stateDir: process.env.DAYDO_VERIFY_STATE ?? path.join(os.homedir(), '.local/state/daydo-verify'),
  claudeConfigDir: process.env.CLAUDE_CONFIG_DIR ?? '',
  seedProject: 'verify-seed',
  probePrefix: 'verify-probe',
  tmuxSocket: 'daydo-verify',
};

export const isProdApi = () => new URL(cfg.api).hostname === 'api.daydoapp.com';

fs.mkdirSync(cfg.stateDir, { recursive: true, mode: 0o700 });

// ---------------------------------------------------------------------------
// State files (outside the repo). Secrets live in session.*.json (0600); evidence lives in
// <stateDir>/<run id>/ and is never removed by cleanup.

export function statePath(name) {
  return path.join(cfg.stateDir, name);
}

export function readJson(file, fallback = null) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch {
    return fallback;
  }
}

export function writeJson(file, value, mode = 0o600) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, `${JSON.stringify(value, null, 2)}\n`, { mode });
  fs.chmodSync(file, mode);
}

/** Evidence directory of the current run; created on first use (UTC timestamp name). */
export function runDir() {
  const pointer = statePath('current');
  let id = process.env.DAYDO_VERIFY_RUN ?? (fs.existsSync(pointer) ? fs.readFileSync(pointer, 'utf8').trim() : '');
  if (!id) id = newRunId();
  const dir = path.join(cfg.stateDir, id);
  fs.mkdirSync(dir, { recursive: true });
  return dir;
}

export function newRunId() {
  const id = new Date().toISOString().replace(/[-:]/g, '').replace(/\.\d+Z$/, 'Z');
  fs.writeFileSync(statePath('current'), `${id}\n`);
  fs.mkdirSync(path.join(cfg.stateDir, id), { recursive: true });
  return id;
}

export function sessionFile() {
  return statePath(`session.${new URL(cfg.api).host.replace(/[^a-z0-9.]/gi, '_')}.json`);
}

/** Reads the device session and refuses one that was created for a different email than cfg.email. */
export function readBoundSession() {
  const s = readJson(sessionFile());
  if (s && s.email !== cfg.email) die(`device session is for ${s.email ?? '(no email recorded)'}, but DAYDO_VERIFY_EMAIL is ${cfg.email}; run device.mjs forget and login again`, 2);
  return s;
}

/** Appends one redacted line to <run>/<name>. */
export function evidence(name, value) {
  const text = typeof value === 'string' ? value : JSON.stringify(value);
  fs.appendFileSync(path.join(runDir(), name), `${redact(text)}\n`);
}

export function saveEvidence(name, value) {
  const text = typeof value === 'string' ? value : JSON.stringify(value, null, 2);
  fs.writeFileSync(path.join(runDir(), name), `${redact(text)}\n`);
}

// ---------------------------------------------------------------------------
// Redaction: tokens, codes, OAuth params, cookies, Access headers. Plain 6-digit numbers are
// only masked next to "驗證碼" or a code key, so timestamps stay readable.

export function redact(text) {
  return String(text)
    .replace(/(Bearer\s+)[A-Za-z0-9._~+/=-]+/gi, '$1***')
    .replace(/eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]*/g, '***jwt***')
    .replace(
      /("(?:accessToken|refreshToken|access_token|refresh_token|id_token|code|code_verifier|codeVerifier|ct|consentToken|token|secret|Authorization|cookie|Cookie)"\s*:\s*)"[^"]*"/g,
      '$1"***"',
    )
    .replace(/([?&](?:code|state|ct|pending|code_challenge|code_verifier|nonce)=)[^&\s"'<>]+/g, '$1***')
    .replace(/(daydo_oauth_bind_[A-Za-z0-9_-]*=)[^;\s"']+/g, '$1***')
    .replace(/(CF-Access-Client-(?:Id|Secret)["']?\s*[:=]\s*["']?)[^"'\s,}]+/gi, '$1***')
    .replace(/(驗證碼\s*[：:]\s*)\d{6}/g, '$1******');
}

// ---------------------------------------------------------------------------
// Cloudflare Access service token (production API host only), read through the 1Password
// service account in a child bash so the values never reach argv or stdout.

let accessCache = null;
export function accessHeaders() {
  if (!isProdApi()) return {};
  if (accessCache) return accessCache;
  const item = 'op://Agent/DayDo Cloudflare Access service token';
  const read = (field) =>
    execFileSync('bash', ['-c', `set -a; . "$HOME/.config/op/agent-sa.env"; set +a; op read "${item}/${field}"`], {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'pipe'],
    }).trim();
  accessCache = { 'CF-Access-Client-Id': read('username'), 'CF-Access-Client-Secret': read('credential') };
  return accessCache;
}

export async function apiRequest(method, route, body, token) {
  const headers = { ...accessHeaders() };
  if (body !== undefined) headers['Content-Type'] = 'application/json';
  if (token) headers.Authorization = `Bearer ${token}`;
  const res = await fetch(`${cfg.api}${route}`, {
    method,
    headers,
    body: body === undefined ? undefined : JSON.stringify(body),
    redirect: 'manual',
  });
  const text = await res.text();
  let data = null;
  try {
    data = JSON.parse(text);
  } catch {
    data = text.slice(0, 500);
  }
  return { status: res.status, data };
}

// ---------------------------------------------------------------------------
// Ids and clocks (spec/sync.md 線上格式)

export function uuidv7() {
  const b = randomBytes(16);
  let ms = BigInt(Date.now());
  for (let i = 5; i >= 0; i -= 1) {
    b[i] = Number(ms & 0xffn);
    ms >>= 8n;
  }
  b[6] = (b[6] & 0x0f) | 0x70;
  b[8] = (b[8] & 0x3f) | 0x80;
  const h = b.toString('hex');
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`;
}

export function hlc(ms, counter, deviceId) {
  return `${String(ms).padStart(13, '0')}:${String(counter).padStart(4, '0')}:${deviceId.toLowerCase()}`;
}

export function sha8(text) {
  return createHash('sha256').update(text).digest('hex').slice(0, 8);
}

export function die(message, code = 1) {
  console.error(`FAIL: ${redact(message)}`);
  process.exit(code);
}

/** Minimal `--key value` / `--flag` parser. */
export function parseArgs(argv) {
  const out = { _: [] };
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    if (a.startsWith('--')) {
      const key = a.slice(2);
      const next = argv[i + 1];
      if (next === undefined || next.startsWith('--')) out[key] = true;
      else {
        out[key] = next;
        i += 1;
      }
    } else out._.push(a);
  }
  return out;
}

/** Keychain item / file that holds Claude Code credentials for the current CLAUDE_CONFIG_DIR. */
export function claudeCredentialStores() {
  const dir = cfg.claudeConfigDir;
  const service = dir ? `Claude Code-credentials-${sha8(dir)}` : 'Claude Code-credentials';
  const file = path.join(dir || path.join(os.homedir(), '.claude'), '.credentials.json');
  return { service, file };
}

/**
 * Top-level key names (and mcpOAuth entry names) of both stores; never values. Fail-closed: only
 * `security` exit 44 (item not found) and a missing file mean "no credentials"; any other error or
 * unparsable JSON throws, because "cannot tell" must not read as "no token".
 */
export function claudeCredentialKeys() {
  const { service, file } = claudeCredentialStores();
  const shape = (obj) =>
    obj && typeof obj === 'object'
      ? {
          keys: Object.keys(obj),
          mcpOAuth: Object.entries(obj.mcpOAuth ?? {}).map(([k, v]) => ({
            key: k,
            serverUrl: v?.serverUrl ?? null,
            hasAccessToken: Boolean(v?.accessToken),
            hasRefreshToken: Boolean(v?.refreshToken),
          })),
        }
      : null;
  let raw = null;
  try {
    raw = execFileSync('security', ['find-generic-password', '-s', service, '-w'], {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore'],
    });
  } catch (e) {
    if (e.status !== 44) throw new Error(`security find-generic-password "${service}" failed (exit ${e.status ?? e.code}); cannot tell whether a Claude Code token exists`);
  }
  let keychain = null;
  if (raw !== null) {
    try {
      keychain = shape(JSON.parse(raw));
    } catch {
      throw new Error(`keychain item "${service}" is not valid JSON; cannot tell whether a Claude Code token exists`);
    }
  }
  let fileShape = null;
  if (fs.existsSync(file)) {
    try {
      fileShape = shape(JSON.parse(fs.readFileSync(file, 'utf8')));
    } catch {
      throw new Error(`${file} is unreadable or not valid JSON; cannot tell whether a Claude Code token exists`);
    }
  }
  return { service, keychain, file, fileShape };
}

/** Access-token entries for the MCP URL in the keychain item and in .credentials.json. */
export function claudeMcpTokens(keys = claudeCredentialKeys()) {
  const pick = (store, shape) =>
    (shape?.mcpOAuth ?? []).filter((e) => e.serverUrl === cfg.mcp && e.hasAccessToken).map((e) => ({ store, key: e.key }));
  return [...pick('keychain', keys.keychain), ...pick('file', keys.fileShape)];
}
