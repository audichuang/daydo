# server/：同步後端

> 本檔只寫 server 的增量；跨 App 與 server 的規則在根目錄 AGENTS.md。

部署到 Cloudflare 的 Worker（Void 框架，底層 Hono），名稱 `daydo-api`。D1 存跨使用者的資料（帳號、session、成員關係、邀請、`entityHome`／`listScopes`）；任務與清單等列資料存在每位使用者一個的 `Scope` Durable Object。

- `routes/`：HTTP 端點，檔名即路徑；`*.dev.ts` 只在開發建置掛上。邏輯放 `src/`（`auth`、`sync`、`scope`、`membership`、`sharing`、`attachments`、`mcp`、`oauth`、`serverops`、`domain`、`ics`），route 只做轉接。附件檔案存 Cloudflare R2（`STORAGE` binding，經 `src/deps.ts` 的 `createStorage` 注入 `AppDeps.storage`，物件 key 為 `att/<taskId>/<attachmentId>`）。
- `durable-objects/scope.ts` 只是 RPC 轉接器（開 `transactionSync`、持 HLC 狀態與故障開關）；Scope 帳本的規則在 `src/scope/`（schema、store、push 授權、成員投影、purge、pull、row 檢視），全部是同步函式。Worker↔DO 的 RPC 介面改動必須前後相容：部署期間新舊版本會混跑（`tests/scope-rpc-compat.test.ts` 會拿 main 的舊 DO 實跑）。
- 名詞（Scope ledger、D1 帳本、OpEnvelope、intent、purged 與 gone）見 `GLOSSARY.md`；`src/membership/` 給可組進 `db.batch()` 的 statement，永久刪除清單的原子性靠同一個 batch。
- `middleware/01.access.ts`：正式環境的 Cloudflare Access 驗證。
- `db/schema.ts` → `db/migrations/`：D1 schema；改完用 `npx void db generate` 產新 migration，已有的不改。

## 規則

- push 只能為「重送也不會變」的結果回 `rejected`（資料不合法、權限不足、清單已永久刪除）：App 把 `rejected` 當已確認、永不重送。版本不一致、逾時這類暫時性錯誤回 429／5xx，讓整批重送。
- 每位使用者的 `Scope` DO（`u:<userId>`）用自己的 SQLite 存列資料，寫入包在 `transactionSync` 內同步完成；`SYNC_FAULT=split-txn` 是僅開發建置有效的故障開關，並發測試開啟時必須失敗。改 push 路徑或 Scope DO 後要確認 `npm run e2e:fault` 通過（它證明 `split-txn` 故障會被並發測試抓到）。
- 正式環境前面是 Cloudflare Access（應用程式「DayDo API (iOS app only)」，只放行 service token）。部署、secrets 與部署後的 smoke 照 `README.md` 的 Deploy；service token 與 `JWT_SECRET` 在 1Password `Agent` vault（「DayDo Cloudflare Access service token」「DayDo server JWT_SECRET」）；service token 的 `username` 欄是 `CF_ACCESS_CLIENT_ID`、`credential` 欄是 `CF_ACCESS_CLIENT_SECRET`，用 `op read` 帶進環境變數。
- 改了 D1 schema 的部署會先套 migration 並留還原點。
- void 用 npm `latest` 的最新穩定版（不用 beta／rc），`package.json` 釘精確版本，不挑舊版。npm 設定只裝發布滿 3 天的版本，最新版未滿 3 天時只對那次安裝加 `--min-release-age=0`，不改 npm 設定。
- Lint 用 oxlint（`npm run lint`，警告也算失敗，已含在 `npm run check`），不另加 ESLint 或 Prettier。`.oxlintrc.json` 規定模組間的 import 方向、禁止循環 import、檔案行數上限、`routes/**` 不得 import `void/db` 與 `durable-objects/`，並開了型別感知規則（例如忘了 await DO 或 D1 呼叫）；lint 表達不了的（`createDb(`／`Scope.get(` 只准在 `src/deps.ts`，其餘入口都跟 `productionAppDeps` 拿；重複的 updatedAt 計算、`u:` 字面值、驗證單點、`src/scope` 不得 async 等）在 `tests/architecture.test.ts`；這兩道擋下時改程式的結構，不要放寬規則。
- 新的 server 測試用 `tests/helpers/serverHarness.ts`，時間用 `getNow` 注入，不用 fake timers（`tests/architecture.test.ts` 擋）。
- 日常改動用 `npm run check:fast`（lint、typecheck、vitest），每張票結尾與合併前跑完整的 `npm run check`（含 e2e 與 `e2e:fault`）。e2e 各自挑空 port，多個 worktree 可同時跑；固定用 :8787 的只有 verify skill 的 devserver。

## MCP 與 ICS（細節在 `../spec/mcp.md`）

- 同一個 Worker 服務兩個主機：`api.daydoapp.com`（App，Access 把關）與 `mcp.daydoapp.com`（MCP）。`middleware/00.host.ts` 依 `MCP_HOST` 做主機名閘門，排在 Access 之前、開發與正式建置都生效；MCP 主機只放行 `/`、`/register`、`/token`、`/authorize*`、兩個 `/.well-known/oauth-*`，其餘 404，API 主機則 404 這些 MCP 路徑。改路由時兩邊都要測（`npm run e2e:mcp`）。
- `src/mcp/`：JSON-RPC 傳輸、工具註冊與工具實作，工具清單以 `spec/mcp.md` 第 8 節為準。`src/oauth/`：OAuth 2.1（註冊、授權頁、token、refresh），金鑰由 `JWT_SECRET` 以 HKDF 衍生，不另設 secret。
- `src/serverops/`：伺服器端讀 snapshot、寫 op（走與 `/sync/push` 相同的 Scope DO 路徑），MCP 與 ICS 都經它寫入，不繞過去直接寫 DO。`writer` 自己補 `updatedAt`（呼叫端傳 `nowMs`）與 schedule 成組；與 App `LocalDayDoAPI` 對齊的任務寫入（完成重複任務、checklist、標籤）在 `taskWrites.ts`，MCP 工具只做參數解析與格式化。
- `src/domain/`：從 Swift 移植的規則（重複、提醒、排程、sortKey、標籤、uuid），以 `spec/fixtures` 的向量測試，行為要和 Swift 一致，改一邊就要改另一邊。
- `src/ics/` 與 `crons/ics-sync.ts`：ICS 訂閱同步，cron 每 5 分鐘一輪；cron 經 `productionAppDeps(env)` 拿 db 與 Scope stub，`env` 用 handler 參數。
- 正式環境新增的 secret 只有 `GOOGLE_WEB_CLIENT_SECRET`（1Password `Agent` vault「DayDo Google Web OAuth client (MCP)」）；Access 不動。MCP 的部署與合併後手動步驟在 `README.md`「MCP Server」。
- 部署後或改了 auth／sync／OAuth／MCP 工具，要在正式環境證明行為時用 `.claude/skills/verify/`（信箱註冊、灌資料、`claude mcp login`、`claude -p` 斷言）；測試帳號 `pokemongo030501@gmail.com` 的 Gmail 在 ego-browser 第 8 個帳號。
