# Connect Claude Code to DayDo MCP

A Claude Code user adds DayDo as an HTTP MCP server and signs in. Claude Code registers a client (DCR) and prints an authorization URL. The user signs in on the DayDo page "登入 DayDo" with their email and a mailed code, and approves "授權存取 DayDo". The browser then lands on Claude Code's `http://localhost:<port>/callback`, which prints "Authentication successful". `claude mcp list` shows `daydo: … - ✔ Connected`.

## Sub-features

- `dcr` registers a public client through `POST /register`, done automatically by `claude mcp login`.
- `authorize-email` covers the login page email form, then the "輸入驗證碼" code page, then the consent page.
- `consent-approve` makes 同意 redirect to the client's localhost callback with `code` and `state`.
- `token-store` stores the tokens in the macOS keychain, and `claude mcp list` / `claude -p` find them.
- `logout` makes `claude mcp logout daydo-verify` remove the stored entry.
- `unknown-identity` shows an error for an address with no DayDo account and creates no account (not driven by default).

## How to get to it (user POV)

- Claude Code, in an empty project:
  - `.mcp.json` holds `{"mcpServers":{"daydo-verify":{"type":"http","url":"https://daydo-mcp.audichuang.app/"}}}`;
  - trust the folder and approve the server (`.claude/settings.local.json` `{"enabledMcpjsonServers":["daydo-verify"]}`);
  - run `claude mcp login daydo-verify --no-browser` and open the printed URL.
- Claude.ai / ChatGPT connectors use the same `/authorize` page (README "Adding the connector"); they are not driven here.

## Driving it with daydo-verify scripts

Preconditions:

- [Email sign-in](./email-sign-in.md) and the bootstrap step of [device sync](./device-sync.md) have run, so the account exists and has data.
- Doctor shows the tmux socket `daydo-verify` free.

- **Connect.** Run `node $S/mcp-login.mjs`. It prints, in order:
  - `{"step":"authorize-url","host":…,"redirectUri":"http://localhost:<port>/callback"}`
  - `{"step":"email-sent","stage":"code-page","title":"輸入驗證碼"}`
  - `{"step":"approved","finalUrl":"http://localhost:<port>/callback?code=***&state=***","callbackText":"Authentication successful…"}`
  - `{"step":"mcp-list","pasted":false,"line":"daydo-verify: <url> (HTTP) - ✔ Connected",…}`
- **Trust step inside it.** It starts interactive `claude` in tmux, picks "Yes, I trust this folder", waits for "1 MCP server needs authentication", and sends `/exit`. No prompt goes to the model.
- **Paste fallback.** If `claude mcp login` has not exited 15 s after the browser reached the callback, the script types the redirected URL into the pane ("Or paste the redirect URL here:"). `pasted:true` in the output records that.
- **Proof.** The `authorize-*.png` screenshots, `mcp-login.pane.txt` ending in `Authenticated with "daydo-verify"` and `__EXIT__ 0`, and `mcp-list.txt` with `✔ Connected`. `credential-store.json` shows which store gained the entry.
- **Logout.** `bash $S/cleanup.sh` runs `claude mcp logout daydo-verify`, which prints "Signed out of "daydo-verify"". The keychain then has no token for the MCP URL.

## Gotchas

- The login page has no separate "Email" button: the email form sits under the Google and Apple buttons. Those show "（未設定）" when not configured.
- The MCP email path never registers. An address without a DayDo identity gets "這個…帳號還沒有 DayDo 帳號". Sign up through the device first.
- `.claude/settings.local.json` approval only counts in a trusted folder. Without trust, `claude mcp login` exits 1 with `"daydo-verify" is from .mcp.json and awaiting approval`.
- Accepting trust leaves an entry for the temp path under `projects` in `$CLAUDE_CONFIG_DIR/.claude.json` (`hasTrustDialogAccepted: true`). Cleanup leaves that shared file alone.
- Token storage (Claude Code 2.1.325, macOS) is the keychain generic password `Claude Code-credentials-<first 8 hex of sha256(CLAUDE_CONFIG_DIR)>`, or `Claude Code-credentials` when the variable is unset.
  - The entries sit in JSON key `mcpOAuth["daydo-verify|<hash>"]`, with `serverUrl`, `accessToken`, `refreshToken`, `clientId`, `discoveryState` and so on.
  - `~/.claude*/.credentials.json` holds only `claudeAiOauth`, but the scripts also read its `mcpOAuth` for the token check. Only `security` exit 44 (item not found) counts as "no keychain item"; any other `security` error or unparsable JSON fails the check instead of reading as "no token".
  - The entry appears (without tokens) as soon as interactive `claude` sees the server, before login.
- The entry key comes from the server name and URL, not the directory. A personal "daydo-verify" connector in Claude Code with the same URL shares it. So `mcp-login.mjs` refuses to start, and Doctor fails, while a token for the URL already exists, rather than overwriting it and then signing it out in cleanup.
- The callback port is chosen per login (52310 and 62903 in the dry runs); the script reads it from `redirect_uri` in the printed URL.
- `claude -p --bare` skips keychain reads, so it would not see the token. The assertions never use it.
- Bind cookies are `Secure; SameSite=None` on `Path=/authorize`. Finish the authorize flow in the same ego-browser page that opened it, or it fails with a bind mismatch.
