#!/usr/bin/env bash
# Tests for ios/scripts/uitest.sh and record-uitest.sh against stub sim-vault, xcrun,
# xcodebuild, pgrep and ps, plus an integration group against the real sim-vault 4.0 source
# (with fake xcrun, fake xcodebuild, temp HOME and temp SIM_VAULT_DIR).
# Nothing here touches a real simulator: HOME, TMPDIR and PATH point into a scratch directory,
# and PATH is <stubs>:/usr/bin:/bin with BASH_ENV unset.
#
#   bash ios/scripts/tests/test_uitest_sh.sh [test_name...]
set -uo pipefail

SCRIPTS="$(cd "$(dirname "$0")/.." && pwd -P)"
ROOT="$(cd "$SCRIPTS/../.." && pwd -P)"
UITEST="$SCRIPTS/uitest.sh"
RECORD="$SCRIPTS/record-uitest.sh"
REAL_PY="$(command -v python3)"
SIM_VAULT_SRC="${SIM_VAULT_SRC:-/Users/audichuang/Project/sim-vault/src}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/dd-uitest-test.XXXXXX")"
STUB="$WORK/stub"
STUB_NOVAULT="$WORK/stub-novault"
STUB_REALVAULT="$WORK/stub-realvault"
FAILS=0
FAILED_TESTS=""
CURRENT=""
BG_PIDS=""

kill_test_procs() {
  local pattern="${1:-}" extra="" p pid
  for p in "${S:-}/xcodebuild.pid" "${S:-}/rec.pid"; do
    if [[ -f "$p" ]]; then
      pid="$(cat "$p" 2>/dev/null || true)"
      [[ -z "$pid" ]] || extra="$extra $pid"
    fi
  done
  local roots="$BG_PIDS $extra"
  BG_PIDS=""
  "$REAL_PY" -c '
import os, signal, subprocess, sys
pattern = sys.argv[1]
roots = {int(x) for x in sys.argv[2:] if x.isdigit()}
out = subprocess.run(["/bin/ps", "-axww", "-o", "pid=,ppid=,args="],
                     capture_output=True, text=True).stdout
children = {}
ppid_of = {}
args_of = {}
for line in out.splitlines():
    parts = line.split(None, 2)
    if len(parts) == 3 and parts[0].isdigit() and parts[1].isdigit():
        p, pp, a = int(parts[0]), int(parts[1]), parts[2]
        ppid_of[p] = pp
        children.setdefault(pp, []).append(p)
        args_of[p] = a
# Never kill ourselves or any ancestor up to PID 1.
keep = set()
cur = os.getpid()
while cur and cur not in keep:
    keep.add(cur)
    cur = ppid_of.get(cur, 0)
victims = set()
stack = list(roots)
while stack:
    p = stack.pop()
    if p in victims or p in keep:
        continue
    victims.add(p)
    stack.extend(children.get(p, ()))
if pattern:
    for p, a in args_of.items():
        if pattern in a and p not in keep:
            stack.append(p)
    while stack:
        p = stack.pop()
        if p in victims or p in keep:
            continue
        victims.add(p)
        stack.extend(children.get(p, ()))
for p in victims:
    try:
        os.kill(p, signal.SIGKILL)
    except OSError:
        pass
' "$pattern" $roots 2>/dev/null || true
}

cleanup() {
  kill_test_procs "$WORK"
  chmod -R u+w "$WORK" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

# ---------------------------------------------------------------- stubs
mkdir -p "$STUB" "$STUB_NOVAULT" "$STUB_REALVAULT"

cat >"$STUB/sim-vault" <<'EOF'
#!/bin/bash
# Stub sim-vault 4.0. State in $STUB_STATE: udid (device present), archive (restorable),
# booted, leases (one owner per line), sessions (scope<TAB>owner), hook.<cmd> (sourced first),
# rc.<cmd> (forced exit), rc.teardown (forced run teardown exit).
S="$STUB_STATE"
ev() { printf '%s\n' "$*" >>"$S/events.log"; }
cmd="${1:-}"
if [[ "$cmd" == --version ]]; then
  if [[ -e "$S/no-version" ]]; then
    echo "sim-vault: error: unrecognized arguments: --version" >&2; exit 2
  fi
  if [[ -e "$S/old-version" ]]; then
    echo "sim-vault $(cat "$S/old-version")"
  else
    echo "sim-vault 4.0.0"
  fi
  exit 0
fi
case " $* " in
  *" --help "*|*" -h "*)
    if [[ "$cmd" == run && -e "$S/no-run" ]]; then
      echo "sim-vault: error: argument command: invalid choice: 'run'" >&2; exit 2
    fi
    if [[ "$cmd" == shutdown && -e "$S/old-vault" ]]; then
      echo "sim-vault: error: argument command: invalid choice: 'shutdown'" >&2; exit 2
    fi
    if [[ "$cmd" == run ]]; then
      echo "usage: sim-vault run <name> --lease PREFIX [--boot] [--deny-other-leases] [--allow-lease OWNER] [--wait WAIT] [--result-file FILE] -- <cmd...>"
    elif [[ "$cmd" == ensure ]]; then
      echo "usage: sim-vault ensure [--boot] [--lease OWNER] [--lease-scope DIR] [--lease-prefix PREFIX] [--deny-other-leases] [--allow-lease OWNER] name"
    elif [[ "$cmd" == park ]]; then
      echo "usage: sim-vault park [--shutdown] [--missing-ok] [--trim-posterboard] name"
    fi
    exit 0 ;;
esac
shift
name="${1:-}"; shift || true
# Separate run's `-- <cmd...>` from its flags for clean event logging.
flags=()
child_cmd=()
if [[ "$cmd" == run ]]; then
  in_child=0
  for arg in "$@"; do
    if [[ $in_child == 1 ]]; then
      child_cmd+=("$arg")
    elif [[ "$arg" == -- ]]; then
      in_child=1
    else
      flags+=("$arg")
    fi
  done
  ev "sim-vault run $name ${flags[*]}"
else
  flags=("$@")
  ev "sim-vault $cmd $name $*"
fi
if [[ -e "$S/hook.$cmd" ]]; then . "$S/hook.$cmd"; fi

owner=""; scope=""; prefix=""; deny=0; allow=""; as_json=0; result_file=""
i=0
while (( i < ${#flags[@]} )); do
  case "${flags[$i]}" in
    --lease) owner="${flags[$((i+1))]}"; i=$((i+2)) ;;
    --lease-scope) scope="${flags[$((i+1))]}"; i=$((i+2)) ;;
    --lease-prefix) prefix="${flags[$((i+1))]}"; i=$((i+2)) ;;
    --allow-lease) allow="$allow"$'\n'"${flags[$((i+1))]}"; i=$((i+2)) ;;
    --deny-other-leases) deny=1; i=$((i+1)) ;;
    --json) as_json=1; i=$((i+1)) ;;
    --result-file) result_file="${flags[$((i+1))]}"; i=$((i+2)) ;;
    --wait) i=$((i+2)) ;;
    *) i=$((i+1)) ;;
  esac
done

