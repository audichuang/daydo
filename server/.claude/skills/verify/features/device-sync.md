# Device sync: bootstrap, seed, read-back

A signed-in device uploads its first-login data and then its tasks over `/sync/push`, and reads everything back over `/sync/pull`. A fresh account gets the App's "me" member and the 收件匣 inbox. Here a marker list `verify-seed` is then filled with N tasks spread over the next 30 days: all-day and timed (Asia/Taipei), some repeating, some completed, some with checklist items, and some with a reminder. Another device's pull sees exactly what was pushed.

## Sub-features

- `bootstrap` creates the member (`isMe: true`) and the inbox like the App's first login on an empty account (`spec/sync.md` 第一次登入). It is skipped when the server already has them.
- `seed` creates project `verify-seed` plus N tasks and their checklist items, in batches of 50 ops. It is skipped when the project already exists.
- `pull` returns all scopes and all pages, and summarizes verify-seed with the MCP liveness rules.
- `find` locates a task by exact title and optionally checks its status.
- `soft-delete` writes `deletedAt` on probe tasks with an HLC that beats the server clocks.

## How to get to it (user POV)

- The iOS App does this on its first login and on every sync. The device script sends the same op shapes as `spec/fixtures/sync-ops.json`.

## Driving it with daydo-verify scripts

Preconditions:

- `node $S/device.mjs status` shows a session for the target API (run [email sign-in](./email-sign-in.md) first).

- **Bootstrap.** Run `node $S/device.mjs bootstrap`. It prints `{"step":"bootstrap","pushed":["member","project"],"hasData":true,"meMemberId":…,"inboxProjectId":…}`, or `"pushed":[]` on a rerun. It exits 1 unless `/auth/refresh` reports `hasData` and `meMemberId`.
- **Seed.** Run `node $S/device.mjs seed --n 60`.
  - The first run prints `"skipped":false` with pushed counts. For N=60 that is 60 tasks: 54 active, 6 completed, 7 repeating, 20 all-day, 40 timed, 27 checklist items. It also prints a `pulled` summary that must match.
  - Later runs print `"skipped":true` with the current pulled counts.
- **Read-back.** Run `node $S/device.mjs pull [--label <name>]` (`--label` is optional and defaults to `latest`). The summary is written to `<run>/pull-<name>.json`.
- **Find.** Run `node $S/device.mjs find --title "verify-seed #001"`. It exits 0 and prints the id and status.
- **Proof.** `seed.json` holds the pushed counts next to the pulled counts, and a mismatch fails the step. `pull-*.json` before and after the MCP steps shows the probe arriving and leaving.

## Gotchas

- MCP write tools refuse with "請先在 DayDo App 登入並同步一次" until bootstrap has run: the server never creates the member or the inbox.
- `projectMember` ops are always `rejected` by the server, because ownership comes from D1. The App sends them anyway; the script does not.
- A new row needs every non-nullable field in `fields`, or the server rejects it as `unknown-row`. The five schedule fields are one LWW group, so they are always sent together.
- Values the server only type-checks must still be valid for the App:
  - `priority` must be one of 0, 1, 3, 5;
  - `status` 2 requires `completedAt`;
  - reminders and repeat rules only go on scheduled tasks;
  - sort keys never end in `0`.
- The seed is skipped whenever `verify-seed` exists, even a partial one from an interrupted run. The assertions compare MCP results with a fresh device pull, never with the requested N. To reseed, delete the list in the App first.
- Soft-deleted and purged rows in `verify-seed` stay in `deleted` (`allTasks.length - liveTasks.length`), so `deleted` keeps growing across runs while `probes` drops to `[]` after cleanup. That is expected.
- `/sync/*` exists only on the API host; the MCP host returns 404 for it.
