#!/usr/bin/env node
// Latest DayDo sign-in code mailed to an address after a timestamp.
//   node mail-code.mjs [--email <addr>] [--since <epoch ms>] [--timeout <s>] [--exclude <code,code>]
//                      [--query <gmail query>] [--pattern <regex with 1 group>]   (dry tests on other mail)
// Prints the 6-digit code on stdout (exit 0), or FAIL on stderr (exit 1).
// Source: DAYDO_CODE_SOURCE=gmail (ego-browser, Gmail account index DAYDO_GMAIL_INDEX) or
// devmail (GET <DAYDO_API>/test/mail, dev builds only).
import { fileURLToPath } from 'node:url';
import { egoRun } from './ego.mjs';
import { cfg, die, parseArgs } from './lib.mjs';

const GMAIL_BODY = String.raw`
const { email, since, timeoutMs, exclude, index, query: baseQuery, pattern } = P.args;
const page = await pageFor('mail');
const query = baseQuery + ' after:' + Math.floor(since / 1000 - 120);
const searchUrl = 'https://mail.google.com/mail/u/' + index + '/#search/' + encodeURIComponent(query);
const deadline = Date.now() + timeoutMs;
let result = null;
let attempts = 0;
while (!result && Date.now() < deadline) {
  attempts += 1;
  // Bounce through the inbox so the same search hash is re-run on every attempt.
  await page.goto('https://mail.google.com/mail/u/' + index + '/#inbox', { timeout: 30000 });
  await page.goto(searchUrl, { timeout: 30000 });
  // Gmail keeps earlier views (the inbox) in the DOM, hidden: only count visible rows, and only
  // once the title says this is the search view.
  await page.waitForFunction(() => {
    if (!/^(搜尋結果|Search results)/.test(document.title)) return false;
    const vis = (el) => el.getClientRects().length > 0;
    return [...document.querySelectorAll('div[role=main] tr.zA')].some(vis)
      || [...document.querySelectorAll('div[role=main]')].some((m) => vis(m) && /找不到與你的搜尋|沒有符合|No messages matched/.test(m.innerText));
  }, undefined, { timeout: 20000 }).catch(() => {});
  const title = await page.title();
  if (!title.toLowerCase().includes(email)) { result = { error: 'gmail account mismatch', title }; break; }
  const rows = await page.evaluate(() => {
    document.querySelectorAll('[data-daydo-verify]').forEach((el) => el.removeAttribute('data-daydo-verify'));
    const row = [...document.querySelectorAll('div[role=main] tr.zA')].find((el) => el.getClientRects().length > 0);
    if (row) row.setAttribute('data-daydo-verify', 'newest');
    return row ? 1 : 0;
  });
  if (rows > 0) {
    await page.click('tr[data-daydo-verify="newest"]', { label: 'open newest code mail' });
    await page.waitForSelector('div[role=main] [data-legacy-message-id]', { timeout: 20000 }).catch(() => {});
    // Legacy message ids are hex with the send time in ms in the bits above 20, per message
    // (the thread id only dates the first message, and every code mail shares one subject).
    const found = await page.evaluate(({ since, exclude, pattern }) => {
      const msgs = [...document.querySelectorAll('div[role=main] [data-legacy-message-id]')].filter((el) => el.getClientRects().length > 0).map((el) => {
        const id = el.getAttribute('data-legacy-message-id');
        const t = Number(BigInt('0x' + id) >> 20n);
        const body = el.querySelector('.a3s')?.innerText ?? '';
        const m = new RegExp(pattern).exec(body);
        return { t, code: m ? m[1] : null };
      });
      const fresh = msgs.filter((m) => m.t >= since - 5000 && m.code && !exclude.includes(m.code)).sort((a, b) => b.t - a.t);
      return fresh[0] ?? null;
    }, { since, exclude, pattern });
    if (found) { result = { code: found.code, msgTime: found.t, attempts }; break; }
  }
  await page.waitForTimeout(5000);
}
emit(result ?? { error: 'timed out waiting for the code mail', attempts });
`;

const DAYDO_QUERY = 'in:anywhere from:no-reply@audichuang.app subject:"你的 DayDo 驗證碼"';
const DAYDO_PATTERN = '驗證碼[：:]\\s*(\\d{6})';

export async function getCode({ email = cfg.email, since, timeoutMs = 120_000, exclude = [], query = DAYDO_QUERY, pattern = DAYDO_PATTERN } = {}) {
  if (cfg.codeSource === 'devmail') {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      const res = await fetch(`${cfg.api}/test/mail?to=${encodeURIComponent(email)}`);
      if (res.ok) {
        const body = await res.json();
        if (/^\d{6}$/.test(body.code ?? '') && !exclude.includes(body.code)) return body.code;
      }
      await new Promise((r) => setTimeout(r, 1000));
    }
    throw new Error(`no dev mail code for ${email}`);
  }
  const result = egoRun(GMAIL_BODY, { email, since, timeoutMs, exclude, index: cfg.gmailIndex, query, pattern }, { timeoutMs: timeoutMs + 90_000 });
  if (!result?.code) throw new Error(`gmail: ${JSON.stringify(result)}`);
  return result.code;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const a = parseArgs(process.argv.slice(2));
  try {
    const code = await getCode({
      email: (a.email ?? cfg.email).toLowerCase(),
      since: a.since ? Number(a.since) : Date.now() - 10 * 60_000,
      timeoutMs: (a.timeout ? Number(a.timeout) : 120) * 1000,
      exclude: typeof a.exclude === 'string' ? a.exclude.split(',') : [],
      ...(typeof a.query === 'string' && { query: a.query }),
      ...(typeof a.pattern === 'string' && { pattern: a.pattern }),
    });
    console.log(code);
  } catch (e) {
    die(e.message);
  }
}