leases() { grep -v '^$' "$S/leases" 2>/dev/null || true; }
session_for_scope() {
  local sc="$1"
  [[ -e "$S/sessions" ]] || return 0
  awk -F '\t' -v s="$sc" '$1 == s { print $2; exit }' "$S/sessions"
}
set_session() {
  local sc="$1" tok="$2"
  if [[ -e "$S/sessions" ]]; then
    awk -F '\t' -v s="$sc" '$1 != s' "$S/sessions" >"$S/sessions.tmp"
    mv "$S/sessions.tmp" "$S/sessions"
  fi
  printf '%s\t%s\n' "$sc" "$tok" >>"$S/sessions"
}
del_session() {
  local sc="$1"
  [[ -e "$S/sessions" ]] || return 0
  awk -F '\t' -v s="$sc" '$1 != s' "$S/sessions" >"$S/sessions.tmp"
  mv "$S/sessions.tmp" "$S/sessions"
}
legacy_owner_for_scope() {
  local sc="$1" alias
  case "$name" in
    "DD iPhone 18 Pro") alias=iphone ;;
    "DD iPad Pro 11") alias=ipad ;;
    *) alias="$(printf '%s' "$name" | tr -c 'A-Za-z0-9' '_')" ;;
  esac
  local f="$HOME/Library/Developer/CoreSimulator/sim-vault/owners/daydo-$(printf '%s' "$sc" | shasum | cut -c1-40)-$alias"
  [[ -e "$f" ]] || return 0
  cat "$f"
}
write_result() {
  local stage="$1" rc="$2" child_rc="$3" td="$4"
  local cjson="$child_rc"
  [[ "$cjson" == "-" ]] && cjson="null"
  if [[ -n "$result_file" ]]; then
    printf '{"stage":"%s","childRc":%s,"teardown":"%s","rc":%s}\n' "$stage" "$cjson" "$td" "$rc" >"$result_file"
  fi
  echo "sim-vault-run: stage=${stage} rc=${rc} childRc=${child_rc} teardown=${td}" >&2
}
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
  [[ "$cmd" != run ]] || write_result acquire "$rc" - -
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
  whoami)
    anchor_json='{"pid":1234,"comm":"claude"}'
    [[ ! -e "$S/null-anchor" ]] || anchor_json="null"
    tok="$(session_for_scope "$scope")"
    if [[ -n "$tok" ]] && leases | grep -qxF -- "$tok"; then
      lease_json="\"$tok\""
    else
      tok=""; lease_json="null"
    fi
    if [[ $as_json == 1 ]]; then
      printf '{"ok":true,"anchor":%s,"lease":%s}\n' "$anchor_json" "$lease_json"
    else
      echo "anchor: $anchor_json" >&2
      [[ -z "$tok" ]] || printf '%s\n' "$tok"
    fi
    ;;
  ensure)
    if [[ "$owner" == auto ]]; then
      existing="$(session_for_scope "$scope")"
      if [[ -n "$existing" ]] && leases | grep -qxF -- "$existing"; then
        echo "error (exit 8, busy): '$name' already has session lease $existing for this scope" >&2
        exit 8
      fi
      leg="$(legacy_owner_for_scope "$scope")"
      if [[ -n "$leg" ]] && leases | grep -qxF -- "$leg"; then
        echo "error (exit 8, busy): '$name' has a legacy lease $leg recorded for this scope" >&2
        exit 8
      fi
    fi
    if [[ ! -e "$S/udid" ]]; then
      if [[ -e "$S/archive" ]]; then
        echo "UDID-NEW" >"$S/udid"; ev "sim-vault restored UDID-NEW"
      else
        echo "error (exit 3, no-archive): no archive for '$name'" >&2; exit 3
      fi
    fi
    if [[ "$owner" == auto ]]; then
      owner="${prefix:-auto}:$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
      set_session "$scope" "$owner"
      echo "lease: $owner" >&2
    fi
    if [[ $deny == 1 ]]; then
      others=""
      while IFS= read -r o; do
        [[ "$o" == "$owner" ]] && continue
        case $'\n'"$allow"$'\n' in *$'\n'"$o"$'\n'*) continue ;; esac
        others="${others:+$others,}$o"
      done < <(leases)
      if [[ -n "$others" ]]; then
        echo "error (exit 8, busy): '$name' is leased by $others" >&2
        ev "sim-vault ensure-denied"; exit 8
      fi
    fi
    if [[ -n "$owner" ]] && ! leases | grep -qxF -- "$owner"; then
      printf '%s\n' "$owner" >>"$S/leases"
    fi
    : >"$S/booted"
    cat "$S/udid"
    ;;
  run)
    if [[ ! -e "$S/udid" ]]; then
      if [[ -e "$S/archive" ]]; then
        echo "UDID-NEW" >"$S/udid"; ev "sim-vault restored UDID-NEW"
      else
        echo "error (exit 3, no-archive): no archive for '$name'" >&2
        write_result acquire 3 - -
        exit 3
      fi
    fi
    held_owner="${owner}:$$-abc123"
    if [[ $deny == 1 ]]; then
      others=""
      while IFS= read -r o; do
        [[ "$o" == "$held_owner" ]] && continue
        case $'\n'"$allow"$'\n' in *$'\n'"$o"$'\n'*) continue ;; esac
        others="${others:+$others,}$o"
      done < <(leases)
      if [[ -n "$others" ]]; then
        echo "error (exit 8, busy): '$name' is leased by $others" >&2
        ev "sim-vault run-denied"
        write_result acquire 8 - -
        exit 8
      fi
    fi
    printf '%s\n' "$held_owner" >>"$S/leases"
    : >"$S/booted"
    udid="$(cat "$S/udid")"
    run_child_pid=""
    trap 'if [[ -n "$run_child_pid" ]]; then kill -TERM "$run_child_pid" 2>/dev/null || true; fi' TERM
    SIM_VAULT_NAME="$name" SIM_VAULT_UDID="$udid" SIM_VAULT_LEASE="$held_owner" SIM_VAULT_LEASE_FD=9 \
      "${child_cmd[@]}" &
    run_child_pid=$!
    child_rc=0
    wait "$run_child_pid" || child_rc=$?
    # If interrupted by TERM trap, keep waiting until child finishes.
    while kill -0 "$run_child_pid" 2>/dev/null; do
      wait "$run_child_pid" || child_rc=$?
    done
    run_child_pid=""
    if [[ -e "$S/leases" ]]; then
      grep -vxF -- "$held_owner" "$S/leases" >"$S/leases.tmp" || true
      mv "$S/leases.tmp" "$S/leases"
    fi
    ev "sim-vault run-teardown $held_owner"
    if [[ -e "$S/rc.teardown" ]]; then
      td_rc="$(cat "$S/rc.teardown")"
      if [[ $child_rc != 0 ]]; then
        echo "warning: teardown failed (exit $td_rc, held-by-other)" >&2
        write_result child "$child_rc" "$child_rc" held-by-other
        exit "$child_rc"
      fi
      echo "error (exit $td_rc, held-by-other): lease still held" >&2
      write_result teardown "$td_rc" "$child_rc" held-by-other
      exit "$td_rc"
    fi
    write_result child "$child_rc" "$child_rc" ok
    exit "$child_rc"
    ;;
  release)
    action="no-lease"
    rel_owner="$owner"
    if [[ "$owner" == auto ]]; then
      rel_owner="$(session_for_scope "$scope")"
      del_session "$scope"
    fi
    if [[ -n "$rel_owner" && -e "$S/leases" ]] && grep -qxF -- "$rel_owner" "$S/leases"; then
      action="released"
      grep -vxF -- "$rel_owner" "$S/leases" >"$S/leases.tmp" || true
      mv "$S/leases.tmp" "$S/leases"
    fi
    if [[ $as_json == 1 ]]; then
      ljson="null"
      [[ -z "$rel_owner" ]] || ljson="\"$rel_owner\""
      printf '{"ok":true,"action":"%s","lease":%s,"shutdown":false,"remaining":[]}\n' "$action" "$ljson"
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
if [[ -e "$S/xcodebuild.ignore_term" ]]; then
  trap '' TERM INT HUP
  echo $$ >"$S/xcodebuild.pid"
  echo $PPID >"$S/xcodebuild.ppid"
  printf '%s\n' "xcodebuild $*" >>"$S/events.log"
  while [[ -d "$S" ]]; do sleep 0.05; done
  exit 0
fi
if [[ -e "$S/xcodebuild.slow_term" ]]; then
  delay="$(cat "$S/xcodebuild.slow_term")"
  trap '' INT
  trap 'sleep "$delay"; printf "%s\n" "xcodebuild-slow-exit" >>"$S/events.log"; exit 143' TERM
  echo $$ >"$S/xcodebuild.pid"
  echo $PPID >"$S/xcodebuild.ppid"
  printf '%s\n' "xcodebuild $*" >>"$S/events.log"
  while [[ -d "$S" ]]; do sleep 0.05; done
  exit 0
fi
printf '%s\n' "xcodebuild $*" >>"$S/events.log"
echo $$ >"$S/xcodebuild.pid"
echo $PPID >"$S/xcodebuild.ppid"
if [[ -e "$S/hook.xcodebuild" ]]; then . "$S/hook.xcodebuild"; fi
if [[ -e "$S/xcodebuild.sleep" ]]; then sleep "$(cat "$S/xcodebuild.sleep")"; fi
if [[ -e "$S/xcodebuild.block" ]]; then
  while [[ -d "$S" && ! -e "$S/xcodebuild.release" ]]; do sleep 0.05; done
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
  echo $$ >"$S/rec.pid"
  : >"$out"
  echo "Recording started" >&2
  if [[ -e "$S/rec.die" ]]; then
    sleep 0.2; echo "recordVideo: device disconnected" >&2
    printf '%s\n' "rec-died" >>"$S/events.log"; exit 1
  fi
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

# Real sim-vault 4.0 wrapper + fake xcrun for integration tests (never touches real devices).
cat >"$STUB_REALVAULT/sim-vault" <<EOF
#!/bin/bash
if [[ "\$(command -v xcrun)" != "$STUB_REALVAULT/xcrun" ]]; then
  echo "SAFETY ABORT: xcrun is not the fake one: \$(command -v xcrun)" >&2
  exit 99
