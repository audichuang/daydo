#!/usr/bin/env bash
# Run one DayDo UI test while recording the simulator screen, to check animations frame by frame.
#
#   ios/scripts/record-uitest.sh [iphone|ipad|"DD <name>"] <Class/testMethod> <output prefix>
#   ios/scripts/record-uitest.sh iphone DayDoFlowTests/testCalendarHorizontalSwipeChangesMonth /tmp/dd-rec/cal
#
# Writes <prefix>.mp4 and <prefix>.log. Screenshots from shot() land after the animation settles, so they
# cannot prove a transition happened; extract frames instead, e.g.
#   ffmpeg -ss 20 -t 1.5 -i <prefix>.mp4 -vf "fps=15,scale=240:-1,tile=8x3" -frames:v 1 <prefix>-frames.png
#
# Handshake with uitest.sh through a fresh directory per run (DD_UITEST_HANDSHAKE_DIR): uitest.sh
# writes `udid` once it holds the lease and the device is booted, and starts xcodebuild only after
# `go`; this writes `recorder.pid`, then `go` once recording has started. After the run uitest.sh
# writes `done`; this stops recordVideo, waits for it to exit and writes `stopped`, and only then
# does uitest.sh drop the lease. Both sides give up when the other one dies.
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "usage: $0 [iphone|ipad|\"DD <name>\"] <Class/testMethod> <output prefix>" >&2
  exit 2
fi
target="$1"; test_id="$2"; out="$3"
here="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$(dirname "$out")"
hs=$(mktemp -d "${TMPDIR:-/tmp}/dd-record.XXXXXX")

DD_UITEST_HANDSHAKE_DIR="$hs" "$here/uitest.sh" "$target" "-only-testing:DayDoUITests/$test_id" \
  >"$out.log" 2>&1 &
test_pid=$!
rec_pid=""

alive() { [[ -n "$1" ]] && kill -0 "$1" 2>/dev/null; }
stop_recorder() {
  if alive "$rec_pid"; then
    kill -INT "$rec_pid" 2>/dev/null || true
    local waited=0
    while alive "$rec_pid" && (( waited < 300 )); do sleep 0.1; waited=$((waited + 1)); done
    if alive "$rec_pid"; then
      echo "recordVideo 30 秒內沒有結束，強制停止（影片可能不完整）" >&2
      kill -KILL "$rec_pid" 2>/dev/null || true
    fi
  fi
  if [[ -n "$rec_pid" ]]; then wait "$rec_pid" 2>/dev/null || true; fi
  : >"$hs/stopped"
}
# shellcheck disable=SC2329 # run by the EXIT trap
cleanup() {
  local rc=$?
  trap - EXIT INT TERM HUP
  stop_recorder
  if alive "$test_pid"; then wait "$test_pid" 2>/dev/null || true; fi
  rm -rf "$hs"
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

finish_test() {
  local rc=0
  wait "$test_pid" || rc=$?
  grep -E "Executed|TEST (SUCCEEDED|FAILED)" "$out.log" | tail -2 || true
  echo "video: $out.mp4  log: $out.log  test rc=$rc" >&2
  exit "$rc"
}

# uitest.sh may queue behind other runs for a long time; it has its own timeouts.
until [[ -e "$hs/udid" ]]; do
  if ! alive "$test_pid"; then
    echo "uitest.sh 在拿到模擬器前就結束了" >&2
    finish_test
  fi
  sleep 0.5
done
udid=$(cat "$hs/udid")

# A background job of a non-interactive bash starts with SIGINT ignored, and SIGINT is how
# recordVideo is told to finish the file; restore the default before exec.
python3 -I -c 'import os, signal, sys; signal.signal(signal.SIGINT, signal.SIG_DFL); os.execvp(sys.argv[1], sys.argv[1:])' \
  xcrun simctl io "$udid" recordVideo --codec h264 --force "$out.mp4" >"$hs/rec.log" 2>&1 &
rec_pid=$!
printf '%s\n' "$rec_pid" >"$hs/recorder.pid"

# recordVideo prints "Recording started" once frames flow; if this Xcode prints nothing,
# still alive after the grace period counts as started.
waited=0
until grep -q "Recording started" "$hs/rec.log" 2>/dev/null || (( waited >= 50 )); do
  if ! alive "$rec_pid"; then break; fi
  sleep 0.1
  waited=$((waited + 1))
done
if ! alive "$rec_pid"; then
  echo "recordVideo 沒有啟動：$(cat "$hs/rec.log" 2>/dev/null)" >&2
  finish_test
fi
: >"$hs/go"

until [[ -e "$hs/done" ]] || ! alive "$test_pid"; do sleep 0.2; done
stop_recorder
finish_test
