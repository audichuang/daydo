#!/usr/bin/env node
// Connects Claude Code to the DayDo MCP server the way a user does, in an empty temp dir:
//   node mcp-login.mjs            .mcp.json + approval → `claude mcp login daydo-verify --no-browser` in tmux
//                                  → ego-browser: authorize page → email → code → consent
//                                  → claude's localhost callback → `claude mcp list` must say Connected
// Needs a bootstrapped device session first (the MCP email path only binds existing accounts).
// Writes the temp dir path to <stateDir>/claude-dir; evidence: mcp-login.pane.txt, mcp-list.txt,
// credential-store.json, authorize-*.png.
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { egoRun } from './ego.mjs';
import { getCode } from './mail-code.mjs';
import { cfg, claudeCredentialKeys, claudeMcpTokens, die, readBoundSession, redact, runDir, saveEvidence, statePath } from './lib.mjs';

const SOCK = cfg.tmuxSocket;
let SESSION = 'trust';
const tmux = (...args) => spawnSync('tmux', ['-L', SOCK, ...args], { encoding: 'utf8' });
const pane = () => tmux('capture-pane', '-p', '-J', '-t', SESSION, '-S', '-500').stdout ?? '';
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const keys = (...k) => tmux('send-keys', '-t', SESSION, ...k);

async function waitPane(pred, timeoutMs, what) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const text = pane();
    const hit = pred(text);
    if (hit) return hit;
    await sleep(500);
  }
  saveEvidence(`mcp-${SESSION}.pane.txt`, pane());
  die(`timed out waiting for ${what}; pane saved to ${runDir()}/mcp-${SESSION}.pane.txt`);
}

/** Runs `cmd` in a fresh tmux session (private socket) inside `cwd`, with CLAUDE_CONFIG_DIR passed through. */
function startPane(name, cwd, cmd) {
  SESSION = name;
  const envArgs = cfg.claudeConfigDir ? ['-e', `CLAUDE_CONFIG_DIR=${cfg.claudeConfigDir}`] : [];
  const r = tmux('new-session', '-d', '-s', name, '-x', '250', '-y', '60', '-c', cwd, ...envArgs, '/bin/sh', '-c', `${cmd}; echo "__EXIT__ $?"; sleep 3600`);
  if (r.status !== 0) die(`tmux new-session ${name} failed: ${r.stderr}`);
}

const env = { ...process.env, ...(cfg.claudeConfigDir && { CLAUDE_CONFIG_DIR: cfg.claudeConfigDir }) };
const mcpGet = (cwd) => spawnSync('claude', ['mcp', 'get', 'daydo-verify'], { cwd, env, encoding: 'utf8', timeout: 60_000 }).stdout ?? '';

// --- preconditions ---------------------------------------------------------
const session = readBoundSession();
if (!session?.meMemberId || !session?.hasData) die('device session missing or not bootstrapped; run device.mjs login && device.mjs bootstrap first', 2);
if (tmux('list-sessions').status === 0) die(`tmux socket ${SOCK} already has sessions; run cleanup.sh first`, 2);
// The keychain entry is keyed by server name + URL, not by directory: an existing token for this URL
// is someone's own "daydo-verify" connection, which this login would overwrite and cleanup would sign out.
let before;
try {
  before = claudeCredentialKeys();
} catch (e) {
  die(`cannot read Claude Code credential stores: ${e.message}`, 2);
}
const existing = claudeMcpTokens(before);
if (existing.length) die(`Claude Code already holds a token for ${cfg.mcp} (${existing.map((e) => `${e.store}:${e.key}`).join(', ')}); refusing to overwrite it. Ask the user, or run cleanup.sh if it is a leftover verify login.`, 2);

// --- temp Claude Code project ------------------------------------------------
const dir = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'daydo-verify-claude.')));
// cleanup.sh and doctor compare this against their own CLAUDE_CONFIG_DIR before touching credentials.
fs.writeFileSync(statePath('claude-config-dir'), `${cfg.claudeConfigDir}\n`);
fs.writeFileSync(statePath('claude-dir'), `${dir}\n`);
fs.writeFileSync(path.join(dir, '.mcp.json'), `${JSON.stringify({ mcpServers: { 'daydo-verify': { type: 'http', url: cfg.mcp } } }, null, 2)}\n`);
fs.mkdirSync(path.join(dir, '.claude'));
fs.writeFileSync(path.join(dir, '.claude/settings.local.json'), `${JSON.stringify({ enabledMcpjsonServers: ['daydo-verify'] }, null, 2)}\n`);

// Whatever happens from here on (die, throw, signal, success), the private tmux server goes away:
// its scrollback holds the unredacted OAuth URL and state.
const killTmux = () => spawnSync('tmux', ['-L', SOCK, 'kill-server'], { stdio: 'ignore' });
process.on('exit', killTmux);
for (const sig of ['SIGINT', 'SIGTERM', 'SIGHUP']) process.on(sig, () => process.exit(130));