fi
case "\$HOME" in "$WORK"/*) ;; *)
  echo "SAFETY ABORT: HOME is not under scratch dir: \$HOME" >&2
  exit 99 ;;
esac
PYTHONPATH="$SIM_VAULT_SRC" exec "$REAL_PY" -c 'import sys,sim_vault; sys.argv[0]="sim-vault"; sys.exit(sim_vault.main())' "\$@"
EOF

cat >"$STUB_REALVAULT/xcrun" <<EOF
#!$REAL_PY
import json, os, plistlib, signal, sys, time

args = sys.argv[1:]
state_dir = os.environ["STUB_STATE"]
with open(os.path.join(state_dir, "events.log"), "a") as h:
    h.write("xcrun " + " ".join(args) + "\n")
if args[:1] != ["simctl"]:
    sys.exit(0)
args = args[1:]
dset = os.path.join(os.environ["HOME"], "Library/Developer/CoreSimulator/Devices")
if args[:1] == ["--set"]:
    dset, args = args[1], args[2:]
sub, rest = args[0], args[1:]

def devices():
    out = []
    if not os.path.isdir(dset):
        return out
    for u in sorted(os.listdir(dset)):
        p = os.path.join(dset, u, "device.plist")
        if os.path.exists(p):
            with open(p, "rb") as f:
                out.append(plistlib.load(f))
    return out

def save(d):
    p = os.path.join(dset, d["UDID"], "device.plist")
    with open(p, "wb") as f:
        plistlib.dump(d, f)

def find(u):
    for d in devices():
        if d["UDID"] == u or d["name"] == u:
            return d
    return None

def fail(msg, rc=164):
    sys.stderr.write(msg + "\n")
    sys.exit(rc)

if sub == "list":
    what = next((x for x in rest if x in ("devices", "runtimes", "devicetypes")), "devices")
    if what == "devices":
        out = {"devices": {}}
        for d in devices():
            if "available" in rest and not d.get("fakeAvailable", True):
                continue
            out["devices"].setdefault(d["runtime"], []).append({
                "name": d["name"], "udid": d["UDID"],
                "state": d.get("fakeState", "Shutdown"),
                "isAvailable": d.get("fakeAvailable", True),
                "dataPath": os.path.join(dset, d["UDID"], "data"),
            })
        print(json.dumps(out))
    elif what == "runtimes":
        print(json.dumps({"runtimes": [{
            "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-2",
            "isAvailable": True, "version": "27.2", "name": "iOS 27.2",
        }]}))
    else:
        print(json.dumps({"devicetypes": []}))
    sys.exit(0)

if sub == "boot":
    d = find(rest[0])
    if not d:
        fail("Invalid device: " + rest[0])
    if d.get("fakeState", "Shutdown") != "Shutdown":
        fail("Unable to boot device in current state: " + d["fakeState"], 149)
    d["fakeState"] = "Booted"
    save(d)
    sys.exit(0)

if sub == "bootstatus":
    d = find(rest[0])
    if not d:
        fail("Invalid device: " + rest[0])
    d["fakeState"] = "Booted"
    save(d)
    sys.exit(0)

if sub == "shutdown":
    d = find(rest[0])
    if not d:
        fail("Invalid device: " + rest[0])
    if d.get("fakeState", "Shutdown") == "Shutdown":
        fail("Unable to shutdown device in current state: Shutdown", 149)
    d["fakeState"] = "Shutdown"
    save(d)
    sys.exit(0)

if sub == "io" and len(rest) >= 2 and rest[1] == "recordVideo":
    if os.path.exists(os.path.join(state_dir, "rec.fail")):
        fail("recordVideo: cannot record", 1)
    out = rest[-1]
    stopped = [False]
    def on_int(_s, _f):
        stopped[0] = True
    signal.signal(signal.SIGINT, on_int)
    with open(os.path.join(state_dir, "rec.pid"), "w") as f:
        f.write(str(os.getpid()) + "\n")
    open(out, "wb").close()
    sys.stderr.write("Recording started\n")
    sys.stderr.flush()
    if os.path.exists(os.path.join(state_dir, "rec.die")):
        time.sleep(0.2)
        sys.stderr.write("recordVideo: device disconnected\n")
        sys.stderr.flush()
        with open(os.path.join(state_dir, "events.log"), "a") as h:
            h.write("rec-died\n")
        sys.exit(1)
    while not stopped[0]:
        time.sleep(0.05)
    time.sleep(0.1)
    with open(os.path.join(state_dir, "events.log"), "a") as h:
        h.write("rec-stopped\n")
    sys.exit(0)

fail("unknown subcommand " + sub)
EOF

chmod +x "$STUB"/* "$STUB_REALVAULT"/*
ln -s "$REAL_PY" "$STUB/python3"
for f in xcodebuild xcrun pgrep ps python3; do ln -s "$STUB/$f" "$STUB_NOVAULT/$f"; done
for f in xcodebuild pgrep ps python3; do ln -s "$STUB/$f" "$STUB_REALVAULT/$f"; done

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
  ENVCMD=(env -u BASH_ENV -u DD_SIM_OWNER -u DD_PARK_TRIM -u DD_UITEST_RECORD
    -u DD_UITEST_LOCK_PID -u DD_UITEST_LOCK_FD -u DD_UITEST_LOCK_RC -u DD_UITEST_KILL_AFTER
    -u CLAUDE_PID -u CLAUDE_CODE_SESSION_ID -u CODEX_THREAD_ID -u SIM_VAULT_ANCHOR_PID
    HOME="$T/home" TMPDIR="$T/tmp" STUB_STATE="$S"
    DD_UITEST_POLL=0.05 DD_UITEST_LOCK_WAIT=30
    PATH="$1:/usr/bin:/bin")
}
setup_realvault() {
  mkdir -p "$T/vault" "$T/home/Library/Developer/CoreSimulator/Devices/UDID-REAL-001/data/Library"
  "$REAL_PY" -c '
import os, plistlib, sys
p = os.path.join(sys.argv[1], "device.plist")
plistlib.dump({
    "UDID": "UDID-REAL-001",
    "name": "DD iPhone 18 Pro",
    "runtime": "com.apple.CoreSimulator.SimRuntime.iOS-27-2",
    "deviceType": "com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro",
    "fakeState": "Shutdown",
    "fakeAvailable": True,
}, open(p, "wb"))
' "$T/home/Library/Developer/CoreSimulator/Devices/UDID-REAL-001"
  ENVCMD=(env -u BASH_ENV -u DD_SIM_OWNER -u DD_PARK_TRIM -u DD_UITEST_RECORD
    -u DD_UITEST_LOCK_PID -u DD_UITEST_LOCK_FD -u DD_UITEST_LOCK_RC -u DD_UITEST_KILL_AFTER
    -u CLAUDE_PID -u CLAUDE_CODE_SESSION_ID -u CODEX_THREAD_ID
    HOME="$T/home" TMPDIR="$T/tmp" STUB_STATE="$S"
    SIM_VAULT_DIR="$T/vault" SIM_VAULT_HISTORY="$T/history.jsonl"
    SIM_VAULT_ANCHOR_PID="$$"
    DD_UITEST_POLL=0.05 DD_UITEST_LOCK_WAIT=30
    PATH="$STUB_REALVAULT:/usr/bin:/bin")
}
realvault_leases() {
  "${ENVCMD[@]}" sim-vault status "DD iPhone 18 Pro" --json | "$REAL_PY" -c '
import json, sys
s = json.load(sys.stdin)
for l in s.get("leases") or []:
    if not l.get("stale"):
        print(l.get("owner") or "")
'
}
realvault_state() {
  "${ENVCMD[@]}" sim-vault status "DD iPhone 18 Pro" --json | "$REAL_PY" -c '
import json, sys
print(json.load(sys.stdin).get("state") or "")
'
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
# Gate: refuse to run anything unless every tool the scripts call resolves to a stub.
check_stubs() {
  local T="$WORK/gate" S="$WORK/gate" out
  mkdir -p "$T"
  set_env "$STUB"
  out="$("${ENVCMD[@]}" bash --noprofile --norc -c 'command -v sim-vault xcrun xcodebuild pgrep ps python3')"
  if [[ "$(printf '%s\n' "$out" | grep -c "^$STUB/")" != 6 ]]; then
    echo "stub PATH check failed, not running tests:"; echo "$out"; exit 1
  fi
  set_env "$STUB_NOVAULT"
  out="$("${ENVCMD[@]}" bash --noprofile --norc -c 'command -v sim-vault xcrun xcodebuild pgrep ps python3')"
  if [[ "$(printf '%s\n' "$out" | grep -c "^$STUB_NOVAULT/")" != 5 ]] || [[ "$out" == *sim-vault* ]]; then
    echo "no-vault PATH check failed, not running tests:"; echo "$out"; exit 1
  fi
  set_env "$STUB_REALVAULT"
  out="$("${ENVCMD[@]}" bash --noprofile --norc -c 'command -v sim-vault xcrun xcodebuild pgrep ps python3')"
  if [[ "$(printf '%s\n' "$out" | grep -c "^$STUB_REALVAULT/")" != 6 ]]; then
    echo "realvault PATH check failed, not running tests:"; echo "$out"; exit 1
  fi
}
check_stubs


owner_file() { echo "$T/home/Library/Developer/CoreSimulator/sim-vault/owners/daydo-$(printf '%s' "$ROOT" | shasum | cut -c1-40)-iphone"; }
RUN_TEST="sim-vault run DD iPhone 18 Pro --lease dd:run --boot --deny-other-leases"
INSTALL_HINT='uv tool install --force "git\+https://github\.com/audichuang/sim-vault@v4\.0\.0"'

t_test_run_basic() {
  run -- iphone -only-testing:DayDoUITests/X
  eq "$RC" 0 "rc"
  has "$S/events.log" "^sim-vault release DD iPhone 18 Pro --lease dd:uitest --wait 1800$" "clears leftover dd:uitest with --wait 1800 before run"
  has "$S/events.log" "^$RUN_TEST --wait 1800 --result-file " "one run that refuses other leases (no allow without an up)"
  before "sim-vault release DD iPhone 18 Pro --lease dd:uitest --wait 1800" "^$RUN_TEST" "release legacy dd:uitest before run"
  hasnt "$S/events.log" "sim-vault status" "no separate status check before run"
  has "$S/events.log" "xcodebuild test .*id=UDID-AAA .*-only-testing:DayDoUITests/X" "xcodebuild uses the leased UDID"
  before "xcodebuild-exit" "sim-vault run-teardown dd:run:" "teardown after xcodebuild"
  eq "$(cat "$S/leases")" "" "no lease left"
  [[ -e "$S/booted" ]] || fail "device should stay booted after a test"
  lock_free || fail "lock still held after the test"
}

t_test_releases_leftover_dd_uitest() {
  echo "dd:uitest" >"$S/leases"
  run -- iphone
  eq "$RC" 0 "leftover dd:uitest does not block test"
  before "sim-vault release DD iPhone 18 Pro --lease dd:uitest --wait 1800" "^$RUN_TEST" "released with --wait 1800 before run"
  eq "$(cat "$S/leases")" "" "no lease left"
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
  hasnt "$S/events.log" "sim-vault run" "test leased nothing while park holds the lock"
  has "$T/test.err" "等 DayDo 模擬器鎖" "test says it waits for the lock"
  : >"$S/park.go"
  wait_exit "$ppid" 10; eq "$WRC" 0 "park rc"
  wait_exit "$tpid" 10; eq "$WRC" 0 "test rc"
  before "sim-vault park-done" "sim-vault run .*--lease dd:run" "test leased only after park finished"
  has "$S/events.log" "xcodebuild test .*id=UDID-NEW" "test uses the UDID from its own run (restored device)"
  eq "$(last_line "$T/park.out")" "park rc=0" "park rc line"
}

nothing_after_xcodebuild() {
  eq "$(tail -n 1 "$S/events.log")" "$(grep '^xcodebuild test' "$S/events.log")" "$1"
}

t_test_first_park_waits() {
  : >"$S/xcodebuild.block"
  bg test iphone; local tpid=$BGPID
  wait_for "^xcodebuild test" "$S/events.log" 10 || return
  bg park park iphone; local ppid=$BGPID
  sleep 1
  kill -0 "$ppid" 2>/dev/null || fail "park should be waiting"
  nothing_after_xcodebuild "nothing ran after xcodebuild started"
  : >"$S/xcodebuild.release"
  wait_exit "$tpid" 10; eq "$WRC" 0 "test rc"
  wait_exit "$ppid" 10; eq "$WRC" 0 "park rc"
  before "xcodebuild-exit" "sim-vault park DD" "park after the test"
  before "sim-vault run-teardown dd:run:" "sim-vault park DD" "held lease released before park"
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
  hasnt "$S/events.log" "sim-vault run-teardown" "no teardown while xcodebuild lives"
  lock_free && fail "lock must stay held by the orphaned xcodebuild"
  bg park park iphone; local ppid=$BGPID
  bg down down iphone; local dpid=$BGPID
  sleep 1
  kill -0 "$ppid" 2>/dev/null || fail "park should wait for the orphaned xcodebuild"
  kill -0 "$dpid" 2>/dev/null || fail "down should wait for the orphaned xcodebuild"
  nothing_after_xcodebuild "park and down did nothing while the child lives"
  : >"$S/xcodebuild.release"
  wait_exit "$ppid" 10
  wait_exit "$dpid" 10
  before "xcodebuild-exit" "sim-vault park-done" "park only after child exited"
  lock_free || fail "lock released once everyone exited"
}

t_record_sigkill_recorder_keeps_lock() {
  : >"$S/xcodebuild.block"
  "${ENVCMD[@]}" bash --noprofile --norc "$RECORD" iphone Flow/testX "$T/rec/cal" >"$T/out" 2>"$T/err" &
  local wpid=$!; BG_PIDS="$BG_PIDS $wpid"
  wait_for "^xcodebuild test" "$S/events.log" 10 || return
  local upid rpid; upid="$(cat "$S/xcodebuild.ppid")"; rpid="$(cat "$S/rec.pid")"
  BG_PIDS="$BG_PIDS $rpid"
  # Kill the wrapper and child uitest.sh; then let xcodebuild finish: only recordVideo is left.
  kill -KILL "$wpid" "$upid"
  wait "$wpid" 2>/dev/null
  : >"$S/xcodebuild.release"
  wait_for "xcodebuild-exit" "$S/events.log" 10 || return
  kill -0 "$rpid" 2>/dev/null || fail "recordVideo should still be running"
  bg park park iphone; local ppid=$BGPID
  bg down down iphone; local dpid=$BGPID
  sleep 1
  kill -0 "$ppid" 2>/dev/null || fail "park should wait while recordVideo holds the lock"
  kill -0 "$dpid" 2>/dev/null || fail "down should wait while recordVideo holds the lock"
  hasnt "$S/events.log" "sim-vault (park|shutdown)" "nothing parked or shut down"
  kill -KILL "$rpid"
  wait_exit "$ppid" 10
  wait_exit "$dpid" 10
  before "xcodebuild-exit" "sim-vault park-done" "only afterwards"
}

t_up_twice_same_worktree() {
  run -- up iphone; eq "$RC" 0 "first up"
  eq "$(cat "$T/out")" "UDID-AAA" "up prints only the UDID"
  has "$S/events.log" "^sim-vault ensure DD iPhone 18 Pro --boot --lease auto --lease-scope $ROOT --lease-prefix dd:up --wait 1800$" "uses session lease auto"
  local a; a="$(cat "$S/leases")"
  [[ "$a" =~ ^dd:up:[0-9a-f]{8}$ ]] || fail "session owner has prefix and hex8: $a"
  [[ -e "$(owner_file)" ]] && fail "up must no longer write owner file"
  run -- up iphone
  eq "$RC" 8 "second up from the same worktree refused"
  has "$T/err" "DD_SIM_OWNER" "tells how to share"
  eq "$(cat "$S/leases")" "$a" "still one lease"
  run DD_SIM_OWNER=dd:session-b -- up iphone; eq "$RC" 0 "up with DD_SIM_OWNER"
  eq "$(wc -l <"$S/leases" | tr -d ' ')" 2 "separate lease"
  run -- down iphone
  eq "$RC" 8 "A's down does not shut down B's device"
  eq "$(cat "$S/leases")" "dd:session-b" "only A's lease released"
  [[ -e "$S/booted" ]] || fail "device stays booted for B"
  run -- up iphone; eq "$RC" 0 "up works again after down"
  lock_free || fail "up leaves the lock free"
}

t_up_stale_owner_record() {
  mkdir -p "$(dirname "$(owner_file)")"
  echo "dd:up:$ROOT:deadbeef" >"$(owner_file)"
  run -- up iphone
  eq "$RC" 0 "a legacy record whose lease is gone does not block"
  hasnt "$S/leases" "deadbeef" "fresh session owner"
}

t_up_failure_no_owner_file() {
  echo 4 >"$S/rc.ensure"
  run -- up iphone
  eq "$RC" 4 "ensure rc passed on"
  [[ -e "$(owner_file)" ]] && fail "failed up writes no owner file"
  rm -f "$S/rc.ensure"
  run -- up iphone
  eq "$RC" 0 "next up succeeds"
}

t_test_allows_own_up_lease() {
  run -- up iphone
  local a; a="$(cat "$S/leases")"
  run -- iphone
  eq "$RC" 0 "test runs next to this worktree's own up lease"
  has "$S/events.log" "^sim-vault whoami DD iPhone 18 Pro --lease-scope $ROOT --json$" "queries whoami --json"
  has "$S/events.log" "^$RUN_TEST --allow-lease $a --wait 1800" "allows the whoami owner"
  eq "$(cat "$S/leases")" "$a" "own lease kept"
  run DD_SIM_OWNER=dd:me -- iphone
  eq "$RC" 8 "with DD_SIM_OWNER set, the whoami owner is someone else"
  has "$S/events.log" "^$RUN_TEST --allow-lease dd:me --wait 1800" "only DD_SIM_OWNER allowed"
  hasnt "$S/events.log" "--allow-lease dd:me --allow-lease $a" "never allows both"
}

t_null_anchor_and_whoami_failure() {
  local mode_flag
  for mode_flag in null-anchor whoami-fail; do
    : >"$S/events.log"
    rm -f "$S/null-anchor" "$S/rc.whoami" "$S/leases" "$S/sessions" "$S/booted"
    if [[ "$mode_flag" == null-anchor ]]; then : >"$S/null-anchor"; else echo 1 >"$S/rc.whoami"; fi
    # up without DD_SIM_OWNER must refuse (2) and tell user to set DD_SIM_OWNER
    run -- up iphone
    eq "$RC" 2 "$mode_flag: up refuses with 2"
    has "$T/err" "DD_SIM_OWNER" "$mode_flag: up tells user to set DD_SIM_OWNER"
    hasnt "$S/events.log" "^sim-vault ensure " "$mode_flag: up never calls ensure"
    # Even if a session lease exists for this scope, test and down must NOT claim it
    printf '%s\t%s\n' "$ROOT" "dd:up:11223344" >"$S/sessions"
    echo "dd:up:11223344" >"$S/leases"
    : >"$S/booted"
    run -- iphone
    eq "$RC" 8 "$mode_flag: test refuses session lease when anchor is null/unknown"
    hasnt "$S/events.log" "--allow-lease dd:up:11223344" "$mode_flag: test must not pass whoami token"
    run -- down iphone
    eq "$RC" 8 "$mode_flag: down refuses to shut down while session lease exists"
    hasnt "$S/events.log" "sim-vault release .*--lease auto" "$mode_flag: down must not call release --lease auto"
    has "$T/err" "未釋放" "$mode_flag: down says nothing was released"
    eq "$(cat "$S/leases")" "dd:up:11223344" "$mode_flag: other lease untouched"
  done
}

t_test_allows_legacy_owner_file_transition() {
  mkdir -p "$(dirname "$(owner_file)")"
  echo "dd:up:$ROOT:cafebabe" >"$(owner_file)"
  echo "dd:up:$ROOT:cafebabe" >"$S/leases"
  run -- iphone
  eq "$RC" 0 "test allows legacy owner file when whoami is empty"
  has "$S/events.log" "^$RUN_TEST --allow-lease dd:up:$ROOT:cafebabe --wait 1800" "legacy owner passed to --allow-lease"
  run DD_SIM_OWNER=dd:me -- iphone
  eq "$RC" 8 "with DD_SIM_OWNER set, legacy owner file is not allowed"
}

t_test_refuses_foreign_lease() {
  echo "dd:up:/somewhere/else" >"$S/leases"
  run -- iphone
  eq "$RC" 8 "rc"
  has "$T/err" "dd:up:/somewhere/else" "names the owner"
  has "$T/err" "正被別人使用或鎖住" "acquire busy message"
  has "$T/err" 'sim-vault release "DD iPhone 18 Pro" --lease <owner>.*不要清別人仍在用的' "tells how to clear an orphaned lease"
  hasnt "$S/events.log" "xcodebuild" "xcodebuild not called"
  eq "$(cat "$S/leases")" "dd:up:/somewhere/else" "no run lease taken, foreign lease untouched"
}

t_test_foreign_lease_races_run() {
  # A lease taken by a direct `sim-vault ensure` right before ours: refused inside run.
  # shellcheck disable=SC2016 # expanded by the stub
  echo 'echo intruder >>"$S/leases"' >"$S/hook.run"
  run -- iphone
  eq "$RC" 8 "rc"
  has "$T/err" "正被別人使用或鎖住" "acquire busy message"
  hasnt "$S/events.log" "^xcodebuild" "xcodebuild not called"
  eq "$(cat "$S/leases")" "intruder" "no run lease left"
}

t_test_child_and_teardown_rc_8_no_busy_msg() {
  echo 8 >"$S/rc.xcodebuild"
  run -- iphone
  eq "$RC" 8 "child 8 passed through"
  hasnt "$T/err" "正被別人使用或鎖住" "child 8 must not print acquire busy message"
  hasnt "$T/err" "worktree 已不存在" "child 8 must not print orphan hint"
  rm -f "$S/rc.xcodebuild"
  echo 8 >"$S/rc.teardown"
  run -- iphone
  eq "$RC" 8 "teardown 8 passed through"
  hasnt "$T/err" "正被別人使用或鎖住" "teardown 8 must not print acquire busy message"
  hasnt "$T/err" "worktree 已不存在" "teardown 8 must not print orphan hint"
}

t_down_releases_and_shuts_down() {
  run -- up iphone
  run -- down iphone
  eq "$RC" 0 "rc"
  before "sim-vault release DD iPhone 18 Pro --lease auto --lease-scope $ROOT --json" "sim-vault shutdown DD" "release auto then shutdown"
  has "$S/events.log" "sim-vault shutdown-done" "shut down"
  run DD_SIM_OWNER=dd:x -- down iphone
  eq "$RC" 0 "down with DD_SIM_OWNER and no lease"
}

t_down_legacy_owner_file_transition() {
  mkdir -p "$(dirname "$(owner_file)")"
  echo "dd:up:$ROOT:12345678" >"$(owner_file)"
  echo "dd:up:$ROOT:12345678" >"$S/leases"
  : >"$S/booted"
  run -- down iphone
  eq "$RC" 0 "down releases legacy owner file"
  has "$S/events.log" "^sim-vault release DD iPhone 18 Pro --lease auto --lease-scope $ROOT --json$" "tries session release first"
  has "$S/events.log" "^sim-vault release DD iPhone 18 Pro --lease dd:up:$ROOT:12345678$" "falls back to legacy owner"
  [[ -e "$(owner_file)" ]] && fail "legacy owner file removed"
  eq "$(cat "$S/leases")" "" "legacy lease removed"
  has "$S/events.log" "sim-vault shutdown-done" "shut down"
}

t_down_interleaved_lease() {
  echo "dd:me" >"$S/leases"
  # shellcheck disable=SC2016 # expanded by the stub
  echo 'echo intruder >>"$S/leases"' >"$S/hook.shutdown"
  : >"$S/booted"
  run DD_SIM_OWNER=dd:me -- down iphone
  eq "$RC" 8 "rc passed on"
  has "$T/err" "intruder" "owner reported"
  has "$S/events.log" "sim-vault shutdown-refused" "sim-vault refused"
  has "$T/err" "worktree 已不存在" "orphan hint on down"
  [[ -e "$S/booted" ]] || fail "device must stay booted"
  eq "$(cat "$S/leases")" "intruder" "intruder lease untouched"
}

t_down_missing_device() {
  rm -f "$S/udid"
  run -- down iphone
  eq "$RC" 0 "rc"
  hasnt "$S/events.log" "sim-vault shutdown" "no shutdown for a parked device"
}

legacy_xcodebuild() {
  echo 4242 >"$S/pgrep.out"
  echo "/usr/bin/xcodebuild test -project DayDo.xcodeproj -destination platform=iOS Simulator,id=$1" >"$S/ps.4242"
}

t_park_transition_guard() {
  legacy_xcodebuild UDID-AAA
  run -- park iphone
  eq "$RC" 8 "rc"
  eq "$(last_line "$T/out")" "park rc=8" "rc line"
  has "$T/err" "舊版" "explains"
  hasnt "$S/events.log" "sim-vault (park|release)" "nothing released or parked"
  legacy_xcodebuild OTHER
  run -- park iphone
  eq "$RC" 0 "xcodebuild on another device does not block park"
  has "$S/events.log" "sim-vault park-done" "parked"
}

t_down_transition_guard() {
  run DD_SIM_OWNER=dd:me -- up iphone
  legacy_xcodebuild UDID-AAA
  run DD_SIM_OWNER=dd:me -- down iphone
  eq "$RC" 8 "rc"
  has "$T/err" "舊版" "explains"
  hasnt "$S/events.log" "sim-vault (shutdown|release)" "nothing released or shut down"
  [[ -e "$S/booted" ]] || fail "device stays booted"
  legacy_xcodebuild OTHER
  run DD_SIM_OWNER=dd:me -- down iphone
  eq "$RC" 0 "xcodebuild on another device does not block down"
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
  has "$T/err" "worktree 已不存在" "orphan hint on park"
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
  local m
  # 1) No --version support
  : >"$S/no-version"
  for m in "" up down park; do
    if [[ -n "$m" ]]; then run -- "$m" iphone; else run -- iphone; fi
    eq "$RC" 2 "no-version ${m:-test}: rc"
    has "$T/err" "版本過舊.*$INSTALL_HINT" "no-version ${m:-test}: uv install hint"
  done
  eq "$(last_line "$T/out")" "park rc=2" "park prints its rc"
  rm -f "$S/no-version"

  # 2) Version < 4.0.0
  echo "3.1.0" >"$S/old-version"
  for m in "" up down park; do
    if [[ -n "$m" ]]; then run -- "$m" iphone; else run -- iphone; fi
    eq "$RC" 2 "3.1.0 ${m:-test}: rc"
    has "$T/err" "版本過舊.*$INSTALL_HINT" "3.1.0 ${m:-test}: uv install hint"
  done
  rm -f "$S/old-version"

  # 3) Version 4.0.0 but missing `run`
  : >"$S/no-run"
  run -- iphone
  eq "$RC" 2 "no-run: rc"
  has "$T/err" "缺 run.*$INSTALL_HINT" "no-run: message"
  rm -f "$S/no-run"

  eq "$(wc -l <"$S/events.log" | tr -d ' ')" 0 "no sim-vault command ran"
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
  has "$T/err" "找不到 sim-vault.*$INSTALL_HINT" "message gives uv install hint"
  eq "$(last_line "$T/out")" "park rc=2" "rc line"
  run -- build
  eq "$RC" 0 "build needs no sim-vault"
}

t_temp_device_missing() {
  rm -f "$S/udid"; : >"$S/archive"
  run -- "DD tmp x"
  eq "$RC" 2 "rc"
  hasnt "$S/events.log" "sim-vault run" "temp device is not restored"
  run -- up "DD tmp x"
  eq "$RC" 2 "up does not restore a temp device either"
  run -- park "DD tmp x"
  eq "$RC" 2 "park refuses temp devices"
}

t_full_name_is_resident() {
  rm -f "$S/udid"; : >"$S/archive"
  run -- "DD iPhone 18 Pro"
  eq "$RC" 0 "full name restores a parked resident device"
  has "$S/events.log" "sim-vault restored UDID-NEW" "restored"
  run -- up iphone; eq "$RC" 0 "up by alias"
  run -- up "DD iPhone 18 Pro"
  eq "$RC" 8 "full name shares the alias's session scope"
  run -- down "DD iPhone 18 Pro"
  eq "$RC" 0 "down by full name releases the alias's lease and shuts down"
  eq "$(cat "$S/leases")" "" "no lease left"
  run -- park "DD iPhone 18 Pro"
  eq "$RC" 0 "full name can be parked"
  has "$S/events.log" "sim-vault park-done" "parked"
}

t_test_waits_for_other_xcodebuild() {
  echo 999 >"$S/pgrep.out"
  bg test iphone; local tpid=$BGPID
  sleep 0.7
  kill -0 "$tpid" 2>/dev/null || fail "should wait for the other xcodebuild"
  hasnt "$S/events.log" "sim-vault run" "no lease while waiting"
  rm -f "$S/pgrep.out"
  wait_exit "$tpid" 10; eq "$WRC" 0 "rc"
  has "$T/test.err" "有別的 xcodebuild 在跑" "says so"
}

t_teardown_failure_rc() {
  echo 65 >"$S/rc.xcodebuild"; echo 8 >"$S/rc.teardown"
  run -- iphone
  eq "$RC" 65 "test failure wins over teardown failure"
  rm -f "$S/rc.xcodebuild"
  run -- iphone
  eq "$RC" 8 "teardown failure after a passing run"
  hasnt "$T/err" "正被別人使用或鎖住" "teardown failure is not an acquire conflict"
  echo 4 >"$S/rc.run"
  run -- iphone
  eq "$RC" 4 "acquire failure wins over teardown failure"
}

run_record() {
  RC=0
  "${ENVCMD[@]}" bash --noprofile --norc "$RECORD" iphone Flow/testX "$T/rec/cal" >"$T/out" 2>"$T/err" || RC=$?
}

t_record_relative_path() {
  mkdir -p "$T/cwd"
  RC=0
  (cd "$T/cwd" && "${ENVCMD[@]}" bash --noprofile --norc "$RECORD" iphone Flow/testX rec/cal) >"$T/out" 2>"$T/err" || RC=$?
  eq "$RC" 0 "rc"
  has "$S/events.log" "recordVideo .*--force /.*/cwd/rec/cal.mp4$" "recordVideo gets an absolute path"
  [[ -e "$T/cwd/rec/cal.mp4" ]] || fail "video lands relative to the caller's directory"
  [[ -e "$T/cwd/rec/cal.mp4.recordVideo.log" ]] && fail "recorder log removed after a good recording"
  has "$T/err" "^video: rec/cal.mp4" "success line"
}

