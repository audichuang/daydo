#!/bin/bash
# Drive the DayDo Mac (Catalyst) Debug build of THIS worktree for verification.
# Usage: mac.sh build | launch [screen] [WxH] | doctor | size WxH | shot <name> | evidence | cleanup
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
MAIN="$(git -C "$ROOT" worktree list --porcelain | awk 'NR==1{print $2}')"
STATE="${DAYDO_MAC_VERIFY_STATE:-$HOME/.local/state/daydo-verify-mac}/$(printf '%s' "$ROOT" | shasum | cut -c1-10)"
mkdir -p "$STATE"

die() { echo "mac.sh: $*" >&2; exit 1; }

# The .app built from this worktree: DerivedData records the workspace it belongs to.
app_path() {
  local d
  for d in "$HOME"/Library/Developer/Xcode/DerivedData/DayDo-*; do
    [ -f "$d/info.plist" ] || continue
    if plutil -extract WorkspacePath raw "$d/info.plist" 2>/dev/null | grep -qx "$ROOT/ios/DayDo.xcodeproj"; then
      local a="$d/Build/Products/Debug-maccatalyst/DayDo.app"
      [ -d "$a" ] && { echo "$a"; return 0; }
    fi
  done
  return 1
}

our_pid() {
  [ -f "$STATE/pid" ] || return 1
  local pid; pid="$(cat "$STATE/pid")"
  # Same pid AND same executable: never touch the brew-installed DayDo or another worktree's build.
  ps -o comm= -p "$pid" 2>/dev/null | grep -q "^$(cat "$STATE/app")/Contents/MacOS/DayDo$" && echo "$pid"
}

set_size() {
  local w="${1%x*}" h="${1#*x}"
  osascript -e "tell application \"System Events\" to tell (first process whose unix id is $(our_pid)) to set position of window 1 to {0, 30}" \
            -e "tell application \"System Events\" to tell (first process whose unix id is $(our_pid)) to set size of window 1 to {$w, $h}" >/dev/null
}

case "${1:-}" in
  build)
    heavy -- "$ROOT/ios/scripts/uitest.sh" mac >"$STATE/build.log" 2>&1 || { tail -20 "$STATE/build.log"; die "build failed (log: $STATE/build.log)"; }
    git -C "$ROOT" checkout -q DayDoCore/Package.resolved 2>/dev/null || true
    app_path ;;
  launch)
    screen="${2:-}"; size="${3:-1400x900}"
    [ -z "$(our_pid || true)" ] || die "an instance from this worktree is already running (pid $(our_pid)); run cleanup first"
    app="$(app_path)" || die "no Mac build for this worktree; run: mac.sh build"
    before="$(pgrep -f "$app/Contents/MacOS/DayDo" || true)"
    args=(-DayDoReset -DayDoSkipLogin -DayDoDemo)
    [ -n "$screen" ] && args+=(-DayDoScreen "$screen")
    open -n "$app" --args "${args[@]}"
    pid=""
    for _ in $(seq 1 40); do
      for p in $(pgrep -f "$app/Contents/MacOS/DayDo" || true); do
        echo "$before" | grep -qx "$p" || pid="$p"
      done
      [ -n "$pid" ] && break; sleep 0.25
    done
    [ -n "$pid" ] || die "app did not start"
    echo "$pid" >"$STATE/pid"; echo "$app" >"$STATE/app"
    # Ready = the main window exists (System Events sees it), not just a live process.
    for _ in $(seq 1 40); do
      n="$(osascript -e "tell application \"System Events\" to count windows of (first process whose unix id is $pid)" 2>/dev/null || echo 0)"
      [ "$n" -ge 1 ] && break; sleep 0.25
    done
    set_size "$size"
    echo "pid=$pid app=$app size=$size" ;;
  doctor)
    app="$(app_path)" || die "FAIL no Mac build for $ROOT; run: mac.sh build"
    bin="$app/Contents/MacOS/DayDo"
    newest="$(find "$ROOT/ios/DayDo" "$ROOT/DayDoCore/Sources" -name '*.swift' -newer "$bin" | head -1)"
    [ -z "$newest" ] || die "FAIL build is older than $newest; run: mac.sh build"
    pid="$(our_pid || true)"
    [ -n "$pid" ] || die "FAIL no running instance started by this worktree; run: mac.sh launch"
    echo "OK pid=$pid build=$app (newer than every source file)" ;;
  size) set_size "${2:?WxH}"; echo "size=$2" ;;
  evidence)
    run="${DAYDO_VERIFY_RUN:-$(date +%Y%m%d-%H%M%S)}"
    dir="$MAIN/.agent-work/verify/$run"; mkdir -p "$dir"; echo "$dir" >"$STATE/evidence"; echo "$dir" ;;
  shot)
    name="${2:?name}"; dir="$(cat "$STATE/evidence" 2>/dev/null)" || die "run: mac.sh evidence first"
    pid="$(our_pid)" || die "not running"
    b="$(osascript -e "tell application \"System Events\" to tell (first process whose unix id is $pid) to get {position, size} of window 1" | tr -d ' ')"
    IFS=, read -r x y w h <<<"$b"
    screencapture -x -R"$x,$y,$w,$h" "$dir/$name.png"; echo "$dir/$name.png" ;;
  cleanup)
    pid="$(our_pid || true)"
    if [ -n "$pid" ]; then kill "$pid"; echo "stopped pid $pid"; else echo "nothing of ours running"; fi
    rm -f "$STATE/pid"
    git -C "$ROOT" checkout -q DayDoCore/Package.resolved 2>/dev/null || true
    [ -f "$STATE/evidence" ] && echo "evidence kept at $(cat "$STATE/evidence")" ;;
  *) sed -n 2,3p "$0"; exit 2 ;;
esac
