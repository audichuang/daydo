#!/usr/bin/env bash
# Tests for ios/scripts/uitest.sh and record-uitest.sh against stub sim-vault, xcrun,
# xcodebuild, pgrep and ps. Nothing here touches a real simulator: HOME, TMPDIR and PATH point
# into a scratch directory, and PATH is <stubs>:/usr/bin:/bin with BASH_ENV unset.
#
#   bash ios/scripts/tests/test_uitest_sh.sh [test_name...]
set -uo pipefail

SCRIPTS="$(cd "$(dirname "$0")/.." && pwd -P)"
ROOT="$(cd "$SCRIPTS/../.." && pwd -P)"
UITEST="$SCRIPTS/uitest.sh"
RECORD="$SCRIPTS/record-uitest.sh"
REAL_PY="$(command -v python3)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/dd-uitest-test.XXXXXX")"
STUB="$WORK/stub"
STUB_NOVAULT="$WORK/stub-novault"
FAILS=0
FAILED_TESTS=""
CURRENT=""
BG_PIDS=""

cleanup() {
  local p
  for p in $BG_PIDS; do kill -KILL "$p" 2>/dev/null || true; done
  rm -rf "$WORK"
}
trap cleanup EXIT

# ---------------------------------------------------------------- stubs
mkdir -p "$STUB" "$STUB_NOVAULT"

cat >"$STUB/sim-vault" <<'EOF'
#!/bin/bash
# Stub sim-vault. State in $STUB_STATE: udid (device present), archive (restorable),
# booted, leases (one owner per line), hook.<cmd> (sourced first), rc.<cmd> (forced exit).
S="$STUB_STATE"
ev() { printf '%s\n' "$*" >>"$S/events.log"; }
cmd="${1:-}"
case " $* " in
  *" --help "*|*" -h "*)
    if [[ "$cmd" == shutdown && -e "$S/old-vault" ]]; then
      echo "sim-vault: error: argument command: invalid choice: 'shutdown'" >&2; exit 2
    fi
    if [[ "$cmd" == park ]]; then
      if [[ -e "$S/no-trim" ]]; then echo "usage: sim-vault park [--shutdown] [--missing-ok] name"
      else echo "usage: sim-vault park [--shutdown] [--missing-ok] [--trim-posterboard] name"; fi
    fi
    exit 0 ;;
esac
shift
name="${1:-}"; shift || true
ev "sim-vault $cmd $name $*"
if [[ -e "$S/hook.$cmd" ]]; then . "$S/hook.$cmd"; fi
owner=""
while [[ $# -gt 0 ]]; do
  case "$1" in --lease) owner="$2"; shift 2 ;; *) shift ;; esac
done
leases() { grep -v '^$' "$S/leases" 2>/dev/null || true; }
busy() {
  local who
  who="$(leases | paste -sd, -)"
  [[ -n "$who" ]] || return 1
  echo "error: '$name' is leased by $who" >&2
  echo "error (exit 8, busy): '$name' is leased by $who" >&2
  return 0
}
if [[ -e "$S/rc.$cmd" ]]; then
  rc="$(cat "$S/rc.$cmd")"
  echo "error (exit $rc, forced): stub" >&2
  exit "$rc"
