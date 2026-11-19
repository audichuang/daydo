# DayDo Server

Cloudflare Worker backend for DayDo, built with [Void](https://void.cloud) (Hono + Vite), Drizzle ORM (D1), and `jose`.

## Install

```bash
cd server
npm ci
```

## Local Environment

Environment variables are declared in [`env.ts`](./env.ts). For local development, create `.env` (gitignored; Void only reads `.env` and rejects `.env.example` / `.env.*` files):

```ini
JWT_SECRET=replace-with-a-dev-secret-at-least-32-bytes
APPLE_AUDIENCE=com.audichuang.daydo
GOOGLE_AUDIENCE=your-ios-oauth-client-id.apps.googleusercontent.com
```

Optional overrides (defaults point to Apple and Google JWKS endpoints):

- `APPLE_JWKS_URL` (default: `https://appleid.apple.com/auth/keys`)
- `GOOGLE_JWKS_URL` (default: `https://www.googleapis.com/oauth2/v3/certs`)
- `SYNC_FAULT` (`none` | `split-txn`, default: `none`; dev-only fault switch that splits read/write outside `transactionSync` for concurrency race testing)

## Database

Apply committed migrations to the local D1 database:

```bash
npx void db migrate
```

To generate a new migration after editing [`db/schema.ts`](./db/schema.ts):

```bash
npx void db generate
```

## Run Dev Server

```bash
npm run dev
```

Void starts Vite with `workerd` and a local D1 database.

## Auth Endpoints

- `POST /auth/apple` (`{ identityToken, nonce, deviceId }`) and `POST /auth/google` (`{ idToken, deviceId }`)
  - Response: `{ accessToken, refreshToken, user: { id }, isNewAccount, hasData, meMemberId, inboxProjectId, avatarUrl }` (where `avatarUrl` is nullable; Google login stores/refreshes verified `https:` `picture` URL on `user.avatarUrl`, Apple login leaves `user.avatarUrl` untouched)
- `POST /auth/refresh` (`{ refreshToken }`)
  - Response: `{ accessToken, refreshToken, hasData, meMemberId, inboxProjectId, avatarUrl }`
  - Grace rule: retrying a token rotated within 10 minutes whose successor is still unrevoked revokes that unused successor and issues a new token pair; any other reuse revokes the session chain (`401`).
- `PUT /me/avatar` (`{ avatarUrl }`, requires `Authorization: Bearer <accessToken>`)
  - Validates `avatarUrl` is an `https:` URL whose host ends with `googleusercontent.com` (max 2048 chars; `400` otherwise), stores it in D1 `user.avatarUrl`, and returns `{ avatarUrl }`.
- `inboxProjectId` is queried from the user's `Scope` Durable Object (`getInboxProjectId`, filtered by active `projectMembership`), `meMemberId` comes from `user.meMemberId`, and `hasData` is `inboxProjectId !== null`.

## Sync Endpoints

All sync endpoints require `Authorization: Bearer <accessToken>`.

- `POST /sync/push`
  - Body: `{ deviceId, ops: [{ opId, hlc, entity, entityId, op, fields, row }] }` (max 200 ops)
  - Binds new IDs and checks list/membership routing in D1, then routes each scope's ops to its `Scope` Durable Object (`Scope.get('u:<userId>')`), where each batch runs inside `transactionSync` with per-op `opId` deduplication, HLC 5-minute future clamp, and field-level LWW merge (including `schedule` grouped clock).
  - Non-creator `project.folderId` edits are ignored, pushing your own `member` row syncs `name`/`initial`/`color` to D1 `user`, and owner `project` `delete` permanently purges the list across D1 (`purgedProject`, `projectMembership`) and all registered `listScopes`.
  - Response: `{ results: [{ opId, status: 'applied' | 'rejected', reason?, row, clocks, gone? }], serverTime }` where `serverTime` is the server HLC string (`<13-digit ms>:<4-digit counter>:server`), monotonic and `>=` every HLC assigned or clamped in the batch.
- `POST /sync/pull`
  - Body: `{ cursors?: { "u:<userId>": seq }, backfill?: [projectId], limit? }` (`limit` default `500`, max `1000`).
  - Pulls the requester's own scope plus every scope in `listScopes` for active memberships (or `backfill` scopes for those projects), omitting `project.folderId` for non-creators and returning `{ entity, entityId, gone: true, serverSeq }` departures when a row leaves a list and is no longer readable.
  - Reconciles any missed `projectMember` projections and retries any pending `purgedProject` scope purges before reading rows.
  - Response: `{ scopes: [{ scope, rows: [{ entity, row, clocks, serverSeq } | { entity, entityId, gone: true, serverSeq }], cursor, hasMore }], memberships: [{ projectId, scope, role }], members: [{ id, userId, name, initial, color, avatarUrl, isMe, createdAt, updatedAt }] }`
- `PUT /attachments/<id>/content` and `GET /attachments/<id>/content` (API host only; 404 on MCP host)
  - Stores and serves raw attachment file bytes in Cloudflare R2 (`STORAGE` binding, key `att/<taskId>/<attachmentId>`, max 20 MB).
  - `PUT` requires write permission on the parent task's current list and exact body size match (`204`; `404` `attachment-not-found`; `410` `attachment-deleted`; `403` `Forbidden`; `413` > 20 MB; `400` `size-mismatch`).
  - `GET` requires list membership (`200` with `Content-Type` from the attachment row and `Content-Length`; `404` if missing/soft-deleted/not yet uploaded; `403` if not a member).
  - Permanently deleting a task (`op: 'delete'`) cleans up `att/<taskId>/` objects from R2 (best-effort); soft deletion (`deletedAt`) keeps the object.

## Sharing & Invite Endpoints

All sharing endpoints require `Authorization: Bearer <accessToken>`.

- `POST /invites` (`{ projectId, role: 'editor' | 'viewer', email? }`, owner only)
  - Generates a 128-bit base64url invite code (7-day expiry, SHA-256 hash stored in D1 `invite`, reusable until expiry).
  - Response: `{ code, url: "daydo://invite/<code>", expiresAt }`
- `GET /invites/<code>`
  - Response: `{ projectName, inviterName, role, expiresAt }` (`404` if unknown, revoked, expired, or list purged)
- `POST /invites/<code>/accept`
  - Conditionally adds/reactivates `projectMembership` in D1 (never downgrading an existing owner) and projects `projectMember` into the list's home `Scope` DO.
  - Response: `{ projectId, scope, role }`
- `DELETE /invites/<code>` (owner only)
  - Revokes an invite (`{ revoked: true }`).
- `PUT /projects/<id>/members/<userId>` (`{ role: 'editor' | 'viewer' }`, owner only; cannot change owner)
  - Updates role in D1 and projects `projectMember` into the home `Scope` DO.
- `DELETE /projects/<id>/members/<userId>` (owner removes member, or member removes self; owner cannot leave)
  - Marks membership removed in D1 and soft-deletes the projected `projectMember` row in the home `Scope` DO.

## Run Checks

Runs `lint` (`void prepare && oxlint --type-aware --deny-warnings --report-unused-disable-directives`), `typecheck` (`void prepare && tsc --noEmit`), unit tests (`vitest run`), and all local `vite` + `workerd` e2e checks (`e2e`, `e2e:sync`, `e2e:ics`, `e2e:mcp`, `e2e:fault`):

```bash
npm run check
```

To run only the fast static and unit checks (`lint`, `typecheck`, `test`) without starting a local dev server:

```bash
npm run check:fast
```

Individual e2e suites:

- `npm run e2e` (`scripts/e2e.mjs`): auth and session e2e
- `npm run e2e:sync` (`scripts/e2e-sync.mjs`): sync e2e, or run a single scenario (`fixture`, `lww`, `concurrency`, `replay`, `paging`, `auth`, `id_race`, `unknown_row`, `move_task`, `child_task_id`, `two_device`, `sharing`, `move_with_child`, `attachment`):
  ```bash
  npm run e2e:sync
  node scripts/e2e-sync.mjs --only concurrency
  ```
- `npm run e2e:ics` (`scripts/e2e-ics.mjs`): ICS subscription sync and cron e2e
- `npm run e2e:mcp` (`scripts/e2e-mcp.mjs`): MCP OAuth, tools, and hostname gate e2e
- `npm run e2e:fault` (`scripts/e2e-fault.mjs`): negative check running `e2e-sync --only concurrency` with `SYNC_FAULT=split-txn` and asserting it fails with the expected concurrency assertion

Measured wall time per stage (Mac mini, 2026-11-16, each stage run alone with `/usr/bin/time -p npm run <stage>`):

| Stage | Seconds |
| --- | --- |
| `lint` (type-aware, includes `void prepare`) | 0.6 |
| `typecheck` | 0.5 |
| `test` (vitest) | 2.2 |
| `e2e` | 1.7 |
| `e2e:sync` | 2.1 |
| `e2e:ics` | 2.1 |
| `e2e:mcp` | 2.9 |
| `e2e:fault` | 1.5 |
| `check` (all of the above) | about 13.5 |

`check:fast` is the first three rows, about 3 seconds. Under heavy machine load (load average above 100) the same stages took about 2.5 times as long (`check` 37.8 seconds).

## Deploy

In a fresh checkout, link this directory to the Cloudflare account first (`.void/` is gitignored, so every new worktree needs this; `void.lock.json` already pins the account, Worker name and D1 database):

```bash
npx void connect --platform cloudflare
```

Production secrets are already set on the Worker. To change one, use `void secret put <NAME>` (reads stdin) or `void secret sync <file outside the repo> --yes`. Required: `JWT_SECRET`, `GOOGLE_AUDIENCE`, `ACCESS_TEAM_DOMAIN`, `ACCESS_AUD`, and `SCOPE_PHYSICAL_NAMES` once a scope has been relocated (its value is in 1Password vault `Agent`, item "DayDo SCOPE_PHYSICAL_NAMES"; if it goes missing nothing errors, reads still work from the frozen old DO and every write gets HTTP 503).

R2 object storage (`STORAGE` binding via `void/storage`) is inferred from `src/deps.ts` and `void.config.ts`. During `npx void deploy --platform cloudflare`, Void automatically creates or adopts the R2 bucket `daydo-api-storage` and records it in `void.lock.json` (only needed when recreating the environment: run `CLOUDFLARE_ACCOUNT_ID=<account_id from void.lock.json> cf r2 buckets create --name daydo-api-storage` from a temp directory). Locally, `vite` / `void dev` runs an in-process R2 simulator.

The Worker's fetch handlers run near Tokyo (`placement.region: "aws:ap-northeast-1"` in `void.config.ts`), next to the D1 primary (NRT). On 2026-11-19, traffic from a HiNet line in Taiwan was observed entering Cloudflare at SJC (Free zone), so without this every D1 query and Durable Object call from that Worker crosses the Pacific. Cron handlers and Durable Objects are not affected by placement. The `cf-placement` response header shows where a request ran (`remote-NRT`).

D1 read replication is off: `void.config.ts` sets `database.readReplication: false`, and `void deploy` applies it to the production database (needs a token with D1 Edit). Older Void versions enabled replicas automatically; they used to help because the Worker ran at SJC and read from WNAM replicas, but with the Worker placed next to the primary every query is already local. Every D1 session is still opened in `src/deps.ts` as `first-primary`. Check the current mode with `CLOUDFLARE_ACCOUNT_ID=<account_id from void.lock.json> cf d1 get <database_id>` from a temp directory.

The snapshot page size (`PULL_LIMIT` in `src/serverops/snapshot.ts`, used by MCP tools and the ICS cron) must only grow beyond 1000 on Scope DOs that already enforce the per-page size budget (`MAX_PULL_PAGE_CHARS` in `src/scope/pull.ts`, commit 3443491). An active DO keeps its old code for up to 300 seconds after a deploy (the default deferred code update), so deploy a page-size increase only after the budget deploy has served 100% of traffic for more than 5 minutes and `events.durableObjectsInvocations` shows no rows from the older `scriptVersion`. Never roll back below the budget version while the page size is above 1000.

Worker ↔ Durable Object RPC changes (for example `ScopePushInput` in `src/scope/api.ts`) must be forward and backward compatible: a deploy rolls out Workers and DOs independently, so old and new versions call each other for a while. Add optional fields instead of reshaping existing ones; `tests/scope-rpc-compat.test.ts` pins the push RPC against the 701de08 Scope DO.

Do not run `vite build` or other builds in this directory while `void deploy` is running: a non-deploy build rewrites `dist/` and the deploy refuses the output.

Deploy to Cloudflare Workers (behind Cloudflare Access at `https://api.daydoapp.com`):

```bash
CF_ACCESS_CLIENT_ID=... CF_ACCESS_CLIENT_SECRET=... CF_ACCESS_READINESS_ORIGIN=https://api.daydoapp.com npx void deploy --platform cloudflare
```

Void probes `/__void/ready` on the first entry of `routes`, and a new Custom Domain is attached only after that probe passes. When adding a hostname, list it after an already attached one for the first deploy (and point `CF_ACCESS_READINESS_ORIGIN` at that attached host), then move it back; otherwise the deploy fails with "did not pass /__void/ready" and rolls back.

Verify the deployed Worker with the smoke test:

```bash
CF_ACCESS_CLIENT_ID=... CF_ACCESS_CLIENT_SECRET=... npm run smoke:prod
```

Attachment R2 upload/download verification is covered in [`.claude/skills/verify/features/attachments.md`](./.claude/skills/verify/features/attachments.md).

### Measuring latency

Measure before and after a performance change, with the App's real path rather than `GET /` or MCP alone:

```bash
JWT_SECRET=... CF_ACCESS_CLIENT_ID=... CF_ACCESS_CLIENT_SECRET=... node scripts/measure-latency.mjs <userId>
```

It only pulls (read-only) with a 10-minute token for that user. `GET /health` is the network floor (it touches neither D1 nor a Scope), a backfill of an unknown project runs the pull's D1 queries without calling any Scope, and the incremental pull minus those two splits server time into D1 and Scope. Full pulls at limits 200, 500 and 1000 must return the same row count; per-page cost shows whether page count or payload dominates.

Server-side numbers come from Workers Analytics with `cf sql query` (use `node_modules/.bin/cf`, cf 1.x; the global `cf` may be 0.x without `sql`). Columns are `wallTimeUs`, `cpuTimeUs`, `coloCode`, `scriptVersion`, `responseBodyBytes`; datasets are sampled, so `MAX`/quantiles must be `APPROX_*` and `ORDER BY` needs a `LIMIT`. The dataset has no request path: compare one request type across versions by grouping on `responseBodyBytes` and `scriptVersion`. `durableObjectsInvocations.wallTimeUs` is not a Scope's own duration (it has exceeded the whole calling request), so do not read it as Scope latency; use the script above.

### Relocating a Scope

A Durable Object stays in the region where it was created. To move a user's logical scope (`u:<userId>`) to a new physical DO created in Tokyo (`locationHint: 'apac-ne'`) while keeping the logical name everywhere in D1 and App cursors:

Both `SCOPE_ADMIN_TOKEN` and `SCOPE_PHYSICAL_NAMES` are set as secrets with `void secret put <NAME>` (reads stdin), not Worker `vars` (Void rejects `worker.vars` for keys declared in `env.ts`).

1. Deploy this code with `SCOPE_PHYSICAL_NAMES` unset, then set a temporary admin secret: `void secret put SCOPE_ADMIN_TOKEN`.
2. Export `SCOPE_ADMIN_TOKEN`, `CF_ACCESS_CLIENT_ID`, and `CF_ACCESS_CLIENT_SECRET`, then run `node scripts/relocate-scope.mjs status <oldPhysical>` **before** freezing and confirm its table counts and `maxServerSeq` match the account (non-empty).
3. Freeze the old DO (blocks writes with HTTP 503 so the App keeps local ops for retry; reads still work without writing): `node scripts/relocate-scope.mjs freeze <oldPhysical>`.
4. Copy every table to the new physical DO with a local JSONL backup and compare digests: `node scripts/relocate-scope.mjs copy <oldPhysical> <newPhysical> <backupDir>`. Verify every table prints `OK` with matching row count and SHA-256. If a copy fails half-way, the target stays in `importing` and cannot be resumed — rerun `copy` with a **new** target physical name and a **new** backup directory.
5. Finish the import (`importing -> live`; verifies old is `frozen`, new is `importing`, and every table digest matches both client-side and inside the target DO's `transactionSync`): `node scripts/relocate-scope.mjs finish <oldPhysical> <newPhysical>`.
6. Before setting the mapping, run `node scripts/relocate-scope.mjs status <newPhysical>` and confirm `state` is `live` and `maxServerSeq` (and table counts) match `<oldPhysical>`.
7. Set `SCOPE_PHYSICAL_NAMES` via `void secret put SCOPE_PHYSICAL_NAMES` with `{"<logicalScope>":"<newPhysical>"}` (stdin).
8. Verify the cut-over with a real write, not only reads: a frozen old DO still answers pulls, so a missing or unparsed mapping can look healthy. Make one change in that scope (for example create and delete a task through MCP), then `status <newPhysical>` must show `maxServerSeq` advanced and `status <oldPhysical>` must still be `frozen` with its old `maxServerSeq`. Also run `node scripts/measure-latency.mjs <userId>` (row counts unchanged).
9. Remove the temporary admin secret (`void secret delete SCOPE_ADMIN_TOKEN`), confirm `POST /admin/scope-relocation` returns 404, and only then record the active Worker version ID (Cloudflare Deployments) as the rollback floor. Treat the new DO as written to from the moment the mapping takes effect (even a verification pull can write member projections).
10. From then on, every version that serves traffic, whether deployed or rolled back to, must contain this change **and** the current `SCOPE_PHYSICAL_NAMES` mapping, and must not bind `SCOPE_ADMIN_TOKEN`. Never `void deploy` a build older than this change (it ignores the freeze and writes to the old DO: split-brain) and never roll back to a version recorded before step 9 (it lacks the mapping, sending writes to the frozen old DO, or restores the admin secret). If no such version exists, deploy a fix forward. Keep the old DO frozen as a read-only backup and **never unfreeze it** once the mapping has taken effect.

## MCP Server (`mcp.daydoapp.com`)

The same Worker also serves the remote MCP server (OAuth 2.1 + JSON-RPC tools + ICS subscription sync). Design: [`../spec/mcp.md`](../spec/mcp.md). The hostname gate (`middleware/00.host.ts`, `MCP_HOST`, default `mcp.daydoapp.com`) runs before Access: on the MCP host only `/`, `/register`, `/token`, `/authorize*` and the two `/.well-known/oauth-*` documents are served (everything else is 404); on `api.daydoapp.com` those MCP paths are 404.

Extra checks: `npm run e2e:ics` (ICS sync and cron) and `npm run e2e:mcp` (OAuth flow, tools, hostname gate). Both are part of `npm run check`.

### Environment

| Name | Kind | Notes |
|---|---|---|
| `MCP_HOST` | default `mcp.daydoapp.com` | hostname gate |
| `GOOGLE_WEB_CLIENT_ID` | default (web client id) | |
| `GOOGLE_WEB_CLIENT_SECRET` | Worker secret, optional | without it the Google button shows "not configured" |
| `APPLE_WEB_AUDIENCE` | default `com.audichuang.daydo.web` | Apple Services ID |
| `DEFAULT_TIMEZONE` | default `Asia/Taipei` | floating ICS times, recurrence "today" |
| `GOOGLE_AUTH_URL`, `GOOGLE_TOKEN_URL`, `APPLE_AUTH_URL`, `ICS_ALLOW_INSECURE_HOSTS` | e2e only | do not set in production |

`JWT_SECRET` is reused (MCP access and refresh keys are derived from it with HKDF). The only new production secret is `GOOGLE_WEB_CLIENT_SECRET`.

### Production setup（已完成；換網域或重建時照做）

1. Secret: `void secret put GOOGLE_WEB_CLIENT_SECRET` (reads stdin). The value lives in 1Password vault `Agent`, item "DayDo Google Web OAuth client (MCP)" (read it with the `claude-agent` service account token).
2. Google Cloud Console: the web client must list the redirect URIs `https://mcp.daydoapp.com/authorize/google/callback` and `http://localhost:5173/authorize/google/callback`.
3. Apple Developer: Services ID `com.audichuang.daydo.web`, grouped under App ID `com.audichuang.daydo`; domain `mcp.daydoapp.com`; Return URL `https://mcp.daydoapp.com/authorize/apple/callback`.
4. DNS / custom domain: `void.config.ts` (`routes`) and `void.lock.json` define both `custom_domain` routes (`api.daydoapp.com` and `mcp.daydoapp.com`) on the same Worker. Leave Cloudflare Access bound to `api.daydoapp.com` only; the MCP host skips Access by hostname.
5. Workers plan: the Free plan (10 ms CPU per invocation) is not enough for ICS parsing or MCP snapshot reads. Use Paid, set `worker.limits.cpu_ms` in `void.config.ts` if needed, and check the plan's subrequest limit per invocation (reduce sources per cron run if necessary).
6. Email: `daydoapp.com` is enabled as a sending domain in Cloudflare Email Sending (DNS status `ready`). Its onboarding added `_dmarc` with `p=reject` for the whole domain, and the root domain has no SPF, so any other service that sends as `@daydoapp.com` must be added to SPF/DKIM first or its mail is rejected.

### After deploy (only when the user asks to deploy)

- Connect Claude, ChatGPT and Codex to `https://mcp.daydoapp.com/` and sign in with a real Apple account in both Safari and Chrome. Confirm: the web Apple `sub` equals the App's `sub` (same account); the Apple `form_post` callback receives the `SameSite=None` cookie; all three clients send `client_id` on `/token`. Repeat once with a Google account.
- `npm run smoke:prod` against `api.daydoapp.com`: Access must still reject requests without a token.
- `POST https://mcp.daydoapp.com/sync/pull` must return 404.
- If the change touches the cron or ICS wiring: production cron cannot run locally. Wait past the next 5-minute mark, then check the cron invocations since the deploy with the `cf` CLI (not wrangler; Workers Logs are off, so query the invocations dataset). Every row must be `success`:

  ```bash
  cf sql query --scope-account <account_id from void.lock.json> --time-since <deploy time, UTC ISO 8601> \
    "SELECT status, count() AS n, APPROX_MAX(timestamp) AS last FROM events.workersInvocations WHERE scriptName = 'daydo-api' AND invocationType = 'cron' GROUP BY status"
  ```

  `cf sql` needs cf 1.x (`cf --version`; 0.x has no `sql`). A `success` invocation does not prove ICS ran: the engine records source errors and still returns. When any source exists, also confirm that `icsSource.lastSyncAt` advanced on its own and that `lastStatus` is `success` (read-only; `CLOUDFLARE_ACCOUNT_ID` set):

  ```bash
  cf d1 query <database_id from void.lock.json> --sql \
    "SELECT id, datetime(lastSyncAt/1000,'unixepoch') AS lastSyncUtc, lastStatus, lastStats FROM icsSource"
  ```

### Adding the connector

- Claude (claude.ai or desktop): Settings, Connectors, Add custom connector, URL `https://mcp.daydoapp.com/`; leave client id/secret empty (dynamic client registration via `/register`), then sign in with Apple or Google in the opened page.
- ChatGPT: Settings, Connectors (Developer mode), create a connector with MCP server URL `https://mcp.daydoapp.com/`, authentication OAuth, then sign in.
- Hermes Agent (verified 2026-11-18): add `mcp_servers.daydo` with `url: https://mcp.daydoapp.com/` and `auth: oauth` to its `config.yaml`, then run `hermes mcp login daydo`. Tools appear as `mcp__daydo__<tool>`.
- mcporter (verified 2026-11-18; for scripts that call tools without a model): add `"daydo": {"baseUrl": "https://mcp.daydoapp.com/"}` under `mcpServers` in `~/.mcporter/mcporter.json`, run `mcporter auth daydo` once, then call `mcporter call daydo.<tool> --no-oauth --output json`.
- Each client signs in on its own. Refresh tokens rotate and reusing an old one revokes the whole family (OAuth spec, `spec/mcp.md` 4.5), so two programs must never share one token file.
- When mcporter is not signed in, it reports `HTTP 200 (SSE error: Invalid content type, expected "text/event-stream")` instead of 401: the tool call gets 401, and the `GET /` that mcporter falls back to returns the 200 JSON metadata (`spec/mcp.md` 2). Treat that error as "not signed in".
- Writes made through MCP show up in the App after its next pull (no push notification).
