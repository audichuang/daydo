#!/usr/bin/env bash
# Run DayDo UI tests on a DD simulator, one xcodebuild at a time.
#
#   ios/scripts/uitest.sh [iphone|ipad|"DD <full simulator name>"] [extra xcodebuild args...]
#   ios/scripts/uitest.sh build [extra xcodebuild args...]  # build-for-testing (no simulator needed)
#   ios/scripts/uitest.sh ipad -only-testing:DayDoUITests/DayDoFlowTests/testCalendar
#   ios/scripts/uitest.sh up [iphone|ipad|"DD <name>"]     # restore if parked, boot, lease, print the UDID
#   ios/scripts/uitest.sh down [iphone|ipad|"DD <name>"]   # drop your lease, shut down if nobody else uses it
#   ios/scripts/uitest.sh park [iphone|ipad]               # archive a resident device to the NAS
#
# Every mode first takes the DayDo lock (build just needs no sim-vault), a flock on a fixed file (not $TMPDIR:
# sessions have different ones). The fd is inherited by xcodebuild, so the lock lasts while
# any test process is alive, even if this shell is killed. test and build then also wait for
# every xcodebuild on the Mac to finish (two at once fail with "Failed to send signal 19";
# DerivedData and CPU are shared). Waiting for either gives up after 30 min with exit 8.
#
# Devices come from `sim-vault ensure` with a lease, which park and `sim-vault shutdown`
# respect: resident devices are restored from the NAS when parked (never created here: on 3
# no archive, on 4 the archive's runtime is not installed; ask the user). sim-vault exit codes
# are passed on unchanged; see `sim-vault --help`.
#
# Lease owners: a test run holds `dd:uitest` while it runs. `up` and `down` use $DD_SIM_OWNER,
# default `dd:up:<this worktree>`; two sessions in one worktree must each set their own
# DD_SIM_OWNER, or one's `down` drops the other's protection. A test refuses (8) to run while
# anyone else holds a lease: -DayDoReset wipes the app's data and Keychain.
#
# record-uitest.sh sets DD_UITEST_HANDSHAKE_DIR: once leased and booted this writes `udid`
# there, waits for `go`, and after the run writes `done` and waits for `stopped` before
# dropping the lease.
#
# Knobs for the tests in ios/scripts/tests: DD_UITEST_LOCK_WAIT (s, default 1800),
# DD_UITEST_POLL (s), DD_UITEST_HANDSHAKE_WAIT (s, default 120). DD_PARK_TRIM=1 adds
# --trim-posterboard to park.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd -P)"
root="$(cd "$here/../.." && pwd -P)"
lock_file="$HOME/Library/Developer/CoreSimulator/sim-vault/project-locks/daydo-uitest.lock"
lock_wait="${DD_UITEST_LOCK_WAIT:-1800}"
handshake_wait="${DD_UITEST_HANDSHAKE_WAIT:-120}"
owner="${DD_SIM_OWNER:-dd:up:$root}"
test_owner="dd:uitest"

usage() {
  echo "usage: $0 {build [xcodebuild args...] | [up|down|park] [iphone|ipad|\"DD <name>\"] | [iphone|ipad|\"DD <name>\"] [xcodebuild args...]}" >&2
  exit 2
}

# Validate without shifting: the lock re-executes this script with the original arguments.
mode="test"
case "${1:-}" in build|down|park|up) mode=$1 ;; esac
if [[ "$mode" == test ]]; then target="${1:-iphone}"; else target="${2:-iphone}"; fi
resident=1
name=""
if [[ "$mode" != build ]]; then
  case "$target" in
    iphone) name="DD iPhone 18 Pro" ;;
    ipad) name="DD iPad Pro 11" ;;
    "DD "*) name="$target"; resident=0 ;;
    *) usage ;;
  esac
fi

locked=0
if [[ -n "${DD_UITEST_LOCK_PID:-}" && "$DD_UITEST_LOCK_PID" == "$$" ]]; then locked=1; fi

if [[ "$mode" == park ]]; then
  # Last line on stdout, also when the lock times out, so `| tail` still shows the code.
  trap 'rc=$?; echo "park rc=$rc"; exit "$rc"' EXIT
  if [[ $resident == 0 ]]; then
    echo "park 只收常駐機（iphone／ipad）；臨時機用完直接 xcrun simctl delete" >&2
    exit 2
  fi
fi

