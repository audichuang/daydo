# DayDo server + MCP verification map

This directory is the maintained source for verifying the user-facing behavior of the DayDo Worker. That covers the App API (`api.daydoapp.com`, as a device) and the remote MCP server (`mcp.daydoapp.com`, as Claude Code). Read this index first, then use the matching feature file as the recipe. `S` is `server/.claude/skills/verify/scripts`, and every command is in `../SKILL.md`.

## Baseline preconditions

- **Production:** the Worker is deployed; deploying is not part of verification.
- **Stand-in:** `bash $S/devserver.sh up <ref>` plus the `DAYDO_*` exports in `../SKILL.md` Launch.
- `bash $S/doctor.sh --new-run` passes, and the evidence dir it prints is the current run.
- Production only: the test address `pokemongo030501@gmail.com` is signed in at `https://mail.google.com/mail/u/8/` inside ego-browser.
- Production only: the 1Password service account can read `Agent` / "DayDo Cloudflare Access service token".
- No other flow is mailing codes to the same address at the same time. A new start invalidates the previous code.

## Driving conventions

- Run steps in the order of `../SKILL.md` Drive. Every step depends on the one before it: login, then bootstrap, seed, MCP login and the claude assertions.
- Device actions go through `node $S/device.mjs …`. Browser actions go through `scripts/ego.mjs`, in the single TaskSpace recorded in `<state>/ego-space.json`; never in the user's own spaces or tabs.
- Claude Code actions run only in the temp dir recorded in `<state>/claude-dir`. They use tmux socket `daydo-verify`, with `CLAUDE_CONFIG_DIR` passed explicitly. The value used is recorded in `<state>/claude-config-dir`; cleanup and Doctor fail when the current one differs.
- Selectors are the authorize page's form actions and names, never coordinates:
  - `form[action="/authorize/email/start"] input[name=email]`
  - `form[action="/authorize/email/verify"] input[name=code]`
  - `button[name=decision][value=approve]`
- Rerun safely: `verify-seed` is reused, and probes carry a UTC timestamp in the title.

## Proof and skip reporting

- Assert on data, not prose: tool_result JSON from the `claude -p` stream, and pull summaries from the device.
- Every MCP mutation needs a device-side read-back (`device.mjs find`). Every seed needs a pull after the push.
- Screens: authorize login, code, consent and callback pages. The code page is captured before typing; Gmail is never captured.
- Each artifact goes to `$DAYDO_VERIFY_STATE/<run>/` with the step name in its file name.
- Report an unreachable path with the command that failed and the unmet precondition. Examples: the code mail never arrived (rate limit, spam), the authorize page shows "這個…帳號還沒有 DayDo 帳號", or `claude mcp list` shows Pending approval.
- A stand-in run does not verify Access, Gmail delivery or production data. Say so when reporting it.

## Feature entry contract

Each feature file starts with an H1 title and one paragraph describing the user-visible behavior. It then uses exactly four H2 sections in this order: `Sub-features`, `How to get to it (user POV)`, `Driving it with daydo-verify scripts` (starting with `Preconditions:`), and `Gotchas`.

## Features

- [Email sign-in (device)](./email-sign-in.md) covers email code sign-up/login on the API host, refresh, and the rate limits.
- [Device sync: bootstrap, seed, read-back](./device-sync.md) covers the first-login data, bulk task seeding over `/sync/push`, `/sync/pull` summaries and the soft delete.
- [Connect Claude Code to DayDo MCP](./mcp-connect.md) covers DCR + `/authorize` with the email code, consent, the localhost callback, token storage and logout.
- [MCP read tools](./mcp-read.md) covers `list_projects`, `get_project_data`, `search_tasks(include_deleted)`, and `get_task(include_deleted)` against the seeded and probe data.
- [MCP write tools](./mcp-write.md) covers `create_task`, `complete_task`, `uncomplete_task`, and `restore_task`, with device read-back.
- [Task attachments](./attachments.md) covers `PUT`/`GET /attachments/{id}/content` (including 0-byte and untyped PNGs), host gating, MCP `get_task`/`get_attachment`/`upload_attachment`, and purge cleanup.
