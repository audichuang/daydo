# MCP write tools

An AI client can create a task in a list, mark it done, reopen it, and restore a trashed task. The App, and any other device, sees the change on its next pull, because the MCP writes go through the same op path as `/sync/push`. `create_task` returns the server's merged task. `complete_task` sets status 2 and `completedAt`; on a repeating task it instead records a completed copy and moves the original to its next date. `uncomplete_task` clears status back to 0 and `completedAt` to null. `restore_task` restores a soft-deleted task found via `search_tasks(include_deleted: true)` and `get_task(include_deleted: true)`.

## Sub-features

- `create-task` makes a task titled as given in the given project, readable by a device pull with status 0.
- `complete-task` makes a non-repeating task status 2 with `completedAt`, readable by a device pull.
- `uncomplete-task` reopens a completed task back to status 0 and `completed_at: null`, readable by `device.mjs task-status`.
- `trash-restore` soft-deletes a probe via `device.mjs trash`, finds it by title alone via `search_tasks(include_deleted: true)` and `get_task(include_deleted: true)`, restores it via `restore_task`, and reads back `deletedAt: null` via `device.mjs task-status`.
- Not driven yet: `update_task`, `delete_task`, `move_task`, `move_all`, `create_project`, `update_project`, `delete_project`, `create_tag`, `add_ics_source`, `remove_ics_source`, `sync_ics_now`.

## How to get to it (user POV)

- In a connected client, ask to add a task to a DayDo list, complete it, reopen it, or find and restore a deleted task from the trash.

## Driving it with daydo-verify scripts

Preconditions:

- The [MCP read](./mcp-read.md) preconditions hold.
- `write`, `complete`, `uncomplete`, and `trash-restore` run in the same evidence run, because the later steps read `<run>/probe.json`.

- **Create.** Run `node $S/claude-assert.mjs write`. The title is `verify-probe <UTC timestamp>` and the device's verify-seed id is passed in the prompt.
  - Checks: `createTaskOk`, `toolTitle`, `toolProject`, and `devicePullHasTask` (`device.mjs find --title … --status 0` returns the same id).
  - The probe is written to `<run>/probe.json`.
- **Complete.** Run `node $S/claude-assert.mjs complete`.
  - Checks: `completeTaskOk`, `toolStatus2`, and `devicePullStatus2` (the device sees status 2 with `completedAt`).
- **Uncomplete.** Run `node $S/claude-assert.mjs uncomplete`.
  - Calls `complete_task` then `uncomplete_task` on the probe and verifies `device.mjs task-status --id <id>` reports `status: 0` and `completedAt: null`.
- **Trash & restore.** Run `node $S/claude-assert.mjs trash-restore`.
  - Runs `device.mjs trash --id <id>`, asks Claude to locate the probe by title only (`search_tasks` with `include_deleted: true`), read it (`get_task` with `include_deleted: true`), and call `restore_task`, then verifies `device.mjs task-status --id <id>` reports `deletedAt: null`.
- **Proof.** `claude-write.json`, `claude-complete.json`, `claude-uncomplete.json`, and `claude-trash-restore.json` hold the tool inputs, checks and cost. `device.log` holds the `find` / `trash` / `task-status` results.
- **Cleanup.** `bash $S/cleanup.sh` permanently deletes (`purge-probes`) every unpurged `verify-probe*` task across all lists and records `pull-after-cleanup.json` with `probes: []`.

## Gotchas

- Writes refuse until the account has a member and an inbox (bootstrap). The verify-seed list is owner-writable; a list shared to the test account as viewer would refuse with `can_write: false`.
- Probes are non-repeating on purpose. `complete_task` on a repeating task returns a different id (the completed copy), so the device check by title would see the original still at status 0.
- A tool can answer "applied" while a field lost the LWW merge to a device. The tool then returns `isError` with the unapplied field names. The device read-back is the check that matters.
- `device.mjs trash` uses an HLC newer than the server clocks on the row so LWW soft-deletion beats prior MCP writes.
- Cleanup runs `purge-probes` (`op: 'delete'`) rather than soft-deleting: probes are permanently removed (tombstoned) along with any R2 attachment prefix. `--keep-probe` leaves the probe visible for a manual look in the App.