# Probe the sim-vault on PATH before touching any lease: an old one lacks `shutdown`.
need_sim_vault() {
  if ! command -v sim-vault >/dev/null; then
    echo "找不到 sim-vault：ln -s ~/.aghub/modern-ios-guidance/scripts/sim-vault ~/.local/bin/sim-vault（modern-ios-guidance 技能要先用 aghub 裝好）" >&2
    exit 2
  fi
  if ! sim-vault shutdown --help >/dev/null 2>&1; then
    echo "sim-vault 版本過舊（缺 shutdown），先同步 audi-skill：aghub-cli source sync audichuang/audi-skill -g --update --yes" >&2
    exit 2
  fi
  if [[ "$mode" == park && "${DD_PARK_TRIM:-}" == 1 ]]; then
    local park_help
    park_help=$(sim-vault park --help 2>&1) || true
    if [[ "$park_help" != *--trim-posterboard* ]]; then
      echo "sim-vault 版本過舊（park 沒有 --trim-posterboard），先同步 audi-skill：aghub-cli source sync audichuang/audi-skill -g --update --yes" >&2
      exit 2
    fi
  fi
}

if [[ $locked == 0 ]]; then
  [[ "$mode" != build ]] && need_sim_vault
  exec python3 -I "$here/flock-exec.py" "$lock_file" "$lock_wait" "${DD_UITEST_POLL:-1}" \
    "mode=$mode name=${name:-none} owner=$owner" -- "$BASH" "$0" "$@"
fi

lock_rc="${DD_UITEST_LOCK_RC:-}"
lock_fd="${DD_UITEST_LOCK_FD:-}"
# Children (xcodebuild, a nested uitest.sh) must not think they hold the lock.
unset DD_UITEST_LOCK_PID DD_UITEST_LOCK_FD DD_UITEST_LOCK_RC
if [[ -n "$lock_rc" ]]; then exit "$lock_rc"; fi