t_record_basic() {
  rm -f "$S/udid"; : >"$S/archive"
  run_record
  eq "$RC" 0 "rc"
  has "$S/events.log" "xcrun simctl io UDID-NEW recordVideo .*$T/rec/cal.mp4" "records the device uitest.sh leased"
  before "sim-vault run .*--lease dd:run" "recordVideo" "lease before recording"
  before "recordVideo" "^xcodebuild test" "recording before the test"
  before "xcodebuild-exit" "rec-stopped" "recording stops after the test"
  before "rec-stopped" "sim-vault run-teardown dd:run:" "lease released only after recordVideo exited"
  [[ -e "$T/rec/cal.mp4" ]] || fail "video file"
  has "$T/rec/cal.log" "TEST SUCCEEDED" "log"
  [[ -e "$T/rec/cal.mp4.recordVideo.log" ]] && fail "recorder log removed after a good recording"
  has "$T/err" "^video: $T/rec/cal.mp4" "success line"
}

t_record_recorder_dies_midway() {
  : >"$S/rec.die"; echo 1 >"$S/xcodebuild.sleep"
  run_record
  eq "$RC" 11 "recording failure code when the test passed"
  has "$S/events.log" "rec-died" "recorder died during the test"
  has "$T/rec/cal.mp4.recordVideo.log" "device disconnected" "recorder log kept"
  has "$T/err" "cal.mp4.recordVideo.log" "points at the recorder log"
  hasnt "$T/err" "^video: " "no success line with the video path"
  echo 65 >"$S/rc.xcodebuild"
  run_record
  eq "$RC" 65 "test failure code wins"
  hasnt "$T/err" "^video: " "still no video line"
}

