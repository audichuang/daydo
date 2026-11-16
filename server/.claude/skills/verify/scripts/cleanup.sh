#!/usr/bin/env bash
# Tears down what a verify run created; evidence in <state>/<run>/ is never touched.
#   bash cleanup.sh [--keep-probe] [--keep-session]
#   1. soft-deletes live "verify-probe*" tasks in verify-seed (device op, LWW-safe)   [--keep-probe skips]
#   2. `claude mcp logout daydo-verify` in the temp dir, then checks the keychain entry is gone
#   3. removes the temp dir recorded in <state>/claude-dir (only daydo-verify-claude.* paths)
#   4. kills the private tmux socket daydo-verify (never other tmux servers)
#   5. finishes the recorded ego-browser TaskSpace with keep: [] (user tabs are protected)
#   6. deletes the device session file (tokens)                                        [--keep-session skips]
# The verify-seed project and the account stay (there is no delete-account endpoint).
# macOS bash 3.2 compatible.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="$HERE/lib.mjs"
keep_probe=0; keep_session=0
for a in "$@"; do
  case "$a" in
    --keep-probe) keep_probe=1 ;;
    --keep-session) keep_session=1 ;;
    *) echo "usage: cleanup.sh [--keep-probe] [--keep-session]"; exit 2 ;;
  esac
done
js() { node --input-type=module -e "import * as L from '$LIB'; $1"; }
STATE="$(js 'console.log(L.cfg.stateDir)')"
RUN="$(js 'console.log(L.runDir())')"
rc=0

if [ "$keep_probe" = 0 ]; then
  if [ -n "$(js 'import("node:fs").then((fs) => console.log(fs.existsSync(L.sessionFile()) ? 1 : ""))')" ]; then
    node "$HERE/device.mjs" delete-probes || rc=1
    node "$HERE/device.mjs" pull --label after-cleanup >/dev/null || rc=1
  else
    echo "skip  delete-probes: no device session"
  fi
fi

DIR=""
[ -f "$STATE/claude-dir" ] && DIR="$(cat "$STATE/claude-dir")"
if [ -n "$DIR" ] && [ -d "$DIR" ]; then
  (cd "$DIR" && claude mcp logout daydo-verify) 2>&1 | tee -a "$RUN/cleanup.txt"
  js '
    const mine = (L.claudeCredentialKeys().keychain?.mcpOAuth ?? []).filter((e) => e.serverUrl === L.cfg.mcp && e.hasAccessToken);
    if (mine.length) { console.log(`FAIL  keychain still holds a token for ${L.cfg.mcp}: ${mine.map((e) => e.key).join(", ")}`); process.exit(1); }
    console.log(`ok    no Claude Code token left for ${L.cfg.mcp}`);
  ' | tee -a "$RUN/cleanup.txt" || rc=1
  case "$DIR" in
    */daydo-verify-claude.*) rm -rf "$DIR" && echo "ok    removed $DIR" ;;
    *) echo "FAIL  refusing to remove unexpected dir $DIR"; rc=1 ;;
  esac
  rm -f "$STATE/claude-dir"
else
  echo "skip  no Claude temp dir recorded"
fi

if tmux -L daydo-verify list-sessions >/dev/null 2>&1; then
  tmux -L daydo-verify kill-server && echo "ok    killed tmux socket daydo-verify"
fi

js '
  const { egoFinish } = await import("'"$HERE"'/ego.mjs");
  const r = egoFinish();
  console.log(`${r.finished || r.reason === "no space recorded" || r.reason === "space already gone" ? "ok   " : "FAIL "} ego-browser: ${JSON.stringify(r)}`);
' || rc=1

if [ "$keep_session" = 0 ]; then node "$HERE/device.mjs" forget; fi

echo "evidence kept in $RUN:"
ls "$RUN"
exit $rc
