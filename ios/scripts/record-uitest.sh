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
# uitest.sh does the recording (DD_UITEST_RECORD): it starts recordVideo on the device it leased,
# runs the test once recording has started, and keeps the lease and its lock until recordVideo
# has exited. Exit 11: the test passed but the recording failed (see <prefix>.mp4.recordVideo.log).
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "usage: $0 [iphone|ipad|\"DD <name>\"] <Class/testMethod> <output prefix>" >&2
  exit 2
fi
target="$1"; test_id="$2"; out="$3"
here="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$(dirname "$out")"

rec_log="$out.mp4.recordVideo.log"
rm -f "$rec_log"
rc=0
DD_UITEST_RECORD="$out.mp4" "$here/uitest.sh" "$target" "-only-testing:DayDoUITests/$test_id" \
  >"$out.log" 2>&1 || rc=$?
grep -E "Executed|TEST (SUCCEEDED|FAILED)" "$out.log" | tail -2 || true
# uitest.sh keeps the recorder's log only when the recording failed (11 if the test passed).
if [[ -e "$rec_log" ]]; then
  echo "錄影失敗，影片不可用：recordVideo log: $rec_log  log: $out.log  rc=$rc" >&2
else
  echo "video: $out.mp4  log: $out.log  test rc=$rc" >&2
fi
exit "$rc"
