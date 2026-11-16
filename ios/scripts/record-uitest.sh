#!/usr/bin/env bash
# Run one DayDo UI test while recording the simulator screen, to check animations frame by frame.
#
#   ios/scripts/record-uitest.sh [iphone|ipad|"DD <name>"] <Class/testMethod> <output prefix>
#   ios/scripts/record-uitest.sh iphone DayDoFlowTests/testCalendarHorizontalSwipeChangesMonth /tmp/dd-rec/cal
#
# Writes <prefix>.mp4 and <prefix>.log. Screenshots from shot() land after the animation settles, so they
# cannot prove a transition happened; extract frames instead, e.g.
#   ffmpeg -ss 20 -t 1.5 -i <prefix>.mp4 -vf "fps=15,scale=240:-1,tile=8x3" -frames:v 1 <prefix>-frames.png
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "usage: $0 [iphone|ipad|\"DD <name>\"] <Class/testMethod> <output prefix>" >&2
  exit 2
fi
target="$1"; test_id="$2"; out="$3"
case "$target" in
  iphone) name="DD iPhone 18 Pro" ;;
  ipad) name="DD iPad Pro 11" ;;
  "DD "*) name="$target" ;;
  *) echo "unknown device: $target" >&2; exit 2 ;;
esac
udid=$(xcrun simctl list devices available -j | python3 -c '
import json, sys
ids = [d["udid"] for ds in json.load(sys.stdin)["devices"].values() for d in ds if d["name"] == sys.argv[1]]
print(ids[0] if len(ids) == 1 else "")
' "$name")
[[ -n "$udid" ]] || { echo "找不到唯一一台名為「${name}」的模擬器" >&2; exit 2; }
mkdir -p "$(dirname "$out")"

here="$(cd "$(dirname "$0")" && pwd)"
"$here/uitest.sh" "$target" "-only-testing:DayDoUITests/$test_id" >"$out.log" 2>&1 &
test_pid=$!

# uitest.sh may queue behind other xcodebuild runs; start recording once our run owns the booted device.
until pgrep -f "xcodebuild test.*$udid" >/dev/null && xcrun simctl list devices | grep "$udid" | grep -q Booted; do
  if ! kill -0 "$test_pid" 2>/dev/null; then break; fi
  sleep 1
done
rec_pid=""
if kill -0 "$test_pid" 2>/dev/null; then
  xcrun simctl io "$udid" recordVideo --codec h264 --force "$out.mp4" >/dev/null 2>&1 &
  rec_pid=$!
fi

rc=0
wait "$test_pid" || rc=$?
if [[ -n "$rec_pid" ]]; then
  kill -INT "$rec_pid" 2>/dev/null || true
  wait "$rec_pid" || true
fi
grep -E "Executed|TEST (SUCCEEDED|FAILED)" "$out.log" | tail -2 || true
echo "video: $out.mp4  log: $out.log  test rc=$rc" >&2
exit "$rc"