t_record_test_failure_rc() {
  echo 65 >"$S/rc.xcodebuild"
  run_record
  eq "$RC" 65 "record passes the test's rc on"
  before "rec-stopped" "sim-vault run-teardown dd:run:" "lease released after recording stopped"
}

t_record_recorder_fails() {
  : >"$S/rec.fail"
  local start=$SECONDS
  run_record
  [[ "$RC" != 0 ]] || fail "rc should be non-zero"
  hasnt "$S/events.log" "^xcodebuild" "no test without a recording"
  has "$S/events.log" "sim-vault run-teardown dd:run:" "lease released"
  (( SECONDS - start < 8 )) || fail "took $((SECONDS - start)) s"
}

t_record_test_refused() {
  echo "dd:up:/other" >"$S/leases"
  run_record
  eq "$RC" 8 "uitest.sh's rc passed on"
  hasnt "$S/events.log" "recordVideo" "nothing recorded"
}

t_record_rm_log_failure_preserves_rc() {
  mkdir -p "$T/ro"
  # Make the directory read-only while xcodebuild runs so `rm -f "$rec_log"` fails in finish().
  printf 'chmod 555 "%s/ro"\n' "$T" >"$S/hook.xcodebuild"
  echo 65 >"$S/rc.xcodebuild"
  run DD_UITEST_RECORD="$T/ro/cal.mp4" -- iphone
  chmod 755 "$T/ro"
  eq "$RC" 65 "failing rm -f rec_log must not replace test failure code 65"
  eq "$(cat "$S/leases")" "" "lease still released"
  rm -f "$T/ro/cal.mp4" "$T/ro/cal.mp4.recordVideo.log" "$S/rc.xcodebuild"
  run DD_UITEST_RECORD="$T/ro/cal.mp4" -- iphone
  chmod 755 "$T/ro"
  eq "$RC" 0 "failing rm -f rec_log must not replace test pass code 0"
  has "$T/err" "無法刪除錄影 log" "reports rm warning"
  eq "$(cat "$S/leases")" "" "lease still released"
}

