#!/bin/bash
# Record one Time Profiler trace per DayDoPerfTests scenario.
# usage: UDID=<from `uitest.sh up iphone`> OUT=<dir> ios/scripts/perf/run.sh <round> [testPerfXxx ...]
# Writes <OUT>/<test>-<round>.{trace,log,images}; then `perf.py table <OUT> "<rounds>"`.
set -u
: "${UDID:?set UDID to the simulator printed by ios/scripts/uitest.sh up iphone}"
: "${OUT:?set OUT to a trace directory outside the repo (e.g. .agent-work/perf/traces)}"
export DD_SIM_OWNER="${DD_SIM_OWNER:-dd:perf}"
round=$1; shift
tests=("$@")
[ ${#tests[@]} -gt 0 ] || tests=(testPerfControlQueriesOnly testPerfTaskListScroll testPerfDrawerOpenClose testPerfTabSwitch
  testPerfDetailSheetOpenClose testPerfMonthSwipe testPerfMonthCollapseExpand testPerfAgendaListScroll
  testPerfWeekPageAndScroll testPerfDayTimeGridScroll testPerfYearView)
mkdir -p "$OUT"
cd "$(dirname "$0")/../.."
for t in "${tests[@]}"; do
  base="${OUT}/${t}-${round}"
  xcrun simctl terminate "$UDID" com.audichuang.daydo 2>/dev/null
  # -O so the numbers aren't dominated by unoptimized code; dSYMs so perf.py can atos DayDo frames.
  TEST_RUNNER_DAYDO_PERF=1 ./scripts/uitest.sh iphone -only-testing:"DayDoUITests/DayDoPerfTests/${t}" \
    SWIFT_OPTIMIZATION_LEVEL=-O DEBUG_INFORMATION_FORMAT=dwarf-with-dsym > "${base}.log" 2>&1 &
  tpid=$!
  pid=""
  while [ -z "$pid" ] && kill -0 "$tpid" 2>/dev/null; do
    pid=$(pgrep -f "DayDo.app/DayDo .*-DayDoSeedPerf" | head -1); sleep 0.2
  done
  if [ -n "$pid" ]; then
    rm -rf "${base}.trace"
    xcrun xctrace record --template 'Time Profiler' --instrument SwiftUI --device "$UDID" --attach "$pid" \
      --time-limit 240s --output "${base}.trace" > "${base}.xctrace.log" 2>&1
  fi
  wait "$tpid"; rc=$?
  cp "$(xcrun simctl get_app_container "$UDID" com.audichuang.daydo data)/tmp/perf-images.txt" "${base}.images" 2>/dev/null
  echo "${t} round=${round} rc=${rc}"
done
