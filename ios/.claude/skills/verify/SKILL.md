---
name: verify
description: "Drive the DayDo app like a user and capture proof: the Mac (Catalyst) Debug build of this worktree with lcu, and iPhone/iPad through ios/scripts/uitest.sh. Use after changing anything under ios/DayDo or DayDoCore that a user can see or touch (layout, calendar, task list, detail, search, keyboard/mouse behavior), before merging, or whenever a Mac UI claim needs a screenshot."
---

# Verify the DayDo app

Surfaces: the Mac app (Mac Catalyst, same target as iOS) and the iPhone/iPad app on the `DD` simulators. The Mac has no UI tests, so Mac proof is always a driven run plus screenshots. iPhone/iPad proof is the XCUITest suites. Read [features/README.md](features/README.md) first, then the feature file you are proving.

```bash
S="$(git rev-parse --show-toplevel)/ios/.claude/skills/verify/scripts"
```

## Launch

Mac:

```bash
$S/mac.sh build                       # ios/scripts/uitest.sh mac (queues on heavy itself), prints the .app of THIS worktree
DAYDO_VERIFY_RUN=<topic> $S/mac.sh evidence   # evidence dir: <main checkout>/.agent-work/verify/<topic>/
$S/mac.sh launch [calendar|events|week|day|search|settings|detail|...] [1400x900]
```

- `launch` starts with `-DayDoReset -DayDoSkipLogin -DayDoDemo` (empty data + the design-board demo tasks). Without `-DayDoReset` the demo data is seeded twice.
- Ready = the window exists and has been sized; `launch` waits for both.
- Screen names come from the `-DayDoScreen` switch in `ios/DayDo/App/Debug/DebugLaunch.swift`.
- Window sizes that matter: `1400x900` (wide), `900x640` (narrow; the calendar sidebar steps aside below 1100 pt when the detail pane is open).
- `launch signin` starts on the sign-in page (only `-DayDoReset`, no skip-login, no demo data).
- Only one DayDo Debug build may run on the machine: every worktree's Debug build shares `~/Library/Application Support/DayDo-Debug` and one preference suite, so `-DayDoReset` would wipe the other one. `launch` refuses while another runs.

iPhone/iPad: `ios/scripts/uitest.sh [iphone|ipad] [-only-testing:DayDoUITests/<Class>/<method>]` (root AGENTS.md「模擬器」covers locks and leases). For manual simulator checks take a UDID with `ios/scripts/uitest.sh up [iphone|ipad]` and give it back with `down`.

## Doctor

```bash
$S/mac.sh doctor
```

OK means: `mac.sh build` succeeded for this worktree after the last change to any `.swift` under `ios/DayDo` and `DayDoCore/Sources`, and the running instance is the pid this script started from the current binary (never the brew-installed `/Applications/DayDo.app`, which has the same bundle id).

## Drive

Mac: drive with lcu (load the `lcu-desktop` skill for general technique). DayDo specifics:

- Attach by full path: `cua.getApp('<path printed by launch>')`. The bundle id is ambiguous with the brew install.
- Stable AX handles: `rail.tasks` `rail.calendar` `rail.search` `rail.settings` (icon rail), sidebar toggles by label `顯示／隱藏側欄` (calendar) and `顯示／隱藏清單欄` (tasks), `calendarTitle`, `calendarModeMenu`, `calendarPrev`/`calendarToday`/`calendarNext`, `taskTitleField`, `taskContentField`, `taskDetailClose`, `yearDay.<yyyy-mm-dd>` (sidebar mini month). Month cells are containers labelled `11 月 24 日 週二` whose date button opens the day view.
- Keys: `pressKey('Escape')`, `pressKey('cmd+f')`. Lowercase `escape`/`end`/`right` are rejected.
- Text focus: clicking a field by AX index does not give it real first-responder focus; click its coordinates, then `typeText`. `typeText` bypasses the input method, so Zhuyin composition cannot be driven.
- Task rows: clicking a row by AX index can hit the completion checkbox and complete the task. Click the title text by coordinates.
- Drag: lcu drag does not fire in Catalyst. Use `swift ios/scripts/mac-drag.swift <x1> <y1> <x2> <y2>` (screen points).
- Resize mid-run: `$S/mac.sh size 900x640`.

iPhone/iPad: drive through XCUITest. Set `TEST_RUNNER_DAYDO_SHOTS=<dir>` and the `shot()` helper in `DayDoUITests` writes screenshots there. List views are `LazyVStack`: scroll an off-screen row into view before querying it.

## Evidence

- `$S/mac.sh shot <step-name>` captures just the app window into the evidence dir. Take one after each action that changes the screen, not only at the end.
- For state changes, also read the AX state (`getAXState`) and quote the line that proves it (`calendarTitle` value, `taskTitleField` value, `(selected)` row).
- A write (complete, delete, edit) is proven by reopening the item from a second view (list ↔ calendar), not by the button state.
- Name the feature ID and window size with every artifact. Report anything not driven (IME, notifications, sign-in) as not verified, with the reason.

## Cleanup

```bash
$S/mac.sh cleanup
```

Stops only the pid `launch` recorded (verified by executable path) and prints where the evidence was kept. `uitest.sh` already restores the `DayDoCore/Package.resolved` drift a build causes when the file was clean before. Evidence is never deleted. Simulator runs: `ios/scripts/uitest.sh down` for any `up` you did.

## When a UI test run hangs or reports nothing

Read the last `t = …` step in the log. Stuck on `Wait for com.audichuang.daydo to idle` means the app never goes idle, a code problem. A log ending at `Resolve Package Graph` does not mean it hung resolving packages. Run the same test on `main` on the same simulator; if `main` passes, `git bisect run` that single test (with a `timeout` per step). Do not blame the simulator first: that misdiagnosis once hid a deleted tab reset.
