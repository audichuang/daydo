#!/usr/bin/env bash
# Tears down what a verify run created; evidence in <state>/<run>/ is never touched.
#   bash cleanup.sh [--keep-probe] [--keep-session]
#   1. permanently deletes (purges, op=delete) probe tasks recorded in this target's probe ledger
#      (verified by existence, prefix, and account ownership); R2 cleanup is best-effort because
#      GET 404 after purge cannot prove R2 deletion (purged tasks return 404 before reading R2).
#      Fails if session is missing while pending ledger entries remain.         [--keep-probe skips]
#   2. `claude mcp logout daydo-verify` in the temp dir, then checks the keychain entry is gone
#   3. removes the temp dir recorded in <state>/claude-dir (only daydo-verify-claude.* paths)
#   4. kills the private tmux socket daydo-verify (never other tmux servers)
#   5. finishes the recorded ego-browser TaskSpace with keep: [] (user tabs are protected)
#   6. deletes the device session file (kept if step 1 failed so purge can retry) [--keep-session skips]
# The verify-seed project and the account stay (there is no delete-account endpoint).
# Steps 2-3 fail closed: if logout fails, a token remains, or CLAUDE_CONFIG_DIR differs from the one
# mcp-login recorded (<state>/claude-config-dir), the temp dir and pointers are kept and the exit code is 1.
# macOS bash 3.2 compatible.
set -u -o pipefail
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
purge_failed=0

if [ "$keep_probe" = 0 ]; then
  if [ -n "$(js 'import("node:fs").then((fs) => console.log(fs.existsSync(L.sessionFile()) ? 1 : ""))')" ]; then
    if node "$HERE/device.mjs" purge-probes; then
      rm -f "$STATE/attachment-probe.json"
      node "$HERE/device.mjs" pull --label after-cleanup >/dev/null || rc=1
    else
      echo "FAIL  purge-probes failed; keeping device session and probe ledger for retry"
      purge_failed=1
      rc=1
    fi
  else
    js '
      const pending = L.pendingProbeLedgersForApi();
      if (pending.length) {
        console.log(`FAIL  no device session, but probe ledger still has pending probe(s): ${pending.map((p) => `${p.file} (${p.count})`).join(", ")}`);
        process.exit(1);
      }
      console.log("skip  purge-probes: no device session and no pending probes");
    ' || { purge_failed=1; rc=1; }
  fi
else
  echo "skip  purge-probes: --keep-probe"
fi

DIR=""
[ -f "$STATE/claude-dir" ] && DIR="$(cat "$STATE/claude-dir")"
if [ -n "$DIR" ] && [ -d "$DIR" ]; then
  # Any failure below keeps the temp dir and the pointers, so a leftover login can still be found and retried.
  keep=0
  if [ ! -f "$STATE/claude-config-dir" ]; then
    echo "FAIL  no recorded CLAUDE_CONFIG_DIR next to the claude-dir pointer (older run?); not touching credentials. Log out by hand, then remove $STATE/claude-dir"
    keep=1
  else
    RECORDED_CFG="$(cat "$STATE/claude-config-dir")"
    CURRENT_CFG="$(js 'console.log(L.cfg.claudeConfigDir)')"
    if [ "$RECORDED_CFG" != "$CURRENT_CFG" ]; then
      echo "FAIL  CLAUDE_CONFIG_DIR mismatch: login used '${RECORDED_CFG:-(default ~/.claude)}', this shell has '${CURRENT_CFG:-(default ~/.claude)}'; rerun with the recorded one"
      keep=1
    fi
  fi
  if [ "$keep" = 0 ]; then
    (cd "$DIR" && claude mcp logout daydo-verify) 2>&1 | tee -a "$RUN/cleanup.txt" || { echo "FAIL  claude mcp logout daydo-verify failed"; keep=1; }
    js '
      const mine = L.claudeMcpTokens();
      if (mine.length) { console.log(`FAIL  Claude Code still holds a token for ${L.cfg.mcp}: ${mine.map((e) => `${e.store}:${e.key}`).join(", ")}`); process.exit(1); }
      console.log(`ok    no Claude Code token left for ${L.cfg.mcp}`);
    ' 2>&1 | tee -a "$RUN/cleanup.txt" || keep=1
  fi
  if [ "$keep" = 0 ]; then
    case "$DIR" in
      */daydo-verify-claude.*) rm -rf "$DIR" && echo "ok    removed $DIR" && rm -f "$STATE/claude-dir" "$STATE/claude-config-dir" || { echo "FAIL  could not remove $DIR"; rc=1; } ;;
      *) echo "FAIL  refusing to remove unexpected dir $DIR"; rc=1 ;;
    esac
  else
    echo "FAIL  kept $DIR and the pointers in $STATE for a retry"
    rc=1
  fi
else
  echo "skip  no Claude temp dir recorded"
fi

if tmux -L daydo-verify list-sessions >/dev/null 2>&1; then
  tmux -L daydo-verify kill-server && echo "ok    killed tmux socket daydo-verify"
else
  echo "skip  tmux socket daydo-verify not running"
fi

js '
  const { egoFinish } = await import("'"$HERE"'/ego.mjs");
  const r = egoFinish();
  const ok = r.finished || r.reason === "no space recorded" || r.reason === "space already gone" || String(r.reason).startsWith("recorded space is not ours");
  console.log(`${ok ? "ok   " : "FAIL "} ego-browser: ${JSON.stringify(r)}`);
  if (!ok) process.exit(1);
' || rc=1

if [ "$keep_session" = 0 ]; then
  if [ "$purge_failed" = 0 ]; then
    node "$HERE/device.mjs" forget
  else
    echo "skip  forget device session: kept so purge-probes can be retried"
  fi
fi

echo "evidence kept in $RUN:"
ls "$RUN"
exit $rc