t_sigterm_stops_child_and_recorder() {
  : >"$S/xcodebuild.block"
  "${ENVCMD[@]}" DD_UITEST_RECORD="$T/rec/sig.mp4" bash --noprofile --norc "$UITEST" iphone >"$T/sig.out" 2>"$T/sig.err" &
  local tpid=$!; BG_PIDS="$BG_PIDS $tpid"
  wait_for "^xcodebuild test" "$S/events.log" 10 || return
  local xpid rpid; xpid="$(cat "$S/xcodebuild.pid")"; rpid="$(cat "$S/rec.pid")"
  kill -TERM "$tpid"
  wait_exit "$tpid" 10
  eq "$WRC" 143 "SIGTERM returns 143"
  kill -0 "$xpid" 2>/dev/null && fail "xcodebuild should have stopped"
  kill -0 "$rpid" 2>/dev/null && fail "recordVideo should have stopped"
  eq "$(cat "$S/leases")" "" "held lease torn down after SIGTERM"
  lock_free || fail "lock free after SIGTERM"
}

# ------------------------------------------------ real sim-vault 4.0 integration
t_real_test_basic() {
  setup_realvault
  run -- iphone -only-testing:DayDoUITests/X
  eq "$RC" 0 "rc"
  has "$S/events.log" "xcodebuild test .*id=UDID-REAL-001 .*-only-testing:DayDoUITests/X" "xcodebuild got real sim-vault UDID"
  has "$T/err" "sim-vault-run: stage=child rc=0 childRc=0 teardown=ok" "real sim-vault run summary"
  eq "$(realvault_leases)" "" "no lease left"
  eq "$(realvault_state)" "Booted" "device stays booted"
  lock_free || fail "lock free"
}

t_real_foreign_lease_refused() {
  setup_realvault
  "${ENVCMD[@]}" sim-vault ensure "DD iPhone 18 Pro" --lease dd:someone-else >/dev/null 2>&1
  run -- iphone
  eq "$RC" 8 "rc"
  has "$T/err" "sim-vault-run: stage=acquire rc=8 childRc=- teardown=-" "run summary reports acquire 8"
  has "$T/err" "dd:someone-else" "names foreign owner"
  has "$T/err" "正被別人使用或鎖住" "busy message printed on acquire 8"
  has "$T/err" "worktree 已不存在" "orphan hint printed"
  hasnt "$S/events.log" "^xcodebuild" "xcodebuild never started"
  eq "$(realvault_leases)" "dd:someone-else" "foreign lease untouched"
}

t_real_xcodebuild_65_and_8() {
  setup_realvault
  echo 65 >"$S/rc.xcodebuild"
  run -- iphone
  eq "$RC" 65 "rc 65 passed through"
  has "$T/err" "sim-vault-run: stage=child rc=65 childRc=65 teardown=ok" "run summary reports child 65"
  hasnt "$T/err" "正被別人使用或鎖住" "no busy message on 65"
  eq "$(realvault_leases)" "" "no lease left"
  echo 8 >"$S/rc.xcodebuild"
  run -- iphone
  eq "$RC" 8 "child rc 8 passed through"
  has "$T/err" "sim-vault-run: stage=child rc=8 childRc=8 teardown=ok" "run summary reports child 8"
  hasnt "$T/err" "正被別人使用或鎖住" "no busy message on child 8"
  eq "$(realvault_leases)" "" "no lease left"
}

t_real_up_twice_same_worktree() {
  setup_realvault
  run -- up iphone
  eq "$RC" 0 "first up"
  eq "$(cat "$T/out")" "UDID-REAL-001" "stdout is only the UDID"
  has "$T/err" "^lease: dd:up:[0-9a-f]{8}$" "token printed on stderr"
  [[ -e "$(owner_file)" ]] && fail "no owner file created"
  run -- up iphone
  eq "$RC" 8 "second up in same worktree refused"
  has "$T/err" "DD_SIM_OWNER" "mentions DD_SIM_OWNER"
}

