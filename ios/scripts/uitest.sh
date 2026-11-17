#!/usr/bin/env bash
# Run DayDo UI tests on a DD simulator, one xcodebuild at a time.
#
#   ios/scripts/uitest.sh [iphone|ipad|"DD <full simulator name>"] [extra xcodebuild args...]
#   ios/scripts/uitest.sh ipad -only-testing:DayDoUITests/DayDoFlowTests/testCalendar
#   ios/scripts/uitest.sh down [iphone|ipad|"DD <name>"]   # shut down once the batch is done
#   ios/scripts/uitest.sh park [iphone|ipad]               # archive a resident device to the NAS
#   ios/scripts/uitest.sh up [iphone|ipad|"DD <name>"]     # restore if parked, boot, print the UDID
#
# `park` hands a resident device to sim-vault (whole device incl. app and login, stored on
# the NAS) and deletes it locally; the next run that cannot find it restores it inside the
# lock. A missing NAS share never deletes or recreates a resident device: a blank device
# parked later would overwrite the archive that still holds the login.
#
# Codex, agy and other sessions share the DD simulators; two xcodebuild runs at
# once fail at launch with "Failed to send signal 19", so this waits for others.
# `down` waits on the same lock: a bare `simctl shutdown` from another session once
# cut a run 14 s after boot.
set -euo pipefail

mode=test
case "${1:-}" in down|park|up) mode=$1; shift ;; esac
target="${1:-iphone}"
[[ $# -gt 0 ]] && shift
resident=1
case "$target" in
  iphone) name="DD iPhone 18 Pro" ;;
  ipad) name="DD iPad Pro 11" ;;
  "DD "*) name="$target"; resident=0 ;;
  *) echo "usage: $0 [down|park|up] [iphone|ipad|\"DD <name>\"] [xcodebuild args...]" >&2; exit 2 ;;
esac
if [[ "$mode" == park && $resident == 0 ]]; then
  echo "park 只收常駐機（iphone／ipad）；臨時機用完直接 xcrun simctl delete" >&2
  exit 2
fi

# Prints the UDID, "MISSING" when no device has the name, or "" when several do.
lookup() {
  xcrun simctl list devices available -j | python3 -c '
import json, sys
name = sys.argv[1]
ids = [d["udid"] for ds in json.load(sys.stdin)["devices"].values() for d in ds if d["name"] == name]
print(ids[0] if len(ids) == 1 else ("MISSING" if not ids else ""))
' "$name"
}
udid=$(lookup)
if [[ "$udid" == MISSING && $resident == 1 && ( "$mode" == down || "$mode" == park ) ]]; then
  echo "「${name}」不在本機（可能已收進 NAS），不用處理" >&2
  exit 0
fi
if [[ -z "$udid" || ( "$udid" == MISSING && $resident == 0 ) ]]; then
  echo "找不到唯一一台名為「${name}」的模擬器（xcrun simctl list devices）" >&2
  exit 2
fi

boot() {
  xcrun simctl boot "$udid" 2>/dev/null || true
  xcrun simctl bootstatus "$udid" -b >/dev/null
}
# `up` on a device that is already here needs no lock.
if [[ "$mode" == up && "$udid" != MISSING ]]; then
  boot
  printf '%s\n' "$udid"
  exit 0
fi

store="$HOME/Library/Developer/CoreSimulator/Devices/$udid/data/Library/Application Support/PRBPosterExtensionDataStore"
if [[ "$mode" == park && -d "$store" ]] && (( $(du -sk "$store" | cut -f1) > 1048576 )); then
  # A bloated PosterBoard store (12G on the iPad, 2026-11-17) would be archived as is. Healthy is about 200M.
  echo "PosterBoard 資料超過 1G（$(du -sh "$store" | cut -f1)），先照 AGENTS.md「模擬器」的修法重建再收起；機器沒動" >&2
  exit 1
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

trap 'rm -rf "$lock"' EXIT

# Restore inside the lock so two sessions never restore the same device twice.
# sim-vault exit codes: 3 no archive, 4 runtime removed, 5 NAS share not mounted.
if [[ "$udid" == MISSING ]]; then
  udid=$(lookup)
fi
if [[ "$udid" == MISSING ]]; then
  echo "從 NAS 還原「${name}」…" >&2
  rc=0
  sim-vault restore "$name" >/dev/null || rc=$?
  case "$rc" in
    0) udid=$(lookup) ;;
    3) echo "NAS 上沒有「${name}」的封存。要重建先問使用者，建好要重新登入（AGENTS.md「模擬器」）" >&2; exit 3 ;;
    4) echo "封存用的 iOS runtime 已移除，無法還原（sim-vault list 看版本）" >&2; exit 4 ;;
    5) echo "NAS 的 WorkSpace 沒掛上：先掛上再重跑。不建空機，空機之後再收起會蓋掉有登入的封存" >&2; exit 5 ;;
    *) echo "sim-vault restore 失敗（結束碼 ${rc}），沒有重建，先查原因" >&2; exit "$rc" ;;
  esac
  if [[ -z "$udid" || "$udid" == MISSING ]]; then
    echo "還原後仍找不到唯一一台「${name}」" >&2
    exit 1
  fi
fi

if [[ "$mode" == up ]]; then
  boot
  printf '%s\n' "$udid"
  exit 0
fi
if [[ "$mode" != test ]]; then
  echo "關機：${name} (${udid})" >&2
  xcrun simctl shutdown "$udid" 2>/dev/null || true
fi
[[ "$mode" == down ]] && exit 0
if [[ "$mode" == park ]]; then
  rc=0
  sim-vault park "$name" || rc=$?
  case "$rc" in
    0) echo "已收起「${name}」到 NAS；下次 uitest.sh 會自動還原（App 與登入都在，UDID 會換新）" >&2 ;;
    5) echo "NAS 的 WorkSpace 沒掛上，模擬器保留沒刪（已關機）" >&2 ;;
    *) echo "sim-vault park 失敗（結束碼 ${rc}），模擬器保留沒刪" >&2 ;;
  esac
  exit "$rc"
fi

cd "$(dirname "$0")/.."
echo "UI 測試：${name} (${udid})" >&2
# Boot here instead of letting xcodebuild do it: xcodebuild shuts down a simulator it booted
# as soon as the run ends, often 30 s after boot while PosterBoard is still writing its
# wallpaper store. One such cut on 2026-11-17 corrupted that store and PosterBoard then
# crashed on every boot. A device that was already booted is left running.
boot
xcodebuild test -project DayDo.xcodeproj -scheme DayDo \
  -destination "platform=iOS Simulator,id=$udid" \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO "$@"
