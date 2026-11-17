---
name: verify
description: "Drive the DayDo sync server and remote MCP end to end like a user: sign up / log in with an email code as a device (code read from Gmail in ego-browser), bootstrap and seed tasks over /sync/push, connect Claude Code to daydo-mcp through its OAuth authorize page, then assert MCP reads and writes with `claude -p` against a device pull. Use after deploying server/, or whenever auth, sync, OAuth or MCP tool behavior must be proven on production (daydo-api / mcp.daydoapp.com) or on a local dev build."
---

# Verify DayDo server + remote MCP

Surface: two hostnames on one Worker.
- `https://api.daydoapp.com` is the App API. It sits behind Cloudflare Access, so every request carries the service token.
- `https://mcp.daydoapp.com/` is the remote MCP server. It has no Access; OAuth 2.1 with DCR is its only gate.

The user journey is:
1. Email sign-in as a device.
2. First-login bootstrap.
3. Seed tasks.
4. Connect Claude Code via OAuth (email code).
5. Read, create and complete tasks through MCP tools.
6. Confirm each MCP write from the device side.

Everything is scripted in `scripts/`. Read [features/README.md](features/README.md) before driving, then the feature file for what you are proving.

```bash
S="$(git rev-parse --show-toplevel)/server/.claude/skills/verify/scripts"
```

All scripts read their config from the environment. Production is the default:

| Variable | Default | Meaning |
|---|---|---|
| `DAYDO_API` | `https://api.daydoapp.com` | App API (Access headers are added automatically only for this host) |
| `DAYDO_MCP` | `https://mcp.daydoapp.com/` | MCP URL written into `.mcp.json` |
| `DAYDO_VERIFY_EMAIL` | `pokemongo030501@gmail.com` | test account |
| `DAYDO_CODE_SOURCE` | `gmail` | `gmail` reads the code mail in ego-browser; `devmail` uses `GET <api>/test/mail` (dev builds only) |
| `DAYDO_GMAIL_INDEX` | `8` | Gmail account index in ego-browser (`https://mail.google.com/mail/u/8/`) |
| `DAYDO_VERIFY_STATE` | `~/.local/state/daydo-verify` | session file, ego/tmux/temp-dir pointers, evidence runs |
| `CLAUDE_CONFIG_DIR` | inherited | passed explicitly to every `claude` the scripts start, so login, list, `-p` and logout share one credential store |

Node 24, bash (macOS 3.2 is fine), `tmux`, `claude` 2.1.325+, `ego-browser`, and for production `op` with `~/.config/op/agent-sa.env`.

## Launch

**Production** has nothing to start. It is the deployed Worker; deploying is the lead's job (`server/README.md` "Deploy"), never this skill's. "Ready" means Doctor passes.

**Local stand-in** (dry runs; nothing touches production):

```bash
bash $S/devserver.sh up [<git ref>]   # git archive of <ref> → /tmp/daydo-verify-devsrv, migrate, vite on :8787
export DAYDO_API=http://127.0.0.1:8787 DAYDO_MCP=http://localhost:8787/ DAYDO_CODE_SOURCE=devmail \
       DAYDO_VERIFY_STATE=$HOME/.local/state/daydo-verify-dryrun
bash $S/devserver.sh down             # teardown
```

- It exports a ref, never a working tree, so it is safe while someone else edits or reviews a worktree.
- Ready is the line `ok dev server <sha> on http://127.0.0.1:8787 (API) and http://localhost:8787/ (MCP)`. By then `/health` answered and the MCP host gate served `/`.
- The stand-in skips three things the production run must cover:
  - Cloudflare Access;
  - real mail delivery, and reading it from Gmail;
  - existing production data.

## Doctor

```bash
bash $S/doctor.sh --new-run     # --new-run starts a fresh evidence dir; omit to keep the current one
```

Doctor is read-only. Every check prints `ok`, `FAIL` or `info`, and it exits 1 if any check fails. It checks:
- `node`, `claude`, `tmux` and `ego-browser` are on PATH.
- `GET <mcp>/` returns protected-resource metadata whose `resource` equals its own origin.
- `GET <api>/health` returns 200 with Access headers. In production, the same request without them must be rejected (401).
- With `gmail`, ego-browser opens `mail/u/<index>` and the title names the test address. With `devmail`, the dev mailbox answers.
- `op whoami` works (production only).
- No leftover tmux sessions on socket `daydo-verify`.
- No Claude Code keychain token exists yet for the MCP URL. The entry is keyed by name and URL, not directory, so an existing token is someone's own `daydo` connection, or a leftover that `cleanup.sh` removes. `mcp-login.mjs` refuses to start in that case too.
- It also reports the device session.

Run Doctor first, and again whenever anything looks off.

## Drive

Run the steps in order. Each prints one JSON line and exits non-zero with `FAIL: …` on stderr.

```bash
node $S/device.mjs login          # 1. POST /auth/email/start → code from Gmail → /auth/email/verify; saves session
node $S/device.mjs bootstrap      # 2. App first login: me member + 收件匣 inbox, only if missing; asserts hasData + meMemberId
node $S/device.mjs seed --n 60    # 3. project "verify-seed" with N tasks; prints counts; skipped when it already exists
node $S/mcp-login.mjs             # 4. temp dir + .mcp.json + trust, `claude mcp login daydo-verify --no-browser` in tmux,
                                  #    authorize page in ego-browser (email → code → 同意), `claude mcp list` ✔ Connected
node $S/claude-assert.mjs read    # 5a. list_projects + get_project_data: task count == device active count
node $S/claude-assert.mjs write   # 5b. create_task "verify-probe <UTC>" → device pull finds it, status 0
node $S/claude-assert.mjs complete  # 5c. complete_task → device pull shows status 2 + completedAt
```

