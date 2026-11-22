#!/usr/bin/env python3
"""Turn DayDoPerfTests traces (Time Profiler on the simulator) into dropped-frame counts.

usage:
  perf.py table <traces dir> <rounds, e.g. "1 2"> [Scenario ...]   per-scenario frame table
  perf.py hot <trace>                                             DayDo functions on the main thread

Why it works this way (see README.md): the simulator has no hitch instrument, xctrace can't
symbolicate an attached simulator app, and every XCUITest element query costs the app's main
thread an accessibility snapshot. So: busy time per runloop iteration comes from Time Profiler
sample weights, DayDo frames are symbolicated with atos from the image load addresses the app
wrote at `seedDone`, and only frames right after an XCUITest "Synthesize event" count.
"""
import bisect, collections, datetime, glob, os, plistlib, re, subprocess, sys
import xml.etree.ElementTree as ET

FRAME_MS = 16.7          # one 60 Hz frame
WINDOW_S = 1.0           # animation window after a gesture
SNAPSHOT_MS = 90         # XCUITest snapshots cost >= ~100 ms even on light screens
SCENARIOS = ("ControlQueriesOnly TaskListScroll DrawerOpenClose TabSwitch DetailSheetOpenClose MonthSwipe "
             "MonthCollapseExpand AgendaListScroll WeekPageAndScroll DayTimeGridScroll YearView").split()


def export(trace, xpath):
    return subprocess.run(["xcrun", "xctrace", "export", "--input", trace, *xpath],
                          capture_output=True, text=True, check=True).stdout


def table(trace, schema):
    root = ET.fromstring(export(trace, ["--xpath", f'/trace-toc/run[1]/data/table[@schema="{schema}"]']))
    ids, cols = {}, [c.findtext("mnemonic") for c in root.iter("col")]

    def res(e):
        if "ref" in e.attrib:
            return ids[e.attrib["ref"]]
        if "id" in e.attrib:
            ids[e.attrib["id"]] = e
        for c in e:  # nested ids (frames inside backtraces)
            res(c)
        return e

    return [dict(zip(cols, [res(c) for c in r])) for r in root.iter("row")]


def num(e):
    return int(e.text) if e is not None and e.text else 0


def products_dir():
    """DerivedData Build/Products of the checkout this script lives in (holds the dSYMs)."""
    repo = os.path.realpath(os.path.join(os.path.dirname(__file__), "../../.."))
    for info in glob.glob(os.path.expanduser("~/Library/Developer/Xcode/DerivedData/DayDo-*/info.plist")):
        with open(info, "rb") as f:
            if plistlib.load(f).get("WorkspacePath", "").startswith(repo + "/"):
                return os.path.join(os.path.dirname(info), "Build/Products/Debug-iphonesimulator")
    sys.exit(f"no DerivedData for {repo}; run run.sh from this checkout first")