t_real_up_test_down() {
  setup_realvault
  run -- up iphone; eq "$RC" 0 "up"
  local tok; tok="$(realvault_leases)"
  [[ "$tok" =~ ^dd:up:[0-9a-f]{8}$ ]] || fail "unexpected session token: $tok"
  run -- iphone
  eq "$RC" 0 "test allowed via whoami"
  eq "$(realvault_leases)" "$tok" "session lease preserved after test"
  run DD_SIM_OWNER=dd:other -- iphone
  eq "$RC" 8 "DD_SIM_OWNER does not allow worktree session lease"
  run -- down iphone
  eq "$RC" 0 "down releases session lease and shuts down"
  eq "$(realvault_leases)" "" "no lease left after down"
  eq "$(realvault_state)" "Shutdown" "device shut down"
}

t_real_legacy_owner_file_down() {
  setup_realvault
  local legacy="dd:up:$ROOT:deadbeef"
  "${ENVCMD[@]}" sim-vault ensure "DD iPhone 18 Pro" --boot --lease "$legacy" >/dev/null 2>&1
  mkdir -p "$(dirname "$(owner_file)")"
  printf '%s\n' "$legacy" >"$(owner_file)"
  # Also verify `up` delegates legacy owner-file detection to sim-vault --lease auto.
  run -- up iphone
  eq "$RC" 8 "up refuses while legacy owner file points at live lease"
  has "$T/err" "legacy lease .* recorded for this scope" "sim-vault auto detected legacy owner file"
  run -- down iphone
  eq "$RC" 0 "down releases legacy owner file lease"
  [[ -e "$(owner_file)" ]] && fail "legacy owner file deleted"
  eq "$(realvault_leases)" "" "legacy lease gone"
  eq "$(realvault_state)" "Shutdown" "device shut down"
}

t_real_leftover_dd_uitest_released() {
  setup_realvault
  "${ENVCMD[@]}" sim-vault ensure "DD iPhone 18 Pro" --lease dd:uitest >/dev/null 2>&1
  eq "$(realvault_leases)" "dd:uitest" "precondition: leftover dd:uitest"
  run -- iphone
  eq "$RC" 0 "test released leftover dd:uitest and ran"
  has "$T/err" "sim-vault-run: stage=child rc=0 childRc=0 teardown=ok" "ran via sim-vault run"
  has "$S/events.log" "^xcodebuild test" "xcodebuild ran"
  eq "$(realvault_leases)" "" "no lease left"
}

t_real_record_failure_11() {
  setup_realvault
  : >"$S/rec.die"; echo 1 >"$S/xcodebuild.sleep"
  run_record
  eq "$RC" 11 "recording failure returns 11"
  has "$T/rec/cal.log" "sim-vault-run: stage=child rc=11 childRc=11 teardown=ok" "run summary reports child 11"
  has "$T/rec/cal.mp4.recordVideo.log" "device disconnected" "recorder log kept"
  eq "$(realvault_leases)" "" "no lease left after recording failure"
}

t_real_sigterm_releases_held_lease() {
  setup_realvault
  : >"$S/xcodebuild.block"
  "${ENVCMD[@]}" DD_UITEST_RECORD="$T/rec/sig.mp4" bash --noprofile --norc "$UITEST" iphone >"$T/sig.out" 2>"$T/sig.err" &
  local tpid=$!; BG_PIDS="$BG_PIDS $tpid"
  wait_for "^xcodebuild test" "$S/events.log" 10 || return
  local xpid rpid; xpid="$(cat "$S/xcodebuild.pid")"; rpid="$(cat "$S/rec.pid")"
  # While running, another ensure is blocked by the held lease.
  "${ENVCMD[@]}" sim-vault ensure "DD iPhone 18 Pro" --lease dd:intruder >/dev/null 2>&1
  eq "$?" 8 "held lease blocks other ensure while running"
  kill -TERM "$tpid"
  wait_exit "$tpid" 10
  eq "$WRC" 143 "SIGTERM returns 143"
  kill -0 "$xpid" 2>/dev/null && fail "xcodebuild stopped"
  kill -0 "$rpid" 2>/dev/null && fail "recordVideo stopped"
  eq "$(realvault_leases)" "" "held lease gone after SIGTERM"
  lock_free || fail "lock free after SIGTERM"
}

run_detached() {
  # Run a command reparented under launchd (PID 1) with no recognizable session anchor.
  local out_file="$T/out" err_file="$T/err" rc_file="$T/detach.rc"
  rm -f "$rc_file" "$out_file" "$err_file"
  "${ENVCMD[@]}" env -u SIM_VAULT_ANCHOR_PID -u CLAUDE_PID -u CLAUDE_CODE_SESSION_ID -u CODEX_THREAD_ID \
    "$REAL_PY" -c '
import os, subprocess, sys
rcfile, outf, errf = sys.argv[1], sys.argv[2], sys.argv[3]
cmd = sys.argv[4:]
if os.fork():
    os.wait()
    sys.exit(0)
os.setsid()
if os.fork():
    os._exit(0)
with open(outf, "wb") as o, open(errf, "wb") as e:
    rc = subprocess.call(cmd, stdout=o, stderr=e)
with open(rcfile + ".tmp", "w") as f:
    f.write(str(rc))
os.rename(rcfile + ".tmp", rcfile)
' "$rc_file" "$out_file" "$err_file" "$@"
  local i=0
  while [[ ! -e "$rc_file" ]]; do
    sleep 0.05; i=$((i + 1))
    if (( i > 200 )); then fail "detached command timed out: $*"; RC=124; return 1; fi
  done
  RC="$(cat "$rc_file")"
}

t_real_null_anchor_case_alias() {
  setup_realvault
  mkdir -p "$T/checkout/ios/scripts"
  cp "$UITEST" "$SCRIPTS/flock-exec.py" "$T/checkout/ios/scripts/"
  chmod +x "$T/checkout/ios/scripts/uitest.sh"
  local co_lower co_upper
  co_lower="$(cd "$T/checkout" && pwd -P)"
  co_upper="$(dirname "$co_lower")/CHECKOUT"
  # 1) Detached `up` (anchor=null) without DD_SIM_OWNER must refuse with rc 2.
  run_detached bash --noprofile --norc "$co_lower/ios/scripts/uitest.sh" up iphone
  eq "$RC" 2 "null-anchor up refuses with rc 2"
  has "$T/err" "DD_SIM_OWNER" "null-anchor up tells user to set DD_SIM_OWNER"
  eq "$(realvault_leases)" "" "null-anchor up took no lease"

  # 2) Simulate an existing null-anchor session lease on <tmp>/checkout (via direct sim-vault).
  run_detached sim-vault ensure "DD iPhone 18 Pro" --boot --lease auto --lease-scope "$co_lower" --lease-prefix dd:up
  eq "$RC" 0 "precondition: direct sim-vault created null-anchor session lease"
  local tok; tok="$(realvault_leases)"
  [[ "$tok" =~ ^dd:up:[0-9a-f]{8}$ ]] || { fail "expected session token, got '$tok'"; return; }

  # 3) Detached test from <tmp>/CHECKOUT (case-alias) must NOT claim the null-anchor lease.
  run_detached bash --noprofile --norc "$co_upper/ios/scripts/uitest.sh" iphone
  eq "$RC" 8 "null-anchor test from case-alias refuses with 8"
  hasnt "$S/events.log" "^xcodebuild" "xcodebuild never started"
  eq "$(realvault_leases)" "$tok" "other session's lease untouched after test"

  # 4) Detached down from <tmp>/CHECKOUT must NOT release the null-anchor lease or shut down.
  run_detached bash --noprofile --norc "$co_upper/ios/scripts/uitest.sh" down iphone
  eq "$RC" 8 "null-anchor down from case-alias refuses shutdown with 8"
  has "$T/err" "未釋放" "down explains nothing was released"
  eq "$(realvault_leases)" "$tok" "other session's lease untouched after down"
  eq "$(realvault_state)" "Booted" "device stayed booted"

  # 5) Clean up that lease, then verify legacy owner-file fallback still works under null anchor.
  "${ENVCMD[@]}" sim-vault release "DD iPhone 18 Pro" --lease "$tok" >/dev/null 2>&1
  local legacy="dd:up:$co_lower:feedface" co_owner_file
  co_owner_file="$T/home/Library/Developer/CoreSimulator/sim-vault/owners/daydo-$(printf '%s' "$co_lower" | shasum | cut -c1-40)-iphone"
  "${ENVCMD[@]}" sim-vault ensure "DD iPhone 18 Pro" --boot --lease "$legacy" >/dev/null 2>&1
  mkdir -p "$(dirname "$co_owner_file")"
  printf '%s\n' "$legacy" >"$co_owner_file"
  run_detached bash --noprofile --norc "$co_lower/ios/scripts/uitest.sh" iphone
  eq "$RC" 0 "null-anchor test still allows legacy owner file"
  run_detached bash --noprofile --norc "$co_lower/ios/scripts/uitest.sh" down iphone
  eq "$RC" 0 "null-anchor down still releases legacy owner file and shuts down"
  [[ -e "$co_owner_file" ]] && fail "legacy owner file deleted"
  eq "$(realvault_leases)" "" "no lease left"
  eq "$(realvault_state)" "Shutdown" "device shut down"
}

