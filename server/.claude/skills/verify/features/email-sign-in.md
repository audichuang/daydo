# Email sign-in (device)

A person signs up or logs in to DayDo with only an email address. They ask for a code, read the 6-digit code from the mail "你的 DayDo 驗證碼" sent by `DayDo <no-reply@audichuang.app>`, and submit it. The device then receives access and refresh tokens. The first successful verify creates the account; later ones log into it.

## Sub-features

- `email-start` returns `202 {sent:true}` for any valid address and sends a code mail.
- `email-verify-new` makes the first verify for an address return `isNewAccount: true, hasData: false, meMemberId: null`.
- `email-verify-existing` makes a later verify return the same `user.id`, with `isNewAccount: false`.
- `email-refresh` lets `/auth/refresh` rotate the refresh token and report `hasData`, `meMemberId` and `inboxProjectId`.
- `email-not-merged` keeps the email identity separate from any Google or Apple account with the same address.

## How to get to it (user POV)

- App API: `POST /auth/email/start {email, deviceId}`, then `POST /auth/email/verify {email, code, deviceId}`. The iOS App has no email screen yet (spec/sync.md 已知限制), so the device script is the user path.
- The MCP authorize page also sends codes, but it only binds existing accounts (see [mcp-connect](./mcp-connect.md)).

## Driving it with daydo-verify scripts

Preconditions:

- Doctor passes, including the Gmail check (or `devmail` on the stand-in).
- Fewer than 5 code mails were requested for the address in the last hour.

- **Start, read and verify.** Sign in as a new device. Run `node $S/device.mjs login`. Expect `{"step":"email/verify","status":200,"userId":…,"isNewAccount":…}` on stdout. `device.log` shows `email/start` with status 202.
- **Read the code by hand (debug only).** Run `node $S/mail-code.mjs --since <epoch ms before start>`. It prints the code, so keep that output out of evidence.
- **Session state.** Run `node $S/device.mjs status`. It shows `userId`, `deviceId`, `hasData` and `meMemberId`, and never tokens.
- **Refresh.** Any later `device.mjs` command refreshes when the access token is older than 50 minutes or a call returns 401. The rotated refresh token is saved to the session file first.
- **Proof.** `device.log` holds the start status and the verify summary. On the very first run, `isNewAccount: true` proves registration; afterwards `false`, with the same `userId`.

## Gotchas

- Rate limits are 5 starts per address per hour and 20 per IP per hour. Over the limit the API still answers 202 but sends nothing, and `mail-code.mjs` then times out. A full run uses 2 starts: device login plus MCP authorize. Use `cleanup.sh --keep-session` to rerun without a new device login.
- A code is valid for 10 minutes, once. A new start invalidates every older code for the address, so never run two sign-ins against the same address in parallel (another agent or the lead included).
- Gmail threads every code mail under one subject. The script opens the newest thread and picks the newest message by its id timestamp after `--since`, not the thread row.
- A new sender domain may land in spam. The search uses `in:anywhere`.
- The test address's mailbox may already hold codes from other people's flows. `--since` filters them out. A code printed to a transcript stays valid until it expires or is used.
- `start` never reveals whether the account exists. Judge by `isNewAccount` on verify.
- There is no delete-account endpoint (`DELETE /account` is not implemented), so the test account is permanent.
