#!/usr/bin/env bash
# Local stand-in for dry runs: the server at a git ref, exported (never the working tree) to
# /tmp/daydo-verify-devsrv and run as a dev build (MCP_HOST=localhost, Access off, /test/mail on).
#   bash devserver.sh up [<ref>]   default ref: HEAD of the repo this skill lives in
#   bash devserver.sh down
# Then drive it with:
#   export DAYDO_API=http://127.0.0.1:8787 DAYDO_MCP=http://localhost:8787/ DAYDO_CODE_SOURCE=devmail \
#          DAYDO_VERIFY_STATE=$HOME/.local/state/daydo-verify-dryrun
# The stand-in skips: Cloudflare Access, real mail delivery + Gmail, production D1/DO data.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
DIR=/tmp/daydo-verify-devsrv
PORT=8787
SOCK=daydo-devsrv
REPO="${DAYDO_REPO:-$(git -C "$HERE" rev-parse --show-toplevel 2>/dev/null)}"

case "${1:-}" in
  up)
    REF="${2:-HEAD}"
    [ -n "$REPO" ] || { echo "FAIL  set DAYDO_REPO to the DayDo checkout"; exit 2; }
    if tmux -L "$SOCK" has-session -t srv 2>/dev/null; then echo "FAIL  already up (bash devserver.sh down)"; exit 2; fi
    rm -rf "$DIR" && mkdir -p "$DIR"
    git -C "$REPO" archive "$REF" server spec | tar -x -C "$DIR" || exit 1
    if [ -d "$REPO/server/node_modules" ]; then
      cp -Rc "$REPO/server/node_modules" "$DIR/server/node_modules" 2>/dev/null || cp -R "$REPO/server/node_modules" "$DIR/server/node_modules"
      rm -rf "$DIR/server/node_modules/.vite" "$DIR/server/node_modules/.vite-temp" "$DIR/server/node_modules/.vitest-cache" "$DIR/server/node_modules/.mf"
    else
      (cd "$DIR/server" && npm ci --no-audit --no-fund) || exit 1
    fi
    SECRET="dryrun-local-jwt-secret-$(openssl rand -hex 16)"
    (cd "$DIR/server" && JWT_SECRET="$SECRET" MCP_HOST=localhost ./node_modules/.bin/void db migrate) || exit 1
    tmux -L "$SOCK" new-session -d -s srv -x 200 -y 50 -c "$DIR/server" \
      -e JWT_SECRET="$SECRET" -e MCP_HOST=localhost \
      /bin/sh -c "./node_modules/.bin/vite --port $PORT --host 127.0.0.1 --strictPort > $DIR/vite.log 2>&1"
    i=0
    until curl -sf "http://127.0.0.1:$PORT/health" >/dev/null; do
      i=$((i + 1)); [ $i -gt 120 ] && { echo "FAIL  not ready; see $DIR/vite.log"; exit 1; }
      sleep 0.5
    done
    curl -sf "http://localhost:$PORT/" >/dev/null || { echo "FAIL  MCP host gate (localhost) not serving /"; exit 1; }
    echo "ok    dev server $(git -C "$REPO" rev-parse --short "$REF") on http://127.0.0.1:$PORT (API) and http://localhost:$PORT/ (MCP)"
    ;;
  down)
    tmux -L "$SOCK" kill-server 2>/dev/null && echo "ok    stopped dev server"
    rm -rf "$DIR" && echo "ok    removed $DIR"
    ;;
  *) echo "usage: devserver.sh up [<ref>] | down"; exit 2 ;;
esac
