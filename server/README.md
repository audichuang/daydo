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
  - Response: `{ accessToken, refreshToken, user: { id }, isNewAccount, hasData, meMemberId, inboxProjectId }`
- `POST /auth/refresh` (`{ refreshToken }`)
  - Response: `{ accessToken, refreshToken, hasData, meMemberId, inboxProjectId }`
  - Grace rule: retrying a token rotated within 10 minutes whose successor is still unrevoked revokes that unused successor and issues a new token pair; any other reuse revokes the session chain (`401`).
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
  - Response: `{ scopes: [{ scope, rows: [{ entity, row, clocks, serverSeq } | { entity, entityId, gone: true, serverSeq }], cursor, hasMore }], memberships: [{ projectId, scope, role }], members: [{ id, userId, name, initial, color, isMe, createdAt, updatedAt }] }`

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

Runs `void prepare && tsc --noEmit`, unit tests (`vitest run`), auth e2e (`scripts/e2e.mjs`), and sync e2e (`scripts/e2e-sync.mjs` against a real local `vite` + `workerd` server and local JWKS server):

```bash
npm run check
```

To run only the sync e2e suite or a single scenario (`fixture`, `lww`, `concurrency`, `replay`, `paging`, `auth`, `id_race`, `unknown_row`, `move_task`, `child_task_id`, `two_device`, `sharing`, `move_with_child`):

```bash
npm run e2e:sync
node scripts/e2e-sync.mjs --only concurrency
```

## Deploy

In a fresh checkout, link this directory to the Cloudflare account first (`.void/` is gitignored, so every new worktree needs this; `void.lock.json` already pins the account, Worker name and D1 database):

```bash
npx void connect --platform cloudflare
```

Production secrets are already set on the Worker. To change one, use `void secret put <NAME>` (reads stdin) or `void secret sync <file outside the repo> --yes`. Required: `JWT_SECRET`, `GOOGLE_AUDIENCE`, `ACCESS_TEAM_DOMAIN`, `ACCESS_AUD`.

Do not run `vite build` or other builds in this directory while `void deploy` is running: a non-deploy build rewrites `dist/` and the deploy refuses the output.

Deploy to Cloudflare Workers (behind Cloudflare Access at `https://daydo-api.audichuang.app`):

```bash
CF_ACCESS_CLIENT_ID=... CF_ACCESS_CLIENT_SECRET=... CF_ACCESS_READINESS_ORIGIN=https://daydo-api.audichuang.app npx void deploy --platform cloudflare
```

Verify the deployed Worker with the smoke test:

```bash
CF_ACCESS_CLIENT_ID=... CF_ACCESS_CLIENT_SECRET=... npm run smoke:prod
```
