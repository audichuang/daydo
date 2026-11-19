"""Take an exclusive flock on LOCKFILE, then exec CMD with the lock fd inherited.

    python3 -I flock-exec.py LOCKFILE WAIT POLL LABEL -- CMD [ARGS...]

The lock belongs to the open file description, so it lasts while CMD or any child that
inherited the fd (xcodebuild and its helpers) is alive, even if CMD itself is SIGKILLed.
Nobody unlocks explicitly: closing the last fd releases it. The lock file is never deleted,
so every waiter locks the same inode.

CMD always runs, so the caller reports every outcome itself:
  DD_UITEST_LOCK_PID  this pid (exec keeps it); CMD checks it equals $$
  DD_UITEST_LOCK_FD   the inherited fd, when the lock was taken
  DD_UITEST_LOCK_RC   8 when WAIT seconds passed, 1 when the lock file could not be opened
"""
import fcntl
import os
import sys
import time


def holder_text(fd):
    try:
        text = os.pread(fd, 4096, 0).decode(errors="replace").strip()
    except OSError:
        return "（讀不到持有者資訊）"
    if not text:
        return "（持有者沒有留下資訊）"
    pid = next((f[4:] for f in text.split() if f.startswith("pid=")), "")
    if pid.isdigit():
        try:
            os.kill(int(pid), 0)
        except ProcessLookupError:
            text += f"（pid {pid} 已結束，鎖仍由它的子程序持有，例如 xcodebuild 或 recordVideo）"
        except PermissionError:
            pass
    return text


def main():
    if len(sys.argv) < 7 or sys.argv[5] != "--":
        print("usage: flock-exec.py LOCKFILE WAIT POLL LABEL -- CMD [ARGS...]", file=sys.stderr)
        sys.exit(2)
    path, wait, poll, label = sys.argv[1], float(sys.argv[2]), float(sys.argv[3]), sys.argv[4]
    cmd = sys.argv[6:]
    env = dict(os.environ)
    env["DD_UITEST_LOCK_PID"] = str(os.getpid())
    for key in ("DD_UITEST_LOCK_FD", "DD_UITEST_LOCK_RC"):
        env.pop(key, None)

    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o644)
    except OSError as exc:
        print(f"無法開啟鎖檔 {path}：{exc}", file=sys.stderr)
        env["DD_UITEST_LOCK_RC"] = "1"
        os.execvpe(cmd[0], cmd, env)

    deadline = time.monotonic() + wait
    announced = False
    while True:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            break
        except BlockingIOError:
            pass
        if not announced:
            print(f"等 DayDo 模擬器鎖 {path}，持有者：{holder_text(fd)}", file=sys.stderr)
            announced = True
        if time.monotonic() >= deadline:
            print(f"等了 {int(wait)} 秒仍拿不到鎖，放棄；持有者：{holder_text(fd)}",
                  file=sys.stderr)
            os.close(fd)
            env["DD_UITEST_LOCK_RC"] = "8"
            os.execvpe(cmd[0], cmd, env)
        time.sleep(poll)

    info = (f"pid={os.getpid()} {label} cwd={os.getcwd()} "
            f"since={time.strftime('%Y-%m-%dT%H:%M:%S%z')}\n")
    os.ftruncate(fd, 0)
    os.pwrite(fd, info.encode(), 0)
    os.set_inheritable(fd, True)
    env["DD_UITEST_LOCK_FD"] = str(fd)
    os.execvpe(cmd[0], cmd, env)


if __name__ == "__main__":
    main()
