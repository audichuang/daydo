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

## Run Checks

Runs `void prepare && tsc --noEmit`, unit tests (`vitest run`), and the end-to-end test (`scripts/e2e.mjs` against a real local `vite` + `workerd` server and local JWKS server):

```bash
npm run check
```