Helpers you can run on their own:

```bash
node $S/device.mjs status                       # session summary (never tokens)
node $S/device.mjs pull --label <name>          # verify-seed summary → <run>/pull-<name>.json
node $S/device.mjs find --title "<t>" --status 2  # exit 0 only if that task exists with that status
node $S/device.mjs delete-probes                # soft-delete live verify-probe* tasks
node $S/mail-code.mjs --since <epoch ms> [--timeout 120]   # prints the newest code mailed after <since>
node $S/claude-assert.mjs all --model haiku     # 5a-5c in one go (haiku is the default; ~US$0.01 per full run)
```

Notes:
- `mcp-login.mjs` refuses to start without a bootstrapped device session, because the MCP email path only binds existing accounts. It also refuses while the tmux socket is busy, or when the session's email differs from `DAYDO_VERIFY_EMAIL`. It kills tmux socket `daydo-verify` on every exit path, because the pane holds the unredacted OAuth URL.
- `claude-assert.mjs` runs `claude -p` in the temp dir with:
  - `--tools ""`, and `--allowedTools` limited to the `mcp__daydo-verify__*` tools the step needs;
  - `--permission-mode dontAsk`;
  - `--strict-mcp-config --mcp-config .mcp.json`;
  - `--setting-sources project,local`, so no user hooks or plugins load;
  - `--no-session-persistence`.
- It asserts on the `tool_result` JSON in the stream, never on the model's reply.

## Evidence

Everything goes to `$DAYDO_VERIFY_STATE/<UTC run id>/` (production default `~/.local/state/daydo-verify/<run>/`). That is outside the repo, and cleanup never removes it.

| File | What it proves |
|---|---|
| `device.log` | email start 202, verify result (userId, isNewAccount, hasData, meMemberId, inboxProjectId), bootstrap ops, find results |
| `seed.json`, `pull-*.json` | pushed counts and the device's independent read-back (tasks, active, completed, repeating, all-day, timed, checklist items, probes) |
| `authorize-login.png`, `authorize-code.png`, `authorize-consent.png`, `authorize-callback.png` | the user-facing OAuth pages (the code page is captured before the code is typed) |
| `mcp-trust.pane.txt`, `mcp-login.pane.txt`, `mcp-list.txt` | the CLI side of the connection, ending in `✔ Connected` |
| `credential-store.json` | which store holds the MCP token (key names, server URL and has-token flags only) |
| `claude-<step>.jsonl` / `.json` | redacted stream-json, plus the parsed tool calls, checks and cost |
| `probe.json`, `cleanup.txt`, `pull-after-cleanup.json` | the probe and its removal |

Proof standards:
- Drive the real user path: email codes from the real mailbox, the real authorize page in a browser, and real `claude` tool calls. No test endpoints are used in production.
- Each mutation is proven from a second view. An MCP write is confirmed by a device `/sync/pull`, and the seed by a pull after the push.
- Transcripts are redacted (`lib.mjs` `redact`). That covers Bearer and JWT values, `accessToken`/`refreshToken`/`code`/`ct` fields, the `code=`/`state=`/`pending=`/`ct=` URL parameters, bind cookies, Access headers, and `驗證碼：NNNNNN`.
- Never screenshot Gmail.

## Cleanup

```bash
bash $S/cleanup.sh [--keep-probe] [--keep-session]
```

Cleanup runs in this order:
1. Soft-deletes the live `verify-probe*` tasks through the device. The HLC is newer than the MCP-written clocks, and the result is checked on the returned `deletedAt`.
2. Runs `claude mcp logout daydo-verify` in the temp dir and checks that no token is left for the MCP URL, in the keychain item or in `$CLAUDE_CONFIG_DIR/.credentials.json`. It first compares the current `CLAUDE_CONFIG_DIR` with the one `mcp-login.mjs` recorded in `<state>/claude-config-dir`.
3. Removes the recorded `daydo-verify-claude.*` temp dir. If the config dir differs, logout fails, or a token remains, it keeps the temp dir and both pointers and exits 1, so the cleanup can be retried.
4. Kills only tmux socket `daydo-verify`.
5. Finishes only the ego-browser TaskSpace this skill recorded, with `keep: []`, and only if its name starts with `daydo-verify ` (otherwise the record is discarded). User tabs are protected by ego-browser. A failed finish exits 1.
6. Deletes the device session file. Use `--keep-session` to rerun without another email.

It never deletes `verify-seed` or the account: there is no delete-account endpoint, and seeding is rerun-safe. After a stand-in run, also run `bash $S/devserver.sh down`.

## Helpers

| Script | Role |
|---|---|
| `scripts/lib.mjs` | config, state and evidence paths, Access headers via `op read` in a child bash, redaction, UUIDv7/HLC, Claude credential-store inspection (key names only) |
| `scripts/ego.mjs` | runs ego-browser scripts in one persisted TaskSpace (`<state>/ego-space.json`); results come back on `__RESULT__` lines, which ego-browser prints on **stderr** |
| `scripts/mail-code.mjs` | newest code after a timestamp (Gmail via ego-browser, or the dev mailbox) |
| `scripts/device.mjs` | the device: login, bootstrap, seed, pull, find, delete-probes, status, forget |
| `scripts/mcp-login.mjs` | the Claude Code connection: trust, login, authorize, approve, confirm |
| `scripts/claude-assert.mjs` | `claude -p` steps and their assertions |
| `scripts/doctor.sh`, `scripts/cleanup.sh`, `scripts/devserver.sh` | as above |
