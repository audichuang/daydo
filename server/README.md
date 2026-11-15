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
- `WRITER_QUEUE` (`on` | `off`, default: `on`; dev-only toggle to bypass the Durable Object writer queue for concurrency race testing)

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

## Sync Endpoints

All sync endpoints require `Authorization: Bearer <accessToken>`.

- `POST /sync/push`
  - Body: `{ deviceId, ops: [{ opId, hlc, entity, entityId, op, fields, row }] }` (max 200 ops)
  - Serialized through the `Writer` Durable Object (`Writer.get('global')`) with per-op `opId` deduplication, HLC 5-minute future clamp, field-level LWW merge (with `schedule` grouped clock), and D1 `batch()` writes.
  - Response: `{ results: [{ opId, status: 'applied' | 'rejected', reason?, row, clocks }], serverSeq }`
- `GET /sync/pull?since=<seq>&limit=<n>&project=<id>`
  - Query: `since` (default `0`), `limit` (default `500`, max `1000`), optional `project` filter.
  - Response: `{ rows: [{ entity, row, clocks, serverSeq }], cursor, hasMore }`

## Run Checks

Runs `void prepare && tsc --noEmit`, unit tests (`vitest run`), auth e2e (`scripts/e2e.mjs`), and sync e2e (`scripts/e2e-sync.mjs` against a real local `vite` + `workerd` server and local JWKS server):

```bash
npm run check
```

To run only the sync e2e suite or a single scenario (`fixture`, `lww`, `concurrency`, `replay`, `paging`, `auth`):

```bash
npm run e2e:sync
node scripts/e2e-sync.mjs --only concurrency
```