t_real_sigint_pgrp_slow_xcodebuild() {
  setup_realvault
  echo 7 >"$S/xcodebuild.slow_term"
  # Run uitest.sh in its own session/process group, then send SIGINT to the whole pgrp (like Ctrl-C).
  local rc_file="$T/pgrp.rc"
  "${ENVCMD[@]}" "$REAL_PY" -c '
import os, signal, subprocess, sys, time
uitest, events, outf, errf, rcf = sys.argv[1:6]
rc, elapsed = "ERR", 0.0
with open(outf, "wb") as o, open(errf, "wb") as e:
    p = subprocess.Popen(["bash", "--noprofile", "--norc", uitest, "iphone"],
                         stdout=o, stderr=e, start_new_session=True)
    try:
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            if os.path.exists(events) and "xcodebuild test" in open(events).read():
                break
            time.sleep(0.05)
        t0 = time.monotonic()
        os.killpg(p.pid, signal.SIGINT)
        try:
            rc = p.wait(timeout=20)
        except subprocess.TimeoutExpired:
            rc = "TIMEOUT"
        elapsed = time.monotonic() - t0
    finally:
        try:
            os.killpg(p.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        try:
            p.wait(timeout=2)
        except subprocess.TimeoutExpired:
            pass
with open(rcf, "w") as f:
    f.write(f"{rc} {elapsed:.2f}\n")
' "$UITEST" "$S/events.log" "$T/out" "$T/err" "$rc_file"
  local rc elapsed xpid
  read -r rc elapsed <"$rc_file"
  xpid="$(cat "$S/xcodebuild.pid" 2>/dev/null || true)"
  eq "$rc" 130 "SIGINT returns 130"
  has "$S/events.log" "^xcodebuild-slow-exit$" "wrapper returned only after fake xcodebuild finished exiting"
  "$REAL_PY" -c "import sys; sys.exit(0 if float(sys.argv[1]) >= 6.5 else 1)" "$elapsed" \
    || fail "wrapper returned too early (${elapsed}s < 6.5s)"
  if [[ -n "$xpid" ]] && kill -0 "$xpid" 2>/dev/null; then
    fail "fake xcodebuild (pid $xpid) still running after wrapper exited (elapsed=${elapsed}s)"
    kill -KILL "$xpid" 2>/dev/null || true
  fi
  has "$T/err" "sim-vault-run: stage=child rc=130 childRc=130 teardown=ok" "clean teardown=ok"
  eq "$(realvault_leases)" "" "no lease left"
  lock_free || fail "lock free"
}

t_real_sigint_pgrp_ignores_term() {
  setup_realvault
  : >"$S/xcodebuild.ignore_term"
  local rc_file="$T/pgrp.rc"
  "${ENVCMD[@]}" DD_UITEST_KILL_AFTER=2 "$REAL_PY" -c '
import os, signal, subprocess, sys, time
uitest, events, outf, errf, rcf = sys.argv[1:6]
rc, elapsed = "ERR", 0.0
with open(outf, "wb") as o, open(errf, "wb") as e:
    p = subprocess.Popen(["bash", "--noprofile", "--norc", uitest, "iphone"],
                         stdout=o, stderr=e, start_new_session=True)
    try:
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            if os.path.exists(events) and "xcodebuild test" in open(events).read():
                break
            time.sleep(0.05)
        t0 = time.monotonic()
        os.killpg(p.pid, signal.SIGINT)
        try:
            rc = p.wait(timeout=8)
        except subprocess.TimeoutExpired:
            rc = "TIMEOUT"
        elapsed = time.monotonic() - t0
    finally:
        try:
            os.killpg(p.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        try:
            p.wait(timeout=2)
        except subprocess.TimeoutExpired:
            pass
with open(rcf, "w") as f:
    f.write(f"{rc} {elapsed:.2f}\n")
' "$UITEST" "$S/events.log" "$T/out" "$T/err" "$rc_file"
  local rc elapsed xpid
  read -r rc elapsed <"$rc_file"
  xpid="$(cat "$S/xcodebuild.pid" 2>/dev/null || true)"
  eq "$rc" 130 "SIGINT returns 130 when xcodebuild ignores TERM (elapsed=${elapsed}s)"
  "$REAL_PY" -c "import sys; e = float(sys.argv[1]); sys.exit(0 if 1.5 <= e <= 6.0 else 1)" "$elapsed" \
    || fail "expected wrapper to force-kill after ~2s, took ${elapsed}s"
  has "$T/err" "xcodebuild 2 秒內沒有結束，強制停止" "warns xcodebuild was force-killed"
  if [[ -n "$xpid" ]] && kill -0 "$xpid" 2>/dev/null; then
    fail "fake xcodebuild (pid $xpid) still running after force-kill"
    kill -KILL "$xpid" 2>/dev/null || true
  fi
  has "$T/err" "sim-vault-run: stage=child rc=130 childRc=130 teardown=ok" "clean teardown=ok"
  eq "$(realvault_leases)" "" "no lease left"
  lock_free || fail "lock free"
}

t_real_sigkill_all_keeps_held_lease() {
  setup_realvault
  : >"$S/xcodebuild.block"
  bg test iphone; local outer_pid=$BGPID
  wait_for "^xcodebuild test" "$S/events.log" 10 || return
  local xpid child_pid run_pid
  xpid="$(cat "$S/xcodebuild.pid")"
  child_pid="$(cat "$S/xcodebuild.ppid")"
  run_pid="$(/bin/ps -o ppid= -p "$child_pid" | tr -d ' ')"
  BG_PIDS="$BG_PIDS $xpid"
  kill -KILL "$outer_pid" "$run_pid" "$child_pid" 2>/dev/null || true
  wait "$outer_pid" 2>/dev/null || true
  sleep 0.2
  kill -0 "$xpid" 2>/dev/null || fail "fake xcodebuild should survive SIGKILL of wrappers"
  # While fake xcodebuild holds SIM_VAULT_LEASE_FD, shutdown and another ensure must return 8.
  local src=0 erc=0
  "${ENVCMD[@]}" sim-vault shutdown "DD iPhone 18 Pro" >/dev/null 2>&1 || src=$?
  eq "$src" 8 "shutdown refused (8) while xcodebuild holds lease fd"
  "${ENVCMD[@]}" sim-vault ensure "DD iPhone 18 Pro" --lease other >/dev/null 2>&1 || erc=$?
  eq "$erc" 8 "ensure --lease other refused (8) while xcodebuild holds lease fd"
  # Let fake xcodebuild finish; lease must be gone afterwards.
  : >"$S/xcodebuild.release"
  wait_for "xcodebuild-exit" "$S/events.log" 10 || return
  local i=0
  while kill -0 "$xpid" 2>/dev/null && (( i < 100 )); do sleep 0.05; i=$((i + 1)); done
  eq "$(realvault_leases)" "" "held lease gone after xcodebuild exited"
  src=0
  "${ENVCMD[@]}" sim-vault shutdown "DD iPhone 18 Pro" >/dev/null 2>&1 || src=$?
  eq "$src" 0 "shutdown succeeds after xcodebuild released lease fd"
  lock_free || fail "lock free after xcodebuild exited"
}

t_never_bypasses_sim_vault() {
  # Over every stub test above: the wrappers never shut down, delete, erase or boot directly.
  if grep -hE "^xcrun simctl (shutdown|delete|erase|boot)" "$WORK"/t-*/state/events.log | grep -v "UDID-REAL-001"; then
    fail "xcrun simctl shutdown/delete/erase/boot called directly"
  fi
  return 0
}

ALL="t_test_run_basic t_test_releases_leftover_dd_uitest t_park_first_test_waits t_test_first_park_waits
t_sigkill_shell_child_keeps_lock t_record_sigkill_recorder_keeps_lock t_up_twice_same_worktree
t_up_stale_owner_record t_up_failure_no_owner_file t_test_allows_own_up_lease
t_null_anchor_and_whoami_failure
t_test_allows_legacy_owner_file_transition t_test_refuses_foreign_lease t_test_foreign_lease_races_run
t_test_child_and_teardown_rc_8_no_busy_msg t_down_releases_and_shuts_down
t_down_legacy_owner_file_transition t_down_interleaved_lease t_down_missing_device
t_park_transition_guard t_down_transition_guard t_park_rc_passthrough t_park_lock_timeout
t_old_sim_vault t_no_sim_vault t_temp_device_missing t_full_name_is_resident
t_test_waits_for_other_xcodebuild t_teardown_failure_rc t_record_relative_path t_record_basic
t_record_recorder_dies_midway t_record_test_failure_rc t_record_recorder_fails
t_record_test_refused t_record_rm_log_failure_preserves_rc t_sigterm_stops_child_and_recorder
t_real_test_basic t_real_foreign_lease_refused t_real_xcodebuild_65_and_8
t_real_up_twice_same_worktree t_real_up_test_down t_real_legacy_owner_file_down
t_real_leftover_dd_uitest_released t_real_record_failure_11 t_real_sigterm_releases_held_lease
t_real_null_anchor_case_alias t_real_sigint_pgrp_slow_xcodebuild t_real_sigint_pgrp_ignores_term
t_real_sigkill_all_keeps_held_lease
t_never_bypasses_sim_vault"
SELECTED="${*:-$ALL}"
total=0
for CURRENT in $SELECTED; do
  setup
  before_fails=$FAILS
  "$CURRENT"
  kill_test_procs "$T"
  total=$((total + 1))
  if (( FAILS == before_fails )); then echo "ok   $CURRENT"; else echo "FAIL $CURRENT"; fi
done
echo
if (( FAILS > 0 )); then
  echo "$FAILS assertion(s) failed in:$FAILED_TESTS"
  exit 1
fi
echo "all $total tests passed"