# Drop the mode and target, keep the xcodebuild args.
if [[ "$mode" != test ]]; then shift; fi
if [[ "$mode" != build && $# -gt 0 ]]; then shift; fi

wait_for_xcodebuild() {
  local waited=0
  while pgrep -x xcodebuild >/dev/null; do
    if (( waited == 0 )); then
      echo "有別的 xcodebuild 在跑，等它結束：" >&2
      pgrep -lx xcodebuild >&2 || true
    fi
    if (( waited >= 1800 )); then
      echo "等了 30 分鐘仍未結束，放棄" >&2
      exit 8
    fi
    sleep "${DD_UITEST_POLL:-15}"
    waited=$((waited + 15))
  done
}

if [[ "$mode" == build ]]; then
  wait_for_xcodebuild
  cd "$here/.."
  echo "編譯測試標的：generic/platform=iOS Simulator" >&2
  xcodebuild build-for-testing -project DayDo.xcodeproj -scheme DayDo \
    -destination "generic/platform=iOS Simulator" \
    CODE_SIGNING_ALLOWED=NO "$@"
  exit
fi

# Reads `sim-vault status --json` and prints three lines: the number of available devices
# with the name, the UDID (empty unless exactly one), and the owners of live leases other
# than the arguments. Leases on a device that is gone are stale; ensure and park drop them.
read_status() {
  python3 -I -c '
import json, sys
s = json.load(sys.stdin)
allowed = set(sys.argv[1:])
print(s.get("count") or 0)
print(s.get("udid") or "")
print(", ".join(l.get("owner") or "?" for l in s.get("leases") or []
                if not l.get("stale") and l.get("owner") not in allowed))
' "$@"
}
status_json=""
load_status() {
  status_json=$(sim-vault status "$name" --json)
  local parsed
  parsed=$(printf '%s' "$status_json" | read_status "$@")
  count=$(printf '%s\n' "$parsed" | sed -n 1p)
  status_udid=$(printf '%s\n' "$parsed" | sed -n 2p)
  others=$(printf '%s\n' "$parsed" | sed -n 3p)
}

load_status "$owner"
if [[ "$count" == 0 && $resident == 0 && ( "$mode" == up || "$mode" == test ) ]]; then
  echo "找不到名為「${name}」的模擬器；臨時機不從 NAS 還原，先建好再跑" >&2
  exit 2
fi

if [[ "$mode" == up ]]; then
  # --wait matches this script's own 30 min: restoring a 6 GB archive takes minutes.
  udid=$(sim-vault ensure "$name" --boot --lease "$owner" --wait 1800)
  eval "exec ${lock_fd}>&-"
  printf '%s\n' "$udid"
  exit 0
fi

if [[ "$mode" == down ]]; then
  sim-vault release "$name" --lease "$owner"
  if [[ "$count" == 0 ]]; then
    echo "「${name}」不在本機（可能已收進 NAS），不用關機" >&2
    exit 0
  fi
  echo "關機：${name}（若沒有別人的 lease）" >&2
  rc=0
  sim-vault shutdown "$name" || rc=$?
  if [[ $rc == 8 ]]; then
    echo "還有別人在用「${name}」（上面列出 owner），沒有關機" >&2
  fi
  exit "$rc"
fi

if [[ "$mode" == park ]]; then
  # Old uitest.sh runs hold no lease and take a different lock; refuse while one of them
  # is testing on this device.
  if [[ -n "$status_udid" ]]; then
    for pid in $(pgrep -x xcodebuild || true); do
      if [[ "$(ps -o args= -p "$pid" 2>/dev/null || true)" == *"id=$status_udid"* ]]; then
        echo "xcodebuild（pid ${pid}）正在「${name}」(${status_udid}) 上測試，大概是沒有 lease 的舊版 uitest.sh；等它結束再收" >&2
        exit 8
      fi
    done
  fi
  # Holding the lock means no test of ours is alive, so a dd:uitest lease is left over
  # from a run that was killed.
  sim-vault release "$name" --lease "$test_owner"
  trim=()
  [[ "${DD_PARK_TRIM:-}" == 1 ]] && trim=(--trim-posterboard)
  rc=0
  sim-vault park "$name" --shutdown --missing-ok ${trim[@]+"${trim[@]}"} || rc=$?
  exit "$rc"
fi

# test
wait_for_xcodebuild
load_status "$owner" "$test_owner"
if [[ -n "$others" ]]; then
  echo "「${name}」正被別人使用（lease：${others}）；UI 測試的 -DayDoReset 會清掉 App 資料與 Keychain，不跑" >&2
  exit 8
fi

hs="${DD_UITEST_HANDSHAKE_DIR:-}"
udid_sent=0
alive() { [[ -n "$1" ]] && kill -0 "$1" 2>/dev/null; }
recorder_pid() { cat "$hs/recorder.pid" 2>/dev/null || true; }
finish() {
  local rc=$?
  trap - EXIT INT TERM HUP
  if [[ -n "$hs" && $udid_sent == 1 ]]; then
    : >"$hs/done"
    local waited=0 pid
    pid=$(recorder_pid)
    until [[ -e "$hs/stopped" ]] || { [[ -n "$pid" ]] && ! alive "$pid"; }; do
      if (( waited >= handshake_wait * 10 )); then
        echo "錄影器 ${handshake_wait} 秒內沒有回報 stopped，照樣交回 lease" >&2
        break
      fi
      sleep 0.1
      waited=$((waited + 1))
      [[ -n "$pid" ]] || pid=$(recorder_pid)
    done
  fi
  sim-vault release "$name" --lease "$test_owner" || rc=$?
  exit "$rc"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

# --wait matches this script's own 30 min: restoring a 6 GB archive takes minutes.
# --boot boots here instead of letting xcodebuild do it: xcodebuild shuts down a simulator it
# booted as soon as the run ends, often 30 s after boot while PosterBoard is still writing
# its wallpaper store. One such cut on 2026-11-17 corrupted that store and PosterBoard then
# crashed on every boot. A device that was already booted is left running.
udid=$(sim-vault ensure "$name" --boot --lease "$test_owner" --wait 1800)

if [[ -n "$hs" ]]; then
  printf '%s\n' "$udid" >"$hs/udid.tmp"
  mv "$hs/udid.tmp" "$hs/udid"
  udid_sent=1
  waited=0
  until [[ -e "$hs/go" ]]; do
    pid=$(recorder_pid)
    if [[ -n "$pid" ]] && ! alive "$pid"; then
      echo "錄影器（pid ${pid}）在開始前就結束了，不跑測試" >&2
      exit 1
    fi
    if (( waited >= handshake_wait * 10 )); then
      echo "錄影器 ${handshake_wait} 秒內沒有就緒，不跑測試" >&2
      exit 1
    fi
    sleep 0.1
    waited=$((waited + 1))
  done
fi

cd "$here/.."
echo "UI 測試：${name} (${udid})" >&2
# Foreground on purpose: a signal then reaches the trap only after xcodebuild has exited.
xcodebuild test -project DayDo.xcodeproj -scheme DayDo \
  -destination "platform=iOS Simulator,id=$udid" \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO "$@"