fi
case "$cmd" in
  status)
    count=0; udid=null
    if [[ -e "$S/udid" ]]; then count=1; udid="\"$(cat "$S/udid")\""; fi
    items=""
    while IFS= read -r o; do
      items="${items:+$items,}{\"owner\":\"$o\",\"mode\":\"shared\",\"stale\":false}"
    done < <(leases)
    if [[ -e "$S/stale-lease" ]]; then
      items="${items:+$items,}{\"owner\":\"$(cat "$S/stale-lease")\",\"mode\":\"shared\",\"stale\":true}"
    fi
    printf '{"ok":true,"name":"%s","count":%s,"udid":%s,"leases":[%s]}\n' "$name" "$count" "$udid" "$items"
    ;;
  ensure)
    if [[ ! -e "$S/udid" ]]; then
      if [[ -e "$S/archive" ]]; then
        echo "UDID-NEW" >"$S/udid"; ev "sim-vault restored UDID-NEW"
      else
        echo "error (exit 3, no-archive): no archive for '$name'" >&2; exit 3
      fi
    fi
    if [[ -n "$owner" ]] && ! leases | grep -qxF -- "$owner"; then
      printf '%s\n' "$owner" >>"$S/leases"
    fi
    : >"$S/booted"
    cat "$S/udid"
    ;;
  release)
    if [[ -e "$S/leases" ]]; then
      grep -vxF -- "$owner" "$S/leases" >"$S/leases.tmp" || true
      mv "$S/leases.tmp" "$S/leases"
    fi
    ;;
  shutdown)
    if busy; then ev "sim-vault shutdown-refused"; exit 8; fi
    rm -f "$S/booted"; ev "sim-vault shutdown-done"
    ;;
  park)
    if busy; then ev "sim-vault park-refused"; exit 8; fi
    if [[ ! -e "$S/udid" ]]; then echo "'$name' is not here" >&2; exit 0; fi
    rm -f "$S/udid" "$S/booted"; : >"$S/archive"; ev "sim-vault park-done"
    ;;
esac
EOF

cat >"$STUB/xcodebuild" <<'EOF'
#!/bin/bash
S="$STUB_STATE"
printf '%s\n' "xcodebuild $*" >>"$S/events.log"
echo $$ >"$S/xcodebuild.pid"
if [[ -e "$S/xcodebuild.block" ]]; then
  while [[ ! -e "$S/xcodebuild.release" ]]; do sleep 0.05; done
fi
printf '%s\n' "xcodebuild-exit" >>"$S/events.log"
echo "Executed 1 test, with 0 failures"
echo "** TEST SUCCEEDED **"
exit "$(cat "$S/rc.xcodebuild" 2>/dev/null || echo 0)"
EOF

cat >"$STUB/xcrun" <<'EOF'
#!/bin/bash
S="$STUB_STATE"
printf '%s\n' "xcrun $*" >>"$S/events.log"
if [[ "${1:-} ${2:-}" == "simctl io" && "${4:-}" == recordVideo ]]; then
  if [[ -e "$S/rec.fail" ]]; then echo "recordVideo: cannot record" >&2; exit 1; fi
  out="${@: -1}"
  # Exit a little after SIGINT, like recordVideo finishing the file.
  trap 'sleep 0.3; printf "%s\n" "rec-stopped" >>"$S/events.log"; exit 0' INT
  : >"$out"
  echo "Recording started" >&2
  while :; do sleep 0.05; done
fi
exit 0
EOF

cat >"$STUB/pgrep" <<'EOF'
#!/bin/bash
S="$STUB_STATE"
[[ -s "$S/pgrep.out" ]] || exit 1
if [[ "${1:-}" == -lx ]]; then sed 's/$/ xcodebuild/' "$S/pgrep.out"; else cat "$S/pgrep.out"; fi
EOF

cat >"$STUB/ps" <<'EOF'
#!/bin/bash
S="$STUB_STATE"
pid="${@: -1}"
[[ -e "$S/ps.$pid" ]] || exit 1
cat "$S/ps.$pid"
EOF