class Trace:
    def __init__(self, path, products):
        self.path = path
        poi = [r for r in table(path, "PointsOfInterestEvents") if "seedDone" in ET.tostring(r["name"], encoding="unicode")]
        self.t0 = num(poi[0]["time"]) if poi else 0
        with open(path.removesuffix(".trace") + ".images") as f:
            images = sorted((int(a), n) for a, n in (l.split(" ", 1) for l in f.read().splitlines()))
        self.iters = self._iterations()
        raw = []
        for r in table(path, "time-profile"):
            if "Main Thread" not in (r["thread"].get("fmt") or ""):
                continue
            frames = [f.get("name", "") for f in r["stack"].iter("frame")] if r.get("stack") is not None else []
            raw.append((num(r["time"]), frames, num(r["weight"])))
        raw.sort()
        names = self._symbolize(images, products, {int(f, 16) for _, fs, _ in raw for f in fs if f.startswith("0x")})
        self.times = [t for t, _, _ in raw]
        self.weights = [w for _, _, w in raw]
        self.samples = [[names.get(int(f, 16), f) if f.startswith("0x") else f for f in fs] for _, fs, _ in raw]
        self.step = sorted(self.weights)[len(self.weights) // 2] if self.weights else 1_000_000

    def _iterations(self):
        open_, out = {}, []
        for r in table(self.path, "runloop-events"):
            if r["is-main"].get("fmt") not in ("Yes", "true", "1", "YES") or r["interval-type"].get("fmt") != "individual_iteration":
                continue
            key, t = r["interval-identifier"].get("fmt"), num(r["timestamp"])
            if r["event-type"].get("fmt") == "START":
                open_[key] = t
            elif key in open_:
                s = open_.pop(key)
                if s >= self.t0:
                    out.append((s, t - s))
        return out

    @staticmethod
    def _symbolize(images, products, addrs):
        loads = [a for a, _ in images]
        by_img, out = collections.defaultdict(list), {}
        for a in addrs:
            i = bisect.bisect_right(loads, a) - 1
            if i >= 0:
                by_img[images[i]].append(a)
        for (load, name), al in by_img.items():
            dwarf = glob.glob(f"{products}/{name}*.dSYM/Contents/Resources/DWARF/{name}")
            if not dwarf:
                out.update({a: f"[{name}]" for a in al})  # system library: only its name is knowable
                continue
            lines = subprocess.run(["atos", "-o", dwarf[0], "-l", hex(load), *map(hex, al)],
                                   capture_output=True, text=True).stdout.splitlines()
            out.update({a: l.split(" (in ")[0] for a, l in zip(al, lines) if not l.startswith("0x")})
        return out

    def busy_frames(self):
        """(start ns, busy ms) per main-thread runloop iteration; idle wait inside it doesn't count."""
        out = []
        for s, d in self.iters:
            lo, hi = bisect.bisect_left(self.times, s), bisect.bisect_right(self.times, s + d)
            out.append((s, sum(self.weights[lo:hi]) / 1e6))
        return out

    def start_date(self):
        toc = export(self.path, ["--toc"])
        return datetime.datetime.fromisoformat(re.search(r"<start-date>([^<]+)", toc).group(1)).timestamp()


def test_steps(log_path):
    log = open(log_path).read()
    t0 = datetime.datetime.strptime(re.search(r"Start Test at (\S+ \S+)", log).group(1), "%Y-%m-%d %H:%M:%S.%f")
    t0 = t0.replace(tzinfo=datetime.datetime.now().astimezone().tzinfo).timestamp()
    return [(t0 + float(t), s.strip()) for t, s in re.findall(r"t =\s+([\d.]+)s(.*)", log)]


def clock_offset(trace, steps):
    """Trace clock minus test-log clock, from the control run: one big frame per element query."""
    q = [t for t, s in steps if s.startswith("Checking existence")]
    start = trace.start_date()
    offs = [min((start + s / 1e9 - x for x in q), key=abs) for s, b in trace.busy_frames() if b >= 400]
    offs = sorted(o for o in offs if abs(o) < 1.5)
    return offs[len(offs) // 2] if offs else 0.5


def gesture_frames(trace, steps, offset):
    syn = [t for t, s in steps if s == "Synthesize event"]
    queries = [t for t, s in steps if re.match(r"(Find the|Check for|Checking|Requesting snapshot|Scroll element|Computed hit)", s)]
    start, hits, busy = trace.start_date(), [], 0.0
    for s, b in trace.busy_frames():
        f = start + s / 1e9 - offset
        i = bisect.bisect_right(syn, f) - 1
        if i < 0 or f - syn[i] > WINDOW_S:
            continue
        busy += b
        if b < FRAME_MS or (b >= SNAPSHOT_MS and any(f - 0.7 <= x <= f + 0.1 for x in queries)):
            continue
        hits.append(b)
    return len(syn), busy / max(1, len(syn)) / (WINDOW_S * 10), hits


def cmd_table(traces, rounds, names):
    products = products_dir()
    rounds = rounds.split()
    ctl = f"{traces}/testPerfControlQueriesOnly-{rounds[0]}"
    offset = clock_offset(Trace(ctl + ".trace", products), test_steps(ctl + ".log")) if os.path.exists(ctl + ".trace") else 0.5
    print(f"clock offset {offset:+.2f}s; per round: gestures busy% | frames >=16.7 / >=33 / >=100 ms, worst ms")
    for n in names or SCENARIOS:
        cells = []
        for r in rounds:
            base = f"{traces}/testPerf{n}-{r}"
            if not os.path.exists(base + ".trace"):
                cells.append("        (missing)        ")
                continue
            g, busy, hits = gesture_frames(Trace(base + ".trace", products), test_steps(base + ".log"), offset)
            cells.append(f"{g:3d} {busy:3.0f}% | {sum(h >= 16.7 for h in hits):3d} {sum(h >= 33.4 for h in hits):3d} "
                         f"{sum(h >= 100 for h in hits):2d} {max(hits, default=0):4.0f}")
        print(f"{n:22s} | " + " || ".join(cells))


def cmd_hot(path):
    t = Trace(path, products_dir())
    c = collections.Counter()
    for s, frames in zip(t.times, t.samples):
        if s >= t.t0:
            c.update({f for f in frames if f and not f.startswith(("0x", "["))})
    for f, n in c.most_common(20):
        print(f"{n * t.step / 1e6:7.0f} ms  {f[:140]}")


if __name__ == "__main__":
    if len(sys.argv) >= 4 and sys.argv[1] == "table":
        cmd_table(sys.argv[2], sys.argv[3], sys.argv[4:])
    elif len(sys.argv) == 3 and sys.argv[1] == "hot":
        cmd_hot(sys.argv[2])
    else:
        sys.exit(__doc__)
