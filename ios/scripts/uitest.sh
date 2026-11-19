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
# Every mode first takes the DayDo lock (build just needs no sim-vault), a flock on a fixed
# file (not $TMPDIR: sessions have different ones). The fd is inherited by xcodebuild and
# recordVideo, so the lock lasts while any test process is alive, even if this shell is
# killed. test and build then also wait for every xcodebuild on the Mac to finish (two at
# once fail with "Failed to send signal 19"; DerivedData and CPU are shared). Waiting for
# either gives up after 30 min with exit 8.
#
# Devices come from `sim-vault ensure` with a lease, which park and `sim-vault shutdown`
# respect: resident devices are restored from the NAS when parked (never created here: on 3
# no archive, on 4 the archive's runtime is not installed; ask the user). sim-vault exit codes
# are passed on unchanged; see `sim-vault --help`.
#
# Lease owners: a test run holds `dd:uitest` while it runs, and refuses (8) when anyone but
# the caller holds a lease: -DayDoReset wipes the app's data and Keychain. `up` and `down` use
# $DD_SIM_OWNER when set. Otherwise `up` makes a fresh owner `dd:up:<worktree>:<random>` and
# records it in owners/daydo-<sha1 of worktree>-<device> next to the lock, refusing (8) while
# an earlier `up` from this worktree still holds its lease; `down` reads it back and removes
# the record once the lease is released. A test without DD_SIM_OWNER accepts that recorded
# owner as the caller.
#
# DD_UITEST_RECORD=<file.mp4> (record-uitest.sh sets it) records the screen: recordVideo is
# started after the device is leased and booted, the tests start once it records, and after
# them it gets SIGINT and the lease is dropped only once it has exited. As a child of this
# script it holds the lock too.
#
# Knobs for the tests in ios/scripts/tests: DD_UITEST_LOCK_WAIT (s, default 1800),
# DD_UITEST_POLL (s). DD_PARK_TRIM=1 adds --trim-posterboard to park.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd -P)"
root="$(cd "$here/../.." && pwd -P)"
state_dir="$HOME/Library/Developer/CoreSimulator/sim-vault"
lock_file="$state_dir/project-locks/daydo-uitest.lock"
lock_wait="${DD_UITEST_LOCK_WAIT:-1800}"
test_owner="dd:uitest"
sync_hint="先同步 audi-skill：aghub-cli source sync audichuang/audi-skill -g --update --yes"

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

# Probe the sim-vault on PATH before touching any lease or archive.
need_sim_vault() {
  if ! command -v sim-vault >/dev/null; then
    echo "找不到 sim-vault：ln -s ~/.aghub/modern-ios-guidance/scripts/sim-vault ~/.local/bin/sim-vault（modern-ios-guidance 技能要先用 aghub 裝好）" >&2
    exit 2
  fi
  if ! sim-vault shutdown --help >/dev/null 2>&1; then
    echo "sim-vault 版本過舊（缺 shutdown），${sync_hint}" >&2
    exit 2
  fi
  local help
  help=$(sim-vault ensure --help 2>&1) || true
  if [[ "$help" != *--deny-other-leases* ]]; then
    echo "sim-vault 版本過舊（ensure 沒有 --deny-other-leases），${sync_hint}" >&2
    exit 2
  fi
  if [[ "$mode" == park && "${DD_PARK_TRIM:-}" == 1 ]]; then
    help=$(sim-vault park --help 2>&1) || true
    if [[ "$help" != *--trim-posterboard* ]]; then
      echo "sim-vault 版本過舊（park 沒有 --trim-posterboard），${sync_hint}" >&2
      exit 2
    fi
  fi
}

if [[ $locked == 0 ]]; then
  [[ "$mode" != build ]] && need_sim_vault
  exec python3 -I "$here/flock-exec.py" "$lock_file" "$lock_wait" "${DD_UITEST_POLL:-1}" \
    "mode=$mode name=${name:-none} owner=${DD_SIM_OWNER:-auto}" -- "$BASH" "$0" "$@"
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

