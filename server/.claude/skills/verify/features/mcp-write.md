# MCP write tools

An AI client can create a task in a list and mark it done. The App, and any other device, sees the change on its next pull, because the MCP writes go through the same op path as `/sync/push`. `create_task` returns the server's merged task. `complete_task` sets status 2 and `completedAt`; on a repeating task it instead records a completed copy and moves the original to its next date.

## Sub-features

- `create-task` makes a task titled as given in the given project, readable by a device pull with status 0.
- `complete-task` makes a non-repeating task status 2 with `completedAt`, readable by a device pull.
- Not driven yet: `update_task`, `delete_task`, `move_task`, `move_all`, `create_project`, `update_project`, `delete_project`, `create_tag`, and the ICS source tools.

## How to get to it (user POV)

- In a connected client, ask to add a task to a DayDo list, then to complete it.

## Driving it with daydo-verify scripts

Preconditions:

- The [MCP read](./mcp-read.md) preconditions hold.
- The write step and the complete step run in the same evidence run, because `complete` reads `<run>/probe.json`.

- **Create.** Run `node $S/claude-assert.mjs write`. The title is `verify-probe <UTC timestamp>` and the device's verify-seed id is passed in the prompt.
  - Checks: `createTaskOk`, `toolTitle`, `toolProject`, and `devicePullHasTask` (`device.mjs find --title … --status 0` returns the same id).
  - The probe is written to `<run>/probe.json`.
- **Complete.** Run `node $S/claude-assert.mjs complete`.
  - Checks: `completeTaskOk`, `toolStatus2`, and `devicePullStatus2` (the device sees status 2 with `completedAt`).
- **Proof.** `claude-write.json` and `claude-complete.json` hold the tool inputs, checks and cost. `device.log` holds both `find` results.
- **Cleanup.** `bash $S/cleanup.sh` soft-deletes every live `verify-probe*` task and records `pull-after-cleanup.json` with `probes: []`.

## Gotchas

- Writes refuse until the account has a member and an inbox (bootstrap). The verify-seed list is owner-writable; a list shared to the test account as viewer would refuse with `can_write: false`.
- Probes are non-repeating on purpose. `complete_task` on a repeating task returns a different id (the completed copy), so the device check by title would see the original still at status 0.
- A tool can answer "applied" while a field lost the LWW merge to a device. The tool then returns `isError` with the unapplied field names. The device read-back is the check that matters.
- Cleanup soft-deletes rather than purging: the probe stays in the App's trash. `--keep-probe` leaves the probe visible for a manual look in the App.
