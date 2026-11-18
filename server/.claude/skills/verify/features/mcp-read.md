# MCP read tools

An AI client connected to DayDo can list the user's lists and read a list with its open tasks. `list_projects` returns the visible lists, inbox first, each with `role` and `can_write`. `get_project_data` returns `{project, tasks[]}`, where `tasks` holds only open tasks (status 0, not in the trash) as summaries.

## Sub-features

- `list-projects` returns visible lists including `verify-seed` (and 收件匣), with `can_write: true` for the owner.
- `get-project-data` returns the open tasks of one list, with summaries (content cut to 100 characters, `items` and `attachments` as counts).
- `search_tasks(include_deleted: true)` and `get_task(include_deleted: true)` are driven by the `trash-restore` step in [MCP write tools](./mcp-write.md); `get_task` attachments are also driven in [Task attachments](./attachments.md).
- Not driven yet: `get_project`, `list_tasks`, `list_recent_tasks`, `get_completed_tasks`, `list_tags`, `list_ics_sources`, `get_ics_sync_status` (spec/mcp.md section 8).

## How to get to it (user POV)

- In Claude Code (or any connected client), ask about DayDo lists and tasks. The model calls `mcp__daydo-verify__list_projects` and `mcp__daydo-verify__get_project_data`.

## Driving it with daydo-verify scripts

Preconditions:

- [Connect Claude Code](./mcp-connect.md) succeeded in this run, so `<state>/claude-dir` exists and is logged in.
- `verify-seed` exists: `node $S/device.mjs pull` shows a `projectId`.

- **Read through Claude.** Run `node $S/claude-assert.mjs read`. The prompt asks for list_projects, then get_project_data for "verify-seed", with only those two tools allowed. Expect `{"step":"read","ok":true,…,"cost":…}`.
- **Checks** (in `<run>/claude-read.json`):
  - `connected`: the stream's init event shows daydo connected.
  - `listProjectsHasSeed`: list_projects contains verify-seed with the device's project id.
  - `getProjectDataForSeed`: get_project_data was called with that id.
  - `taskCountMatchesDevice`: its `tasks.length` equals the device pull's `active` count.
  - `allOpen`: every returned task has status 0.
- **Proof.** `claude-read.jsonl` (the redacted stream) holds the tool_result payloads. `pull-claude.json` is the device count taken just before.

## Gotchas

- Compare against the device's active count, not the seeded N. Completed tasks, trashed probes and probes left by an earlier failed run all change it.
- Tool output size: with N in the hundreds, get_project_data can exceed Claude Code's MCP output limit (`MAX_MCP_OUTPUT_TOKENS`, about 25k tokens by default) and arrive truncated or as a file reference. Keep N ≤ 150.
- The model may skip list_projects if it already knows the id. The read prompt names the list, not the id, on purpose.
- An `isError` tool result is text (`Error: …`), not JSON, and the check reports it as a failed condition.