# Where `up` records the owner it made when DD_SIM_OWNER is not set. Written and removed
# only while holding the lock.
case "$target" in
  iphone|ipad) alias="$target" ;;
  *) alias="$(printf '%s' "$name" | tr -c 'A-Za-z0-9' '_')" ;;
esac
owner_file="$state_dir/owners/daydo-$(printf '%s' "$root" | shasum | cut -c1-40)-$alias"
recorded_owner() { cat "$owner_file" 2>/dev/null || true; }

# Reads `sim-vault status --json`: count of available devices with the name, the UDID (empty
# unless exactly one), and the live lease owners, one per line.
count="" status_udid="" leases=""
load_status() {
  local json parsed
  json=$(sim-vault status "$name" --json)
  parsed=$(printf '%s' "$json" | python3 -I -c '
import json, sys
s = json.load(sys.stdin)
print(s.get("count") or 0)
print(s.get("udid") or "")
for l in s.get("leases") or []:
    if not l.get("stale"):
        print(l.get("owner") or "?")
')
  count=$(printf '%s\n' "$parsed" | sed -n 1p)
  status_udid=$(printf '%s\n' "$parsed" | sed -n 2p)
  leases=$(printf '%s\n' "$parsed" | sed -n '3,$p')
}

# Old uitest.sh runs hold no lease and take a different lock; refuse while one of them is
# testing on this device. Only a running xcodebuild is visible this way.
legacy_guard() {
  [[ -n "$status_udid" ]] || return 0
  local pid
  for pid in $(pgrep -x xcodebuild || true); do
    if [[ "$(ps -o args= -p "$pid" 2>/dev/null || true)" == *"id=$status_udid"* ]]; then
      echo "xcodebuild（pid ${pid}）正在「${name}」(${status_udid}) 上測試，大概是沒有 lease 的舊版 uitest.sh；等它結束再$1" >&2
      exit 8
    fi
  done
}

if [[ "$mode" == up ]]; then
  load_status
  if [[ "$count" == 0 && $resident == 0 ]]; then
    echo "找不到名為「${name}」的模擬器；臨時機不從 NAS 還原，先建好再跑" >&2
    exit 2
  fi
  if [[ -n "${DD_SIM_OWNER:-}" ]]; then
    owner="$DD_SIM_OWNER"
  else
    prev="$(recorded_owner)"
    if [[ -n "$prev" ]] && printf '%s\n' "$leases" | grep -qxF -- "$prev"; then
      echo "這個 worktree 先前的 up 還持有「${name}」的 lease（${prev}）。那個 session 做完先 down；兩個 session 同時用這台，各自設 DD_SIM_OWNER=<唯一值> 再 up／down" >&2
      exit 8
    fi
    owner="dd:up:$root:$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
    mkdir -p "$(dirname "$owner_file")"
    # Recorded before the lease exists, so a killed up never leaves a lease nobody can name.
    printf '%s\n' "$owner" >"$owner_file"
  fi
  rc=0
  # --wait matches this script's own 30 min: restoring a 6 GB archive takes minutes.
  udid=$(sim-vault ensure "$name" --boot --lease "$owner" --wait 1800) || rc=$?
  if [[ $rc != 0 ]]; then
    [[ -n "${DD_SIM_OWNER:-}" ]] || rm -f "$owner_file"
    exit "$rc"
  fi
  eval "exec ${lock_fd}>&-"
  printf '%s\n' "$udid"
  exit 0
fi

if [[ "$mode" == down ]]; then
  load_status
  legacy_guard 關機
  owner="${DD_SIM_OWNER:-$(recorded_owner)}"
  if [[ -n "$owner" ]]; then
    sim-vault release "$name" --lease "$owner"
    [[ -n "${DD_SIM_OWNER:-}" ]] || rm -f "$owner_file"
  fi
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
  load_status
  legacy_guard 收
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
if [[ $resident == 0 ]]; then
  load_status
  if [[ "$count" == 0 ]]; then
    echo "找不到名為「${name}」的模擬器；臨時機不從 NAS 還原，先建好再跑" >&2
    exit 2
  fi
fi

record="${DD_UITEST_RECORD:-}"
rec_pid=""
rec_log=""
alive() { [[ -n "$1" ]] && kill -0 "$1" 2>/dev/null; }
stop_recorder() {
  [[ -n "$rec_pid" ]] || return 0
  if alive "$rec_pid"; then
    kill -INT "$rec_pid" 2>/dev/null || true
    local waited=0
    while alive "$rec_pid" && (( waited < 300 )); do sleep 0.1; waited=$((waited + 1)); done
    if alive "$rec_pid"; then
      echo "recordVideo 30 秒內沒有結束，強制停止（影片可能不完整）" >&2
      kill -KILL "$rec_pid" 2>/dev/null || true
    fi
  fi
  wait "$rec_pid" 2>/dev/null || true
  rec_pid=""
}
finish() {
  local rc=$? release_rc=0
  trap - EXIT INT TERM HUP
  stop_recorder
  [[ -z "$rec_log" ]] || rm -f "$rec_log"
  sim-vault release "$name" --lease "$test_owner" || release_rc=$?
  if [[ $release_rc != 0 ]]; then
    echo "交回 lease ${test_owner} 失敗（rc=${release_rc}），lease 還留著；下次測試或 park 會清掉" >&2
    # The run's own failure says more than the cleanup's.
    [[ $rc != 0 ]] || rc=$release_rc
  fi
  exit "$rc"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

# The caller's own manual-test lease may stay; anyone else's makes ensure refuse (8) without
# leasing, checked under sim-vault's device lock.
caller="${DD_SIM_OWNER:-$(recorded_owner)}"
allow=()
[[ -z "$caller" ]] || allow=(--allow-lease "$caller")
# --wait matches this script's own 30 min: restoring a 6 GB archive takes minutes.
# --boot boots here instead of letting xcodebuild do it: xcodebuild shuts down a simulator it
# booted as soon as the run ends, often 30 s after boot while PosterBoard is still writing
# its wallpaper store. One such cut on 2026-11-17 corrupted that store and PosterBoard then
# crashed on every boot. A device that was already booted is left running.
rc=0
udid=$(sim-vault ensure "$name" --boot --lease "$test_owner" --deny-other-leases \
  ${allow[@]+"${allow[@]}"} --wait 1800) || rc=$?
if [[ $rc == 8 ]]; then
  echo "「${name}」正被別人使用或鎖住（見上面的 owner）；UI 測試的 -DayDoReset 會清掉 App 資料與 Keychain，不跑" >&2
fi
[[ $rc == 0 ]] || exit "$rc"

if [[ -n "$record" ]]; then
  mkdir -p "$(dirname "$record")"
  rec_log=$(mktemp "${TMPDIR:-/tmp}/dd-record.XXXXXX")
  # A background job of a non-interactive bash starts with SIGINT ignored, and SIGINT is how
  # recordVideo is told to finish the file; restore the default before exec.
  python3 -I -c 'import os, signal, sys; signal.signal(signal.SIGINT, signal.SIG_DFL); os.execvp(sys.argv[1], sys.argv[1:])' \
    xcrun simctl io "$udid" recordVideo --codec h264 --force "$record" >"$rec_log" 2>&1 &
  rec_pid=$!
  # recordVideo prints "Recording started" once frames flow; if this Xcode prints nothing,
  # still alive after the grace period counts as started.
  waited=0
  until grep -q "Recording started" "$rec_log" 2>/dev/null || (( waited >= 50 )); do
    alive "$rec_pid" || break
    sleep 0.1
    waited=$((waited + 1))
  done
  if ! alive "$rec_pid"; then
    echo "recordVideo 沒有啟動，不跑測試：$(cat "$rec_log" 2>/dev/null)" >&2
    exit 1
  fi
fi

cd "$here/.."
echo "UI 測試：${name} (${udid})" >&2
# Foreground on purpose: a signal then reaches the trap only after xcodebuild has exited.
xcodebuild test -project DayDo.xcodeproj -scheme DayDo \
  -destination "platform=iOS Simulator,id=$udid" \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO "$@"
