# DayDo app verification map

This directory is the maintained source for verifying what a DayDo user sees and touches on the Mac, iPad and iPhone. Read this index, then the matching feature file. `S` is `ios/.claude/skills/verify/scripts`; every command is in `../SKILL.md`.

## Baseline preconditions

- Mac: `$S/mac.sh build`, `DAYDO_VERIFY_RUN=<topic> $S/mac.sh evidence`, `$S/mac.sh launch <screen> 1400x900`, then `$S/mac.sh doctor` prints OK.
- The demo data is loaded (`-DayDoDemo`): lists 收件匣、工作、個人、購物、學習、我們的行程; tasks dated around today, including 週會 (repeating, 10:00), 媽媽生日 (first of next month, all-day), 花蓮小旅行 (multi-day).
- iPhone/iPad: `ios/scripts/uitest.sh` gets the `DD` simulator and the lock itself; never drive a simulator someone else holds a lease on.

## Driving conventions

- One instance per worktree; `launch` refuses a second. Never touch `/Applications/DayDo.app` (the user's brew install).
- Prefer AX ids and labels from `../SKILL.md` Drive; use coordinates only for text focus and task-row titles.
- Every journey starts from a fresh `launch` (it resets data), so mutations need no restore.

## Proof and skip reporting

- Screenshot after each screen-changing action (`$S/mac.sh shot <feature>-<step>`), plus the AX line that proves state.
- Writes are proven by reopening the item from another view.
- Report the window size used. A narrow-window journey run only at 1400x900 is not verified.
- Things lcu cannot drive (Zhuyin composition, system notifications, Sign in with Google) are reported as not verified with that reason, never as passed.

## Feature entry contract

Each feature file starts with an H1 title and one paragraph describing the user-visible behavior, then exactly four H2 sections in this order: `Sub-features`, `How to get to it (user POV)`, `Driving it with lcu + mac.sh` (starting with `Preconditions:`), and `Gotchas`.

## Features

- [Mac calendar](./mac-calendar.md) covers the month grid, sidebar mini month and list filter, the right detail pane, cross-month clicks, double-click to add, right-click menus and the narrow window.
- [Mac task columns](./mac-task-columns.md) covers the list + resizable detail pane, the sidebar toggle, Esc and the right-click menu.
- [Mac search panel](./mac-search-panel.md) covers ⌘F, Esc, opening a result, and the same-task-already-open rule.
- [iPhone and iPad](./iphone-ipad.md) points at the XCUITest suites that prove the touch layouts.
