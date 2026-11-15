# server/：同步後端

> 本檔只寫 server 的增量；跨 App 與 server 的規則在根目錄 AGENTS.md。

部署到 Cloudflare 的 Worker（Void 框架，底層 Hono），名稱 `daydo-api`。D1 存跨使用者的資料（帳號、session、成員關係、邀請、`entityHome`／`listScopes`）；任務與清單等列資料存在每位使用者一個的 `Scope` Durable Object。

- `routes/`：HTTP 端點，檔名即路徑；`*.dev.ts` 只在開發建置掛上。邏輯放 `src/`（`auth`、`sync`、`sharing`），route 只做轉接。
- `middleware/01.access.ts`：正式環境的 Cloudflare Access 驗證。
- `db/schema.ts` → `db/migrations/`：D1 schema；改完用 `npx void db generate` 產新 migration，已有的不改。

## 規則

- 每位使用者的 `Scope` DO（`u:<userId>`）用自己的 SQLite 存列資料，寫入包在 `transactionSync` 內同步完成；`SYNC_FAULT=split-txn` 是僅開發建置有效的故障開關，並發測試開啟時必須失敗。
- 正式環境前面是 Cloudflare Access（應用程式「DayDo API (iOS app only)」，只放行 service token）。部署、secrets 與部署後的 smoke 照 `README.md` 的 Deploy；service token 與 `JWT_SECRET` 在 1Password `Agent` vault（「DayDo Cloudflare Access service token」「DayDo server JWT_SECRET」）。
- 改了 D1 schema 的部署會先套 migration 並留還原點。
- void 固定 1.8.0：npm 設定只裝發布滿 3 天的版本，新版會被拒，不要改 npm 設定繞過。
- Lint 用 oxlint（`npm run lint`，警告也算失敗，已含在 `npm run check`），不另加 ESLint 或 Prettier。