// settings.local.json only counts once the folder is trusted: `claude mcp login` in an untrusted
// dir says "awaiting approval". Accept the trust dialog like a user (no prompt is sent), then exit.
try {
  startPane('trust', dir, 'claude');
  const first = await waitPane((t) => (/Yes, I trust this folder/.test(t) ? 'trust' : /needs authentication|Try "/.test(t) ? 'ready' : null), 60_000, 'the trust dialog');
  if (first === 'trust') {
    keys('Down');
    await sleep(300);
    keys('Enter');
    await waitPane((t) => /needs authentication|Try "/.test(t), 60_000, 'claude to start after trust');
  }
  keys('-l', '/exit');
  await sleep(300);
  keys('Enter');
  await waitPane((t) => /__EXIT__/.test(t), 30_000, 'claude to exit');
  saveEvidence('mcp-trust.pane.txt', pane());
  tmux('kill-session', '-t', 'trust');
  const status = mcpGet(dir);
  if (!/Needs authentication|Connected/.test(status)) die(`daydo not approved after trust:\n${status}`);

  startPane('login', dir, 'claude mcp login daydo-verify --no-browser');
  const authUrl = await waitPane((t) => /(https?:\/\/\S+\/authorize\?\S+)/.exec(t)?.[1], 60_000, 'the authorization URL');
  const redirectUri = new URL(authUrl).searchParams.get('redirect_uri');
  console.log(JSON.stringify({ step: 'authorize-url', host: new URL(authUrl).host, redirectUri }));

  // --- browser: login page → email → code page --------------------------------
  const run = runDir();
  const since = Date.now();
  const stage1 = egoRun(
    String.raw`
  const { url, email, shots } = P.args;
  const page = await pageFor('auth');
  await page.goto(url, { timeout: 30000 });
  await page.waitForSelector('form[action="/authorize/email/start"] input[name=email]', { timeout: 20000 });
  await page.screenshot({ path: shots + '/authorize-login.png' });
  await page.fill('form[action="/authorize/email/start"] input[name=email]', email);
  await page.click('form[action="/authorize/email/start"] button[type=submit]', { label: 'send email code' });
  await page.waitForSelector('form[action="/authorize/email/verify"] input[name=code]', { timeout: 20000 });
  await page.screenshot({ path: shots + '/authorize-code.png' });
  emit({ stage: 'code-page', title: await page.title() });
  `,
    { url: authUrl, email: cfg.email, shots: run },
  );
  console.log(JSON.stringify({ step: 'email-sent', ...stage1 }));

  const code = await getCode({ email: cfg.email, since });

  // --- browser: code → consent → approve → localhost callback ------------------
  const stage2 = egoRun(
    String.raw`
  const { code, redirectUri, shots } = P.args;
  const page = await pageFor('auth');
  await page.fill('form[action="/authorize/email/verify"] input[name=code]', code);
  await page.click('form[action="/authorize/email/verify"] button[type=submit]', { label: 'submit email code' });
  await page.waitForSelector('button[name=decision][value=approve]', { timeout: 20000 });
  await page.screenshot({ path: shots + '/authorize-consent.png' });
  const consentText = (await page.evaluate(() => document.body.innerText)).slice(0, 400);
  await page.click('button[name=decision][value=approve]', { label: 'approve DayDo access' });
  await page.waitForURL((u) => String(u).startsWith(redirectUri), { timeout: 20000 }).catch(() => {});
  const finalUrl = await page.url();
  await page.waitForTimeout(1000);
  await page.screenshot({ path: shots + '/authorize-callback.png' }).catch(() => {});
  const callbackText = (await page.evaluate(() => document.body?.innerText ?? '')).slice(0, 300);
  emit({ stage: 'approved', finalUrl, consentText, callbackText });
  `,
    { code, redirectUri, shots: run },
  );
  console.log(JSON.stringify({ step: 'approved', finalUrl: redact(stage2.finalUrl), callbackText: stage2.callbackText }));

  // --- CLI: should exit by itself; otherwise paste the redirected URL ---------
  const exitRe = /__EXIT__ (\d+)/;
  let exit = null;
  for (let i = 0; i < 30 && !exit; i += 1) {
    exit = exitRe.exec(pane());
    if (!exit) await sleep(500);
  }
  let pasted = false;
  if (!exit && stage2.finalUrl.startsWith(redirectUri ?? '\u0000')) {
    // The callback URL carries the OAuth code: load it from stdin, not argv.
    const loaded = spawnSync('tmux', ['-L', SOCK, 'load-buffer', '-b', 'daydo-callback', '-'], { input: stage2.finalUrl, encoding: 'utf8' });
    if (loaded.status !== 0) die(`tmux load-buffer failed: ${loaded.stderr}`);
    tmux('paste-buffer', '-d', '-b', 'daydo-callback', '-t', SESSION);
    tmux('send-keys', '-t', SESSION, 'Enter');
    pasted = true;
    exit = await waitPane((t) => exitRe.exec(t), 30_000, 'claude mcp login to exit after paste');
  }
  saveEvidence('mcp-login.pane.txt', pane());
  tmux('kill-session', '-t', SESSION);
  if (!exit || exit[1] !== '0') die(`claude mcp login exit ${exit?.[1]} (pasted=${pasted}); see mcp-login.pane.txt`);

  // --- confirm -------------------------------------------------------------------
  const list = spawnSync('claude', ['mcp', 'list'], { cwd: dir, env, encoding: 'utf8', timeout: 60_000 });
  saveEvidence('mcp-list.txt', `${list.stdout}\n${list.stderr}`);
  const after = claudeCredentialKeys();
  saveEvidence('credential-store.json', { before, after });
  const line = (list.stdout ?? '').split('\n').find((l) => l.startsWith('daydo-verify'));
  console.log(JSON.stringify({ step: 'mcp-list', pasted, line: line ?? null, claudeDir: dir }));
  if (!line || !/Connected/.test(line)) die(`claude mcp list does not show daydo Connected:\n${list.stdout}`);
} finally {
  killTmux();
}
