#!/bin/bash
# Drive the DayDo Mac (Catalyst) Debug build of THIS worktree for verification.
# Usage: mac.sh build | launch [screen|signin] [WxH] | doctor | size WxH | shot <name> | evidence | cleanup
set -euo pipefail

# The worktree this script lives in, whatever the caller's cwd.
ROOT="$(cd "$(dirname "$0")/../../../../.." && pwd)"
MAIN="$(git -C "$ROOT" worktree list --porcelain | awk 'NR==1{print $2}')"
BASE="${DAYDO_MAC_VERIFY_STATE:-$HOME/.local/state/daydo-verify-mac}"
STATE="$BASE/$(printf '%s' "$ROOT" | shasum | cut -c1-10)"
mkdir -p "$STATE"

# Identity of a built executable: inode + mtime change on every rebuild.
fingerprint() { stat -f '%i-%m' "$1"; }

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
    "$ROOT/ios/scripts/uitest.sh" mac >"$STATE/build.log" 2>&1 || { tail -20 "$STATE/build.log"; die "build failed (log: $STATE/build.log)"; }
    # Stamp the build, not the binary: a comment-only edit compiles to identical objects and Xcode skips relinking.
    touch "$STATE/built"
    app_path ;;
  launch)
    screen="${2:-}"; size="${3:-1400x900}"
    # Every worktree's Debug build shares one data dir and preference suite, so -DayDoReset here
    # would wipe another worktree's running instance: allow one Debug instance machine-wide.
    # mkdir is atomic: two concurrent launches cannot both pass the check below and claim one pid.
    mkdir "$BASE/launch.lock" 2>/dev/null || die "another mac.sh launch is in progress (remove $BASE/launch.lock if none is)"
    trap 'rmdir "$BASE/launch.lock" 2>/dev/null || true' EXIT
    other="$(pgrep -fl "Library/Developer/Xcode/DerivedData/DayDo-.*/DayDo.app/Contents/MacOS/DayDo" || true)"
    [ -z "$other" ] || die "a DayDo Debug build is already running (shared data dir): $other; stop it (mac.sh cleanup in its worktree) first"
    app="$(app_path)" || die "no Mac build for this worktree; run: mac.sh build"
    before="$(pgrep -f "$app/Contents/MacOS/DayDo" || true)"
    if [ "$screen" = signin ]; then
      args=(-DayDoReset)
    else
      args=(-DayDoReset -DayDoSkipLogin -DayDoDemo)
      [ -n "$screen" ] && args+=(-DayDoScreen "$screen")
    fi
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
    fingerprint "$app/Contents/MacOS/DayDo" >"$STATE/fingerprint"
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
    [ -f "$STATE/built" ] || die "FAIL no mac.sh build recorded for this worktree; run: mac.sh build"
    newest="$(find "$ROOT/ios/DayDo" "$ROOT/DayDoCore/Sources" -name '*.swift' -newer "$STATE/built" -print -quit)"
    [ -z "$newest" ] || die "FAIL $newest changed after the last mac.sh build; run: mac.sh build"
    pid="$(our_pid || true)"
    [ -n "$pid" ] || die "FAIL no running instance started by this worktree; run: mac.sh launch"
    [ "$(fingerprint "$bin")" = "$(cat "$STATE/fingerprint" 2>/dev/null)" ] || die "FAIL running pid $pid predates the current build; run: mac.sh cleanup && mac.sh launch"
    echo "OK pid=$pid build=$app (built after every source change, running the current binary)" ;;
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
    if [ -f "$STATE/evidence" ]; then echo "evidence kept at $(cat "$STATE/evidence")"; fi ;;
  *) sed -n 2,3p "$0"; exit 2 ;;
esac
