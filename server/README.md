# DayDo Server

Cloudflare Worker backend for DayDo, built with [Void](https://void.cloud) (Hono + Vite), Drizzle ORM (D1), and `jose`.

> **Note:** Deployment is not set up yet. This package is currently configured for local development and testing only.

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
- `inboxProjectId` is queried from the user's `Scope` Durable Object (`getInboxProjectId`, filtered by active `projectMembership`), `meMemberId` comes from `user.meMemberId`, and `hasData` is `inboxProjectId !== null`.

## Sync Endpoints

All sync endpoints require `Authorization: Bearer <accessToken>`.

- `POST /sync/push`
  - Body: `{ deviceId, ops: [{ opId, hlc, entity, entityId, op, fields, row }] }` (max 200 ops)
  - Binds new IDs and checks list/membership routing in D1, then routes each scope's ops to its `Scope` Durable Object (`Scope.get('u:<userId>')`), where each batch runs inside `transactionSync` with per-op `opId` deduplication, HLC 5-minute future clamp, and field-level LWW merge (including `schedule` grouped clock).
  - Response: `{ results: [{ opId, status: 'applied' | 'rejected', reason?, row, clocks, gone? }], serverTime }` where `serverTime` is the server HLC string (`<13-digit ms>:<4-digit counter>:server`), monotonic and `>=` every HLC assigned or clamped in the batch.
- `POST /sync/pull`
  - Body: `{ cursors: { "u:<userId>": seq }, backfill?: [projectId], limit? }` (`limit` default `500`, max `1000`).
  - Response: `{ scopes: [{ scope, rows: [{ entity, row, clocks, serverSeq } | { entity, entityId, gone: true, serverSeq }], cursor, hasMore }], memberships: [{ projectId, scope, role }], members: [] }`

## Run Checks

Runs `void prepare && tsc --noEmit`, unit tests (`vitest run`), auth e2e (`scripts/e2e.mjs`), and sync e2e (`scripts/e2e-sync.mjs` against a real local `vite` + `workerd` server and local JWKS server):

```bash
npm run check
```

To run only the sync e2e suite or a single scenario (`fixture`, `lww`, `concurrency`, `replay`, `paging`, `auth`, `id_race`, `unknown_row`, `move_task`, `child_task_id`, `two_device`):

```bash
npm run e2e:sync
node scripts/e2e-sync.mjs --only concurrency
```