chmod +x "$STUB"/*
ln -s "$REAL_PY" "$STUB/python3"
for f in xcodebuild xcrun pgrep ps python3; do ln -s "$STUB/$f" "$STUB_NOVAULT/$f"; done

# ---------------------------------------------------------------- helpers
setup() {
  T="$WORK/t-$CURRENT"
  S="$T/state"
  mkdir -p "$T/home" "$T/tmp" "$S"
  echo "UDID-AAA" >"$S/udid"
  : >"$S/events.log"
  LOCK="$T/home/Library/Developer/CoreSimulator/sim-vault/project-locks/daydo-uitest.lock"
  set_env "$STUB"
}
set_env() {
  ENVCMD=(env -u BASH_ENV -u DD_SIM_OWNER -u DD_PARK_TRIM -u DD_UITEST_HANDSHAKE_DIR
    -u DD_UITEST_LOCK_PID -u DD_UITEST_LOCK_FD -u DD_UITEST_LOCK_RC
    HOME="$T/home" TMPDIR="$T/tmp" STUB_STATE="$S"
    DD_UITEST_POLL=0.05 DD_UITEST_LOCK_WAIT=30 DD_UITEST_HANDSHAKE_WAIT=10
    PATH="$1:/usr/bin:/bin")
}
# run [VAR=val...] -- uitest.sh args; stdout in $T/out, stderr in $T/err, exit code in RC.
run() {
  local envs=()
  while [[ "$1" != -- ]]; do envs+=("$1"); shift; done
  shift
  RC=0
  "${ENVCMD[@]}" ${envs[@]+"${envs[@]}"} bash --noprofile --norc "$UITEST" "$@" >"$T/out" 2>"$T/err" || RC=$?
}
# bg NAME uitest.sh args: start in the background; the pid is the uitest.sh process itself
# (env and the lock shim exec, so the pid stays).
bg() {
  local tag="$1"; shift
  "${ENVCMD[@]}" bash --noprofile --norc "$UITEST" "$@" >"$T/$tag.out" 2>"$T/$tag.err" &
  BGPID=$!
  BG_PIDS="$BG_PIDS $BGPID"
}
fail() {
  echo "  FAIL [$CURRENT] $*"
  FAILS=$((FAILS + 1))
  case " $FAILED_TESTS " in *" $CURRENT "*) ;; *) FAILED_TESTS="$FAILED_TESTS $CURRENT" ;; esac
}
eq() { [[ "$1" == "$2" ]] || fail "$3: expected '$2', got '$1'"; }
has() { grep -qE -- "$2" "$1" || fail "$3: /$2/ not in $(basename "$1")"; }
hasnt() { if grep -qE -- "$2" "$1"; then fail "$3: /$2/ found in $(basename "$1")"; fi; }
ev_line() { grep -nE -- "$1" "$S/events.log" | head -1 | cut -d: -f1; }
before() {
  local a b
  a="$(ev_line "$1")"; b="$(ev_line "$2")"
  if [[ -z "$a" || -z "$b" ]]; then fail "$3: missing event (/$1/ at ${a:-none}, /$2/ at ${b:-none})"; return; fi
  (( a < b )) || fail "$3: /$1/ (line $a) not before /$2/ (line $b)"
}
wait_for() { # pattern file seconds
  local i=0
  while ! grep -qE -- "$1" "$2" 2>/dev/null; do
    sleep 0.05; i=$((i + 1))
    if (( i > $3 * 20 )); then fail "timed out waiting for /$1/ in $(basename "$2")"; return 1; fi
  done
}
wait_exit() { # pid seconds -> sets WRC
  local i=0
  while kill -0 "$1" 2>/dev/null; do
    sleep 0.05; i=$((i + 1))
    if (( i > $2 * 20 )); then fail "pid $1 still running after $2 s"; kill -KILL "$1" 2>/dev/null; break; fi
  done
  WRC=0
  wait "$1" 2>/dev/null || WRC=$?
}
lock_free() {
  "$REAL_PY" -I -c '
import fcntl, os, sys
fd = os.open(sys.argv[1], os.O_RDWR)
try:
    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError:
    sys.exit(1)
' "$LOCK"
}
count_lines() { grep -cE -- "$1" "$S/events.log" || true; }
last_line() { tail -n 1 "$1"; }

# ---------------------------------------------------------------- tests
t_stubs_on_path() {
  local out
  out="$("${ENVCMD[@]}" bash --noprofile --norc -c 'command -v sim-vault xcrun xcodebuild pgrep ps python3')"
  eq "$(printf '%s\n' "$out" | grep -vc "^$STUB/")" 0 "every tool resolves to a stub: $out"
}

t_test_run_basic() {
  run -- iphone -only-testing:DayDoUITests/X
  eq "$RC" 0 "rc"
  before "sim-vault status DD iPhone 18 Pro" "sim-vault ensure DD iPhone 18 Pro --boot --lease dd:uitest --wait 1800" "status before ensure"
  has "$S/events.log" "xcodebuild test .*id=UDID-AAA .*-only-testing:DayDoUITests/X" "xcodebuild uses the leased UDID"
  before "xcodebuild-exit" "sim-vault release DD iPhone 18 Pro --lease dd:uitest" "release after xcodebuild"
  eq "$(cat "$S/leases")" "" "no lease left"
  [[ -e "$S/booted" ]] || fail "device should stay booted after a test"
  lock_free || fail "lock still held after the test"
}

t_park_first_test_waits() {
  : >"$S/archive"
  # shellcheck disable=SC2016 # expanded by the stub
  echo 'while [[ ! -e "$S/park.go" ]]; do sleep 0.05; done' >"$S/hook.park"
  bg park park iphone; local ppid=$BGPID
  wait_for "sim-vault park DD" "$S/events.log" 10 || return
  bg test iphone; local tpid=$BGPID
  sleep 1
  kill -0 "$tpid" 2>/dev/null || fail "test should still be waiting"
  eq "$(count_lines 'sim-vault (status|ensure)')" 1 "only park's status ran while park holds the lock"
  has "$T/test.err" "等 DayDo 模擬器鎖" "test says it waits for the lock"
  : >"$S/park.go"
  wait_exit "$ppid" 10; eq "$WRC" 0 "park rc"
  wait_exit "$tpid" 10; eq "$WRC" 0 "test rc"
  before "sim-vault park-done" "sim-vault ensure .*dd:uitest" "test leased only after park finished"
  has "$S/events.log" "xcodebuild test .*id=UDID-NEW" "test uses the UDID from its own ensure (restored device)"
  eq "$(last_line "$T/park.out")" "park rc=0" "park rc line"
}

t_test_first_park_waits() {
  : >"$S/xcodebuild.block"
  bg test iphone; local tpid=$BGPID
  wait_for "^xcodebuild test" "$S/events.log" 10 || return
  bg park park iphone; local ppid=$BGPID
  sleep 1
  kill -0 "$ppid" 2>/dev/null || fail "park should be waiting"
  local n; n="$(wc -l <"$S/events.log")"
  eq "$(tail -n 1 "$S/events.log")" "$(grep '^xcodebuild test' "$S/events.log")" "nothing ran after xcodebuild started (lines: $n)"
  : >"$S/xcodebuild.release"
  wait_exit "$tpid" 10; eq "$WRC" 0 "test rc"
  wait_exit "$ppid" 10; eq "$WRC" 0 "park rc"
  before "xcodebuild-exit" "sim-vault park DD" "park after the test"
  before "sim-vault release .*dd:uitest" "sim-vault park DD" "lease released before park"
  has "$S/events.log" "sim-vault park-done" "parked"
  eq "$(last_line "$T/park.out")" "park rc=0" "park rc line"
}

t_sigkill_shell_child_keeps_lock() {
  : >"$S/xcodebuild.block"
  bg test iphone; local tpid=$BGPID
  wait_for "^xcodebuild test" "$S/events.log" 10 || return
  local xpid; xpid="$(cat "$S/xcodebuild.pid")"
  kill -KILL "$tpid"
  wait "$tpid" 2>/dev/null
  kill -0 "$tpid" 2>/dev/null && fail "uitest.sh still alive after SIGKILL"
  kill -0 "$xpid" 2>/dev/null || fail "stub xcodebuild should survive its parent"
  hasnt "$S/events.log" "sim-vault release" "no release after SIGKILL"
  lock_free && fail "lock must stay held by the orphaned xcodebuild"
  bg park park iphone; local ppid=$BGPID
  sleep 1
  kill -0 "$ppid" 2>/dev/null || fail "park should wait for the orphaned xcodebuild"
  eq "$(tail -n 1 "$S/events.log")" "$(grep '^xcodebuild test' "$S/events.log")" "park did nothing while the child lives"
  : >"$S/xcodebuild.release"
  wait_exit "$ppid" 10; eq "$WRC" 0 "park rc"
  before "xcodebuild-exit" "sim-vault release DD iPhone 18 Pro --lease dd:uitest" "stale dd:uitest released after the child exited"
  before "sim-vault release .*dd:uitest" "sim-vault park-done" "then parked"
  lock_free || fail "lock released once everyone exited"
}

t_up_twice_same_worktree() {
  run -- up iphone; eq "$RC" 0 "first up"; local first; first="$(cat "$T/out")"
  run -- up iphone; eq "$RC" 0 "second up"
  eq "$first" "UDID-AAA" "up prints only the UDID"
  eq "$(cat "$T/out")" "UDID-AAA" "second up prints the same UDID"
  eq "$(cat "$S/leases")" "dd:up:$ROOT" "one shared lease for the worktree"
  run DD_SIM_OWNER=dd:session-b -- up iphone; eq "$RC" 0 "up with DD_SIM_OWNER"
  eq "$(wc -l <"$S/leases" | tr -d ' ')" 2 "DD_SIM_OWNER gives a separate lease"
  lock_free || fail "up leaves the lock free"
}

t_test_allows_own_up_lease() {
  echo "dd:up:$ROOT" >"$S/leases"
  run -- iphone
  eq "$RC" 0 "test runs next to this worktree's own up lease"
  eq "$(cat "$S/leases")" "dd:up:$ROOT" "own lease kept"
}

t_test_refuses_foreign_lease() {
  echo "dd:up:/somewhere/else" >"$S/leases"
  echo "gone:owner" >"$S/stale-lease"
  run -- iphone
  eq "$RC" 8 "rc"
  has "$T/err" "dd:up:/somewhere/else" "names the owner"
  hasnt "$T/err" "gone:owner" "stale lease ignored"
  hasnt "$S/events.log" "xcodebuild" "xcodebuild not called"
  hasnt "$S/events.log" "sim-vault ensure" "no lease taken"
  eq "$(cat "$S/leases")" "dd:up:/somewhere/else" "foreign lease untouched"
  run DD_SIM_OWNER=dd:session-b -- iphone
  eq "$RC" 8 "another session's lease counts as foreign"
}

t_down_releases_and_shuts_down() {
  echo "dd:up:$ROOT" >"$S/leases"
  run -- down iphone
  eq "$RC" 0 "rc"
  before "sim-vault release DD iPhone 18 Pro --lease dd:up:$ROOT" "sim-vault shutdown DD" "release then shutdown"
  has "$S/events.log" "sim-vault shutdown-done" "shut down"
}

t_down_interleaved_lease() {
  echo "dd:up:$ROOT" >"$S/leases"
  # shellcheck disable=SC2016 # expanded by the stub
  echo 'echo intruder >>"$S/leases"' >"$S/hook.shutdown"
  : >"$S/booted"
  run -- down iphone
  eq "$RC" 8 "rc passed on"
  has "$T/err" "intruder" "owner reported"
  has "$S/events.log" "sim-vault shutdown-refused" "sim-vault refused"
  [[ -e "$S/booted" ]] || fail "device must stay booted"
  eq "$(cat "$S/leases")" "intruder" "intruder lease untouched"
}

t_down_missing_device() {
  rm -f "$S/udid"
  run -- down iphone
  eq "$RC" 0 "rc"
  hasnt "$S/events.log" "sim-vault shutdown" "no shutdown for a parked device"
}

t_park_transition_guard() {
  echo 4242 >"$S/pgrep.out"
  echo "/usr/bin/xcodebuild test -project DayDo.xcodeproj -destination platform=iOS Simulator,id=UDID-AAA" >"$S/ps.4242"
  run -- park iphone
  eq "$RC" 8 "rc"
  eq "$(last_line "$T/out")" "park rc=8" "rc line"
  has "$T/err" "舊版" "explains"
  hasnt "$S/events.log" "sim-vault (park|release)" "nothing released or parked"
  echo "/usr/bin/xcodebuild test -destination platform=iOS Simulator,id=OTHER" >"$S/ps.4242"
  run -- park iphone
  eq "$RC" 0 "xcodebuild on another device does not block park"
  has "$S/events.log" "sim-vault park-done" "parked"
}

t_park_rc_passthrough() {
  echo 9 >"$S/rc.park"
  run -- park iphone
  eq "$RC" 9 "rc"
  eq "$(last_line "$T/out")" "park rc=9" "rc line"
  rm -f "$S/rc.park"
  echo "dd:up:/other" >"$S/leases"
  run -- park iphone
  eq "$RC" 8 "foreign lease: sim-vault's 8 passed on"
  eq "$(last_line "$T/out")" "park rc=8" "rc line"
  eq "$(cat "$S/leases")" "dd:up:/other" "foreign lease not cleared"
  hasnt "$S/events.log" "release .*dd:up:/other" "never releases someone else's lease"
}

t_park_lock_timeout() {
  mkdir -p "$(dirname "$LOCK")"
  "$REAL_PY" -I -c '
import fcntl, os, sys, time
fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT, 0o644)
fcntl.flock(fd, fcntl.LOCK_EX)
os.write(fd, b"pid=%d mode=test name=x owner=holder\n" % os.getpid())
open(sys.argv[2], "w").close()
time.sleep(30)
' "$LOCK" "$T/held" &
  local hpid=$!; BG_PIDS="$BG_PIDS $hpid"
  local i=0; while [[ ! -e "$T/held" && $i -lt 100 ]]; do sleep 0.05; i=$((i + 1)); done
  run DD_UITEST_LOCK_WAIT=1 -- park iphone
  kill "$hpid" 2>/dev/null; wait "$hpid" 2>/dev/null
  eq "$RC" 8 "rc"
  eq "$(last_line "$T/out")" "park rc=8" "rc line on lock timeout"
  has "$T/err" "owner=holder" "names the holder"
  hasnt "$S/events.log" "sim-vault" "nothing called"
}

t_old_sim_vault() {
  : >"$S/old-vault"
  local m
  for m in "" up down park; do
    if [[ -n "$m" ]]; then run -- "$m" iphone; else run -- iphone; fi
    eq "$RC" 2 "${m:-test}: rc"
    has "$T/err" "版本過舊（缺 shutdown）.*aghub-cli source sync audichuang/audi-skill -g --update --yes" "${m:-test}: message"
  done
  eq "$(last_line "$T/out")" "park rc=2" "park prints its rc"
  eq "$(wc -l <"$S/events.log" | tr -d ' ')" 0 "no sim-vault command ran"
  rm -f "$S/old-vault"
  : >"$S/no-trim"
  run DD_PARK_TRIM=1 -- park iphone
  eq "$RC" 2 "trim without support: rc"
  has "$T/err" "trim-posterboard" "trim message"
  rm -f "$S/no-trim"
  run -- park iphone
  hasnt "$S/events.log" "trim-posterboard" "no trim by default"
  echo UDID-AAA >"$S/udid"
  run DD_PARK_TRIM=1 -- park iphone
  eq "$RC" 0 "trim park rc"
  has "$S/events.log" "sim-vault park DD iPhone 18 Pro --shutdown --missing-ok --trim-posterboard" "trim flag passed"
}

t_no_sim_vault() {
  set_env "$STUB_NOVAULT"
  run -- park iphone
  eq "$RC" 2 "rc"
  has "$T/err" "找不到 sim-vault" "message"
  eq "$(last_line "$T/out")" "park rc=2" "rc line"
  run -- build
  eq "$RC" 0 "build needs no sim-vault"
}

t_temp_device_missing() {
  rm -f "$S/udid"; : >"$S/archive"
  run -- "DD tmp x"
  eq "$RC" 2 "rc"
  hasnt "$S/events.log" "sim-vault ensure" "temp device is not restored"
  run -- park "DD tmp x"
  eq "$RC" 2 "park refuses temp devices"
}

t_test_waits_for_other_xcodebuild() {
  echo 999 >"$S/pgrep.out"
  bg test iphone; local tpid=$BGPID
  sleep 0.7
  kill -0 "$tpid" 2>/dev/null || fail "should wait for the other xcodebuild"
  hasnt "$S/events.log" "sim-vault ensure" "no lease while waiting"
  rm -f "$S/pgrep.out"
  wait_exit "$tpid" 10; eq "$WRC" 0 "rc"
  has "$T/test.err" "有別的 xcodebuild 在跑" "says so"
}

run_record() {
  RC=0
  "${ENVCMD[@]}" bash --noprofile --norc "$RECORD" iphone Flow/testX "$T/rec/cal" >"$T/out" 2>"$T/err" || RC=$?
}

t_record_handshake() {
  rm -f "$S/udid"; : >"$S/archive"
  run_record
  eq "$RC" 0 "rc"
  has "$S/events.log" "xcrun simctl io UDID-NEW recordVideo" "records the device uitest.sh leased"
  before "sim-vault ensure .*dd:uitest" "recordVideo" "lease before recording"
  before "recordVideo" "^xcodebuild test" "recording before the test"
  before "xcodebuild-exit" "rec-stopped" "recording stops after the test"
  before "rec-stopped" "sim-vault release .*dd:uitest" "lease released only after recordVideo exited"
  [[ -e "$T/rec/cal.mp4" ]] || fail "video file"
  has "$T/rec/cal.log" "TEST SUCCEEDED" "log"
  eq "$(find "$T/tmp" -maxdepth 1 -name 'dd-record.*' | wc -l | tr -d ' ')" 0 "handshake dir removed"
}

t_record_recorder_fails() {
  : >"$S/rec.fail"
  local start=$SECONDS
  run_record
  [[ "$RC" != 0 ]] || fail "rc should be non-zero"
  hasnt "$S/events.log" "^xcodebuild" "no test without a recording"
  has "$S/events.log" "sim-vault release .*dd:uitest" "lease released"
  (( SECONDS - start < 8 )) || fail "took $((SECONDS - start)) s"
}

t_record_test_refused() {
  echo "dd:up:/other" >"$S/leases"
  run_record
  eq "$RC" 8 "uitest.sh's rc passed on"
  hasnt "$S/events.log" "recordVideo" "nothing recorded"
}

t_never_bypasses_sim_vault() {
  # Over every test above: the wrappers never shut down or delete a device themselves.
  if grep -hE "^xcrun simctl (shutdown|delete|erase|boot)" "$WORK"/t-*/state/events.log; then
    fail "xcrun simctl shutdown/delete/erase/boot called directly"
  fi
  return 0
}

ALL="t_stubs_on_path t_test_run_basic t_park_first_test_waits t_test_first_park_waits
t_sigkill_shell_child_keeps_lock t_up_twice_same_worktree t_test_allows_own_up_lease
t_test_refuses_foreign_lease t_down_releases_and_shuts_down t_down_interleaved_lease
t_down_missing_device t_park_transition_guard t_park_rc_passthrough t_park_lock_timeout
t_old_sim_vault t_no_sim_vault t_temp_device_missing t_test_waits_for_other_xcodebuild
t_record_handshake t_record_recorder_fails t_record_test_refused t_never_bypasses_sim_vault"
SELECTED="${*:-$ALL}"
total=0
for CURRENT in $SELECTED; do
  setup
  before_fails=$FAILS
  "$CURRENT"
  total=$((total + 1))
  if (( FAILS == before_fails )); then echo "ok   $CURRENT"; else echo "FAIL $CURRENT"; fi
done
echo
if (( FAILS > 0 )); then
  echo "$FAILS assertion(s) failed in:$FAILED_TESTS"
  exit 1
fi
echo "all $total tests passed"
