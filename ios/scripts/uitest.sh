#!/usr/bin/env bash
# Run DayDo UI tests on a DD simulator, one xcodebuild at a time.
#
#   ios/scripts/uitest.sh [iphone|ipad|"DD <full simulator name>"] [extra xcodebuild args...]
#   ios/scripts/uitest.sh ipad -only-testing:DayDoUITests/DayDoFlowTests/testCalendar
#
# Codex, agy and other sessions share the DD simulators; two xcodebuild runs at
# once fail at launch with "Failed to send signal 19", so this waits for others.
set -euo pipefail

target="${1:-iphone}"
[[ $# -gt 0 ]] && shift
case "$target" in
  iphone) name="DD iPhone 18 Pro" ;;
  ipad) name="DD iPad Pro 11" ;;
  "DD "*) name="$target" ;;
  *) echo "usage: $0 [iphone|ipad|\"DD <name>\"] [xcodebuild args...]" >&2; exit 2 ;;
esac

udid=$(xcrun simctl list devices available -j | python3 -c '
import json, sys
name = sys.argv[1]
ids = [d["udid"] for ds in json.load(sys.stdin)["devices"].values() for d in ds if d["name"] == name]
print(ids[0] if len(ids) == 1 else "")
' "$name")
if [[ -z "$udid" ]]; then
  echo "找不到唯一一台名為「${name}」的模擬器（xcrun simctl list devices）" >&2
  exit 2
fi

# Match the process name exactly: `pgrep -f` also matches shells whose command line mentions xcodebuild.
# The lock keeps two waiting runs of this script from starting together.
lock="${TMPDIR:-/tmp}/daydo-uitest.lock"
busy() {
  if mkdir "$lock" 2>/dev/null; then
    echo $$ >"$lock/pid"
    if pgrep -x xcodebuild >/dev/null; then rm -rf "$lock"; return 0; fi
    return 1
  fi
  local holder
  holder=$(cat "$lock/pid" 2>/dev/null || true)
  if [[ -n "$holder" ]] && ! kill -0 "$holder" 2>/dev/null; then rm -rf "$lock"; fi
  return 0
}
waited=0
while busy; do
  if (( waited == 0 )); then
    echo "有別的 xcodebuild 在跑，等它結束：" >&2
    pgrep -lx xcodebuild >&2 || echo "（另一個 uitest.sh 持有 $lock）" >&2
  fi
  if (( waited >= 1800 )); then
    echo "等了 30 分鐘仍未結束，放棄" >&2
    exit 3
  fi
  sleep 15
  waited=$((waited + 15))
done

cd "$(dirname "$0")/.."
echo "UI 測試：${name} (${udid})" >&2
trap 'rm -rf "$lock"' EXIT
xcodebuild test -project DayDo.xcodeproj -scheme DayDo \
  -destination "platform=iOS Simulator,id=$udid" \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO "$@"
