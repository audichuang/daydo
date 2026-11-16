#!/usr/bin/env bash
# Read-only health check: is this DayDo target worth driving?
#   bash doctor.sh [--new-run]
# --new-run starts a fresh evidence dir (<state>/<UTC timestamp>/) and makes it current.
# Exit 0 when every check passes; each failing check prints FAIL and the exit code is 1.
# macOS bash 3.2 compatible (no associative arrays, no ${var,,}).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="$HERE/lib.mjs"
fails=0
ok()   { printf 'ok    %s\n' "$*"; }
bad()  { printf 'FAIL  %s\n' "$*"; fails=$((fails + 1)); }
info() { printf 'info  %s\n' "$*"; }

js() { node --input-type=module -e "import * as L from '$LIB'; $1"; }

if [ "${1:-}" = "--new-run" ]; then
  info "run: $(js 'console.log(L.newRunId())')"
fi
# Keep a copy of this report with the run's evidence.
RUN="$(js 'console.log(L.runDir())')"
exec > >(tee -a "$RUN/doctor.txt") 2>&1
js 'const c = L.cfg; console.log(`info  api=${c.api} mcp=${c.mcp} email=${c.email} codeSource=${c.codeSource} state=${c.stateDir} run=${L.runDir()} CLAUDE_CONFIG_DIR=${c.claudeConfigDir || "(default ~/.claude)"}`)'

for t in node claude tmux ego-browser; do
  if command -v "$t" >/dev/null 2>&1; then ok "$t: $(command -v "$t")"; else bad "$t not on PATH"; fi
done
command -v claude >/dev/null 2>&1 && info "claude $(claude --version 2>/dev/null)"

# MCP host: GET / is the protected-resource metadata for its own origin.
js '
const origin = new URL(L.cfg.mcp).origin;
try {
  const r = await fetch(L.cfg.mcp);
  const b = await r.json();
  if (r.status === 200 && b.resource === origin && b.authorization_servers?.[0] === origin) console.log(`ok    MCP ${origin} metadata (server ${b.server?.name} ${b.server?.version}, protocol ${b.protocol})`);
  else { console.log(`FAIL  MCP ${origin}: ${r.status} ${JSON.stringify(b).slice(0, 200)}`); process.exitCode = 1; }
} catch (e) { console.log(`FAIL  MCP ${origin}: ${e.message}`); process.exitCode = 1; }
' || fails=$((fails + 1))

# API host: /health 200 with Access headers; in production also 401/403 without them.
js '
try {
  const r = await L.apiRequest("GET", "/health");
  if (r.status === 200 && r.data?.ok === true) console.log(`ok    API ${L.cfg.api}/health 200${L.isProdApi() ? " (with Access service token from 1Password)" : ""}`);
  else { console.log(`FAIL  API /health: ${r.status} ${JSON.stringify(r.data).slice(0, 200)}`); process.exitCode = 1; }
  if (L.isProdApi()) {
    const bare = await fetch(`${L.cfg.api}/health`, { redirect: "manual" });
    if (bare.status === 401 || bare.status === 403 || bare.status === 302) console.log(`ok    API without Access token is rejected (${bare.status})`);
    else { console.log(`FAIL  API without Access token returned ${bare.status}`); process.exitCode = 1; }
  }
} catch (e) { console.log(`FAIL  API /health: ${e.message.split("\n")[0]}`); process.exitCode = 1; }
' || fails=$((fails + 1))

# Code source: Gmail account in ego-browser (title must name the address) or the dev mailbox.
js '
if (L.cfg.codeSource === "devmail") {
  const r = await fetch(`${L.cfg.api}/test/mail?to=doctor@example.com`).catch((e) => ({ status: e.message }));
  if (r.status === 404 || r.status === 200) console.log(`ok    dev mailbox reachable (${r.status})`);
  else { console.log(`FAIL  dev mailbox: ${r.status} (DAYDO_CODE_SOURCE=devmail needs a dev build)`); process.exitCode = 1; }
} else {
  const { egoRun } = await import("'"$HERE"'/ego.mjs");
  try {
    const r = egoRun(`
      const page = await pageFor("mail");
      await page.goto("https://mail.google.com/mail/u/" + P.args.index + "/#inbox", { timeout: 30000 });
      await page.waitForFunction(() => /Gmail/.test(document.title), undefined, { timeout: 20000 }).catch(() => {});
      emit({ title: await page.title() });`, { index: L.cfg.gmailIndex }, { timeoutMs: 90000 });
    if (String(r.title).toLowerCase().includes(L.cfg.email)) console.log(`ok    ego-browser Gmail u/${L.cfg.gmailIndex}: ${r.title}`);
    else { console.log(`FAIL  ego-browser Gmail u/${L.cfg.gmailIndex} title "${r.title}" does not name ${L.cfg.email}`); process.exitCode = 1; }
  } catch (e) { console.log(`FAIL  ego-browser: ${e.message.split("\n")[0]}`); process.exitCode = 1; }
}
' || fails=$((fails + 1))

# 1Password service account (production only).
if js 'process.exit(L.isProdApi() ? 0 : 1)'; then
  if (set -a; . "$HOME/.config/op/agent-sa.env"; set +a; op whoami >/dev/null 2>&1); then ok "op service account"; else bad "op service account (agent-sa.env)"; fi
fi

# Leftovers from an earlier run (informational unless they block a new run).
if tmux -L daydo-verify list-sessions >/dev/null 2>&1; then bad "tmux socket daydo-verify still has sessions (run cleanup.sh)"; else ok "tmux socket daydo-verify free"; fi
js '
import("node:fs").then((fs) => {
  const p = L.statePath("claude-dir");
  const d = fs.existsSync(p) ? fs.readFileSync(p, "utf8").trim() : "";
  console.log(d && fs.existsSync(d) ? `info  previous Claude temp dir still present: ${d}` : "ok    no leftover Claude temp dir");
  const keys = L.claudeCredentialKeys();
  const mine = (keys.keychain?.mcpOAuth ?? []).filter((e) => e.serverUrl === L.cfg.mcp);
  if (mine.some((e) => e.hasAccessToken)) {
    console.log(`FAIL  Claude Code already holds a token for ${L.cfg.mcp} (shared by name+URL across directories; mcp-login would overwrite it and cleanup would sign it out). Leftover verify login: cleanup.sh. Otherwise ask the user.`);
    process.exitCode = 1;
  }
  console.log(`info  Claude credentials: keychain "${keys.service}" has ${mine.length} entr${mine.length === 1 ? "y" : "ies"} for ${L.cfg.mcp}${mine.length ? " (" + mine.map((e) => e.key + (e.hasAccessToken ? " token" : " no-token")).join(", ") + ")" : ""}`);
});
' || fails=$((fails + 1))
node "$HERE/device.mjs" status | sed 's/^/info  device /'

if [ "$fails" -gt 0 ]; then echo "doctor: $fails check(s) failed"; exit 1; fi
echo "doctor: all checks passed"
