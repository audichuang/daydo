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
# Requires sim-vault >= 4.0.0 (`uv tool install --force "git+https://github.com/audichuang/sim-vault@v4.0.0"`).
# Devices come from sim-vault with a lease, which park and `sim-vault shutdown` respect:
# resident devices are restored from the NAS when parked (never created here: on 3 no
# archive, on 4 the archive's runtime is not installed; ask the user). sim-vault exit codes
# are passed on unchanged; see `sim-vault --help`.
#
# Lease owners: a test run uses `sim-vault run --lease dd:run --boot --deny-other-leases`
# (a held lease tied to the inherited SIM_VAULT_LEASE_FD, alive while xcodebuild or
# recordVideo lives, blocking other owners' later ensures, and dropped automatically on exit;
# any leftover `dd:uitest` from a killed old-version run is released under the project lock
# first). It refuses (8) when anyone but the caller holds a lease: -DayDoReset wipes the
# app's data and Keychain. `up` and `down` use $DD_SIM_OWNER when set; otherwise they use
# sim-vault session leases (`--lease auto --lease-scope <worktree> --lease-prefix dd:up`)
# and no longer write owner files. During transition, `down` falls back to releasing and
# removing an existing legacy owner file when `release --lease auto` reports `no-lease`, and
# test mode allows `whoami` (or the legacy owner file if `whoami` is empty) when DD_SIM_OWNER
# is unset.
#
# DD_UITEST_RECORD=<file.mp4> (record-uitest.sh sets it) records the screen inside the
# `sim-vault run` child: recordVideo starts once the device is leased and booted, the tests
# start once it records, and after them it gets SIGINT before the child exits (keeping both
# the lock and lease fd while recording). If recordVideo exits early, fails or has to be
# killed, its output stays in <file.mp4>.recordVideo.log and the exit code is 11 unless the
# test itself failed (then the test's code).
#
# Knobs for the tests in ios/scripts/tests: DD_UITEST_LOCK_WAIT (s, default 1800),
# DD_UITEST_POLL (s). DD_PARK_TRIM=1 adds --trim-posterboard to park.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd -P)"
root="$(cd "$here/../.." && pwd -P)"
state_dir="$HOME/Library/Developer/CoreSimulator/sim-vault"
lock_file="$state_dir/project-locks/daydo-uitest.lock"
lock_wait="${DD_UITEST_LOCK_WAIT:-1800}"
# Relative to the caller's directory; the test run later cds into ios/.
record="${DD_UITEST_RECORD:-}"
case "$record" in ""|/*) ;; *) record="$PWD/$record" ;; esac

# Internal child invoked by `sim-vault run -- "$BASH" "$0" --run-child "$@"`.
# Inherits the DayDo project lock fd and SIM_VAULT_LEASE_FD; runs recording + xcodebuild.
if [[ "${1:-}" == --run-child && -n "${SIM_VAULT_UDID:-}" ]]; then
  shift
  name="${SIM_VAULT_NAME:-}"
  udid="$SIM_VAULT_UDID"
  rec_pid=""
  rec_log=""
  rec_failed=0
  xb_pid=""
  alive() { [[ -n "$1" ]] && kill -0 "$1" 2>/dev/null; }
  # Only an exit 0 after our SIGINT is a good recording; exiting early, failing, or needing
  # SIGKILL is a recording failure.
  stop_recorder() {
    [[ -n "$rec_pid" ]] || return 0
    local rec_rc=0
    if alive "$rec_pid"; then
      kill -INT "$rec_pid" 2>/dev/null || true
      local waited=0
      while alive "$rec_pid" && (( waited < 300 )); do sleep 0.1; waited=$((waited + 1)); done
      if alive "$rec_pid"; then
        echo "recordVideo 30 秒內沒有結束，強制停止（影片可能不完整）" >&2
        kill -KILL "$rec_pid" 2>/dev/null || true
        rec_failed=1
      fi
      wait "$rec_pid" 2>/dev/null || rec_rc=$?
    else
      wait "$rec_pid" 2>/dev/null || rec_rc=$?
      echo "recordVideo 在測試結束前就退出了（rc=${rec_rc}）" >&2
      rec_failed=1
    fi
    [[ $rec_rc == 0 ]] || rec_failed=1
    rec_pid=""
  }
  finish() {
    local rc=$? rm_rc=0
    trap - EXIT
    trap '' INT TERM HUP
    stop_recorder || rec_failed=1
    if [[ $rec_failed == 1 ]]; then
      echo "錄影失敗，recordVideo 的 log：${rec_log}" >&2
      [[ $rc != 0 ]] || rc=11
    elif [[ -n "$rec_log" ]]; then
      rm -f "$rec_log" || rm_rc=$?
      if [[ $rm_rc != 0 ]]; then
        echo "警告：無法刪除錄影 log ${rec_log}（rc=${rm_rc}）" >&2
      fi
    fi
    exit "$rc"
  }
  on_child_signal() {
    local sig_rc="$1"
    trap '' INT TERM HUP
    if [[ -n "$xb_pid" ]] && alive "$xb_pid"; then
      kill -TERM "$xb_pid" 2>/dev/null || true
      wait "$xb_pid" 2>/dev/null || true
    fi
    xb_pid=""
    exit "$sig_rc"
  }
  trap finish EXIT
  trap 'on_child_signal 130' INT
  trap 'on_child_signal 143' TERM
  trap 'on_child_signal 129' HUP

  if [[ -n "$record" ]]; then
    mkdir -p "$(dirname "$record")"
    rec_log="$record.recordVideo.log"
    # A background job of a non-interactive bash starts with SIGINT ignored, and SIGINT is how
    # recordVideo is told to finish the file; restore the default before exec.
    # recordVideo is stopped by stop_recorder before this child exits, so it keeps the lease fd.
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
  xcodebuild test -project DayDo.xcodeproj -scheme DayDo \
    -destination "platform=iOS Simulator,id=$udid" \
    -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO "$@" &
  xb_pid=$!
  rc=0
  wait "$xb_pid" || rc=$?
  xb_pid=""
  exit "$rc"
fi

orphan_hint() {
  echo "若 owner 的 worktree 已不存在、或確認那個 session 已結束，可 \`sim-vault release \"${name}\" --lease <owner>\` 清掉；不要清別人仍在用的" >&2
}
test_owner="dd:uitest"
install_hint='uv tool install --force "git+https://github.com/audichuang/sim-vault@v4.0.0"'

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
    # Full names of the resident devices take the same path as their aliases.
    iphone|"DD iPhone 18 Pro") target=iphone; name="DD iPhone 18 Pro" ;;
    ipad|"DD iPad Pro 11") target=ipad; name="DD iPad Pro 11" ;;
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
    echo "找不到 sim-vault；請安裝：${install_hint}" >&2
    exit 2
  fi
  local ver
  ver=$(sim-vault --version 2>/dev/null) || ver=""
  if ! [[ "$ver" =~ ([0-9]+)\.([0-9]+)\.([0-9]+) ]] || (( 10#${BASH_REMATCH[1]} < 4 )); then
    echo "sim-vault 版本過舊（需要 >= 4.0.0，目前：${ver:-未知}）；請更新：${install_hint}" >&2
    exit 2
  fi
  if ! sim-vault run --help >/dev/null 2>&1; then
    echo "sim-vault 版本過舊（缺 run）；請更新：${install_hint}" >&2
    exit 2
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

# Legacy owner file from pre-4.0 `up` (read by test/down during transition; never written).
case "$target" in
  iphone|ipad) alias="$target" ;;
  *) alias="$(printf '%s' "$name" | tr -c 'A-Za-z0-9' '_')" ;;
esac
owner_file="$state_dir/owners/daydo-$(printf '%s' "$root" | shasum | cut -c1-40)-$alias"
recorded_owner() { cat "$owner_file" 2>/dev/null || true; }

# Reads `sim-vault whoami --json`: whether a recognizable session anchor exists (1/0)
# and the session lease token for this worktree (empty if none or if anchor is null).
# A null anchor (or failed whoami) must not grant session identity across sessions.
whoami_has_anchor=0 whoami_lease=""
load_whoami() {
  whoami_has_anchor=0
  whoami_lease=""
  local json parsed
  json=$(sim-vault whoami "$name" --lease-scope "$root" --json 2>/dev/null) || return 0
  parsed=$(printf '%s' "$json" | python3 -I -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
if d.get("ok") and d.get("anchor") is not None:
    print("1")
    print(d.get("lease") or "")
else:
    print("0")
    print("")
' 2>/dev/null) || return 0
  whoami_has_anchor=$(printf '%s\n' "$parsed" | sed -n 1p)
  whoami_lease=$(printf '%s\n' "$parsed" | sed -n 2p)
  [[ "$whoami_has_anchor" == 1 ]] || { whoami_has_anchor=0; whoami_lease=""; }
}

# Reads `sim-vault status --json`: count of available devices with the name and the UDID
# (empty unless exactly one).
count="" status_udid=""
load_status() {
  local json parsed
  json=$(sim-vault status "$name" --json)
  parsed=$(printf '%s' "$json" | python3 -I -c '
import json, sys
s = json.load(sys.stdin)
print(s.get("count") or 0)
print(s.get("udid") or "")
')
  count=$(printf '%s\n' "$parsed" | sed -n 1p)
  status_udid=$(printf '%s\n' "$parsed" | sed -n 2p)
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
  if [[ $resident == 0 ]]; then
    load_status
    if [[ "$count" == 0 ]]; then
      echo "找不到名為「${name}」的模擬器；臨時機不從 NAS 還原，先建好再跑" >&2
      exit 2
    fi
  fi
  rc=0
  # --wait matches this script's own 30 min: restoring a 6 GB archive takes minutes.
  if [[ -n "${DD_SIM_OWNER:-}" ]]; then
    udid=$(sim-vault ensure "$name" --boot --lease "$DD_SIM_OWNER" --wait 1800) || rc=$?
  else
    load_whoami
    if [[ $whoami_has_anchor != 1 ]]; then
      echo "無法辨識目前的 session（sim-vault whoami 沒有 anchor）；請設 DD_SIM_OWNER=<唯一值> 再 up／down／測試" >&2
      exit 2
    fi
    udid=$(sim-vault ensure "$name" --boot --lease auto --lease-scope "$root" --lease-prefix dd:up --wait 1800) || rc=$?
  fi
  if [[ $rc == 8 && -z "${DD_SIM_OWNER:-}" ]]; then
    echo "若要兩個 session 同時用這台，請各自設 DD_SIM_OWNER=<唯一值> 再 up／down" >&2
  fi
  [[ $rc == 0 ]] || exit "$rc"
  eval "exec ${lock_fd}>&-"
  printf '%s\n' "$udid"
  exit 0
fi

if [[ "$mode" == down ]]; then
  load_status
  legacy_guard 關機
  if [[ -n "${DD_SIM_OWNER:-}" ]]; then
    sim-vault release "$name" --lease "$DD_SIM_OWNER"
  else
    load_whoami
    rel_action="no-lease"
    if [[ $whoami_has_anchor == 1 ]]; then
      rel_json=$(sim-vault release "$name" --lease auto --lease-scope "$root" --json)
      rel_action=$(printf '%s' "$rel_json" | python3 -I -c 'import json, sys; print(json.load(sys.stdin).get("action", ""))')
    fi
    if [[ "$rel_action" == no-lease && -e "$owner_file" ]]; then
      owner="$(recorded_owner)"
      if [[ -n "$owner" ]]; then
        sim-vault release "$name" --lease "$owner"
      fi
      rm -f "$owner_file"
    elif [[ $whoami_has_anchor != 1 ]]; then
      echo "無法辨識目前的 session（未設 DD_SIM_OWNER 且沒有舊 owner 檔），未釋放任何 lease；若要釋放特定 lease 請設 DD_SIM_OWNER=<owner>" >&2
    fi
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
    orphan_hint
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
  [[ $rc != 8 ]] || orphan_hint
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

# Holding the lock means no same-lock runner is alive, so a dd:uitest lease is left over
# from a killed old-version run.
sim-vault release "$name" --lease "$test_owner" --wait 1800

# The caller's own manual-test lease may stay; anyone else's makes run refuse (8) without
# leasing, checked under sim-vault's device lock. Never allow both DD_SIM_OWNER and whoami.
caller=""
if [[ -n "${DD_SIM_OWNER:-}" ]]; then
  caller="$DD_SIM_OWNER"
else
  load_whoami
  caller="$whoami_lease"
  if [[ -z "$caller" ]]; then
    caller="$(recorded_owner)"
  fi
fi
allow=()
[[ -z "$caller" ]] || allow=(--allow-lease "$caller")

if [[ -n "$record" ]]; then
  export DD_UITEST_RECORD="$record"
fi

result_file="$(mktemp "${TMPDIR:-/tmp}/dd-uitest-result.XXXXXX")"
run_pid=""
cleanup_outer() {
  rm -f "$result_file" 2>/dev/null || true
}
on_outer_signal() {
  local sig_rc="$1"
  trap '' INT TERM HUP
  if [[ -n "$run_pid" ]]; then
    kill -TERM "$run_pid" 2>/dev/null || true
    wait "$run_pid" 2>/dev/null || true
  fi
  cleanup_outer
  exit "$sig_rc"
}
trap cleanup_outer EXIT
trap 'on_outer_signal 130' INT
trap 'on_outer_signal 143' TERM
trap 'on_outer_signal 129' HUP

# --wait matches this script's own 30 min: restoring a 6 GB archive takes minutes.
# --boot boots here instead of letting xcodebuild do it: xcodebuild shuts down a simulator it
# booted as soon as the run ends, often 30 s after boot while PosterBoard is still writing
# its wallpaper store. One such cut on 2026-11-17 corrupted that store and PosterBoard then
# crashed on every boot. A device that was already booted is left running.
rc=0
sim-vault run "$name" --lease dd:run --boot --deny-other-leases \
  ${allow[@]+"${allow[@]}"} --wait 1800 --result-file "$result_file" \
  -- "$BASH" "$0" --run-child "$@" &
run_pid=$!
wait "$run_pid" || rc=$?
run_pid=""

if [[ $rc == 8 && -s "$result_file" ]]; then
  stage=$(python3 -I -c 'import json, sys
try:
    print(json.load(open(sys.argv[1])).get("stage", ""))
except Exception:
    pass
' "$result_file" 2>/dev/null || true)
  if [[ "$stage" == acquire ]]; then
    echo "「${name}」正被別人使用或鎖住（見上面的 owner）；UI 測試的 -DayDoReset 會清掉 App 資料與 Keychain，不跑" >&2
    orphan_hint
  fi
fi
exit "$rc"
