# DayDo 第三階段：遠端 MCP 與 ICS 訂閱同步

> 狀態：設計定稿（第二版，已納入審查意見），尚未實作。這份文件是 `spec/mcp.md`。改協議或兩端行為時，先改這份與 `spec/sync.md`。
> 參考實作 `_ref/ticktick-mcp`（以下簡稱 REF）是單人 TickTick 代理。本設計只借它的協定層、工具名與 ICS 語意。REF 唯讀，不修改。
> 審查意見逐條的採納與否決理由見第 15 節。

## 1. 目標與範圍

- 在現有 Worker `daydo-api` 上加一個遠端 MCP server，用第二個主機名 `daydo-mcp.audichuang.app` 對外。
  - 這個主機名不放 Cloudflare Access。
  - `daydo-api.audichuang.app` 維持原本的 Access。
- OAuth 2.1：DCR、PKCE（S256）、JWT access token，每次都發 refresh token。
  - `/authorize` 讓使用者用 DayDo 帳號登入，方式是 Google 網頁登入、Sign in with Apple JS 或信箱驗證碼，登入後再按同意。
- 登入身分只對應既有的 `identity(provider, sub) → userId`，**不建立新帳號**。
- MCP 工具沿用 REF `src/tools.ts` 的名稱與欄位，只搬 DayDo 有資料的工具（見第 8 節）。
- ICS 行事曆訂閱：
  - 每位使用者的來源各存一列在 D1。
  - cron 定期同步，把事件寫成 DayDo 任務。
  - 來源只透過 MCP 工具管理。
- 讀寫路徑：
  - 所有寫入都組成 sync op，走 `executeSyncPush`，App 下次 pull 就會看到。
  - 所有讀取都經過成員資格過濾（`executeSyncPull`）。

不在範圍內：
- WebSocket 推播（App 仍在下次 pull 才看到 MCP 寫入）
- 附件上傳
- habit
- 資料夾與成員管理工具
- 網頁版 DayDo

## 2. 架構總覽

同一個 Worker、同一份程式，由主機名決定能走哪些路徑。

```
server/
  middleware/00.host.ts        主機名閘門（新增，開發與正式都生效）
  middleware/01.access.ts      既有；MCP 主機名跳過
  routes/index.ts              MCP：GET＝health＋protected-resource metadata，POST＝JSON-RPC
  routes/register.ts           DCR
  routes/token.ts              token endpoint
  routes/authorize/index.ts    GET 登入頁／同意頁，POST 同意
  routes/authorize/google/callback.ts   （GET）
  routes/authorize/apple/callback.ts    （Apple form_post，POST）
  routes/.well-known/oauth-authorization-server.ts
  routes/.well-known/oauth-protected-resource.ts
  crons/ics-sync.ts
  src/oauth/     tokens、metadata、cors、register、codes、refresh、token、authorize、webIdentity、googleCallback、pages、cleanup
  src/mcp/       protocol（JSON-RPC）、auth（Bearer）、registry（validateArgs、HINTS）、toolkit（工具共用的參數驗證與型別，tools 不 import registry）、log、format、tools/{projects,tags,tasks,ics}.ts
  src/serverops/ snapshot（讀）、writer（寫）、values（schedule 欄位與比較）、taskWrites（與 App 對齊的任務寫入）
  src/domain/    uuid、sortKey、tags、reminders、schedule、recurrence（Swift 邏輯的 TS 移植）
  src/ics/       types、parser、filters、store、fetch、engine、cron
  src/sync/serverClock.ts      共用的伺服器 HLC 時鐘單例（從 routes/sync/push.ts 移出）
```

**MCP endpoint 放在主機根目錄 `https://daydo-mcp.audichuang.app/`**，與 REF 相同。
- resource 等於 origin，metadata 放在 `/.well-known/oauth-protected-resource`。
- REF 已在 Claude、ChatGPT、Codex 實測過這個形狀。
- Codex（rmcp）會 `GET <server url>`，並把 200 的 JSON 當成 protected-resource metadata 讀。所以 `GET /` 回傳的 body 同時帶 `resource`、`authorization_servers`、`ok`、`server`、`protocol`。

新依賴只有 `ical.js@2.2.1`（與 REF 同版）。JSON-RPC、CORS、OAuth 都手寫，不引入 `@modelcontextprotocol/sdk`，也不引入 `hono/cors`。

## 3. 主機名閘門與 Access

- 新增 env `MCP_HOST`，預設 `daydo-mcp.audichuang.app`。比對 `new URL(c.req.url).hostname`，不比對 port。
- `middleware/00.host.ts` 在開發與正式建置**都**生效，而且排在 Access 之前。它不受「開發建置跳過 Access」影響，所以 e2e 能證明閘門有效。
- **MCP 主機**只放行下列路徑，其餘一律 404：
  - `/`
  - `/register`、`/token`
  - `/authorize`，以及 `/authorize/` 底下的路徑
  - `/.well-known/oauth-authorization-server`、`/.well-known/oauth-protected-resource`
  - 這個主機上的 `OPTIONS` preflight 由閘門直接回 204，並帶 CORS 標頭。
- **其他主機（daydo-api）**：上面這些 MCP 路徑一律 404，其餘照舊交給 Access。
- `createAccessMiddleware` 遇到 MCP 主機時直接 `next()`。其他主機的行為完全不變，正式環境仍然要求 `Cf-Access-Jwt-Assertion`。
- `/__void/*` 由 Void wrapper 在 app 中介層之前處理，兩個主機都會收到。其中只有 `/__void/ready` 公開，其餘都有 token 把關，不另外處理。
- e2e 不改 Vite 設定：
  - 設 `MCP_HOST=localhost`。
  - `http://localhost:<port>` 當 MCP 主機，`http://127.0.0.1:<port>` 當 API 主機。

## 4. OAuth 2.1

### 4.1 端點與 metadata

- `/.well-known/oauth-authorization-server` 的 metadata 照 REF：
  - `issuer` 等於 origin
  - `authorization_endpoint`、`token_endpoint`、`registration_endpoint`
  - `response_types_supported:["code"]`
  - `grant_types_supported:["authorization_code","refresh_token"]`
  - `code_challenge_methods_supported:["S256"]`
  - `token_endpoint_auth_methods_supported:["none"]`
  - `scopes_supported:["mcp","offline_access"]`
- `/.well-known/oauth-protected-resource` 回傳 `{resource: origin, authorization_servers:[origin], scopes_supported, bearer_methods_supported:["header"]}`。
- origin 一律由請求 URL 推得。主機名閘門已保證這只會是 MCP 主機。
- CORS：
  - `/`、`/register`、`/token`、`/.well-known/*` 帶 CORS `*`。這些端點用 Bearer 認證，`*` 是刻意保留。
  - `/authorize*` 不帶 CORS。

### 4.2 D1 資料表（與 ICS 共用一支 migration，用 `npx void db generate` 產生）

| 表 | 欄位重點 |
|---|---|
| `emailCode` | `id`、`email`（小寫去空白）、`codeHash`（`SHA-256(code + salt)`）、`salt`、`attempts`、`createdAt`、`expiresAt`（10 分鐘）、`usedAt`、`pendingId`（MCP 授權頁發的碼綁定的 pending，App 登入為 null）、`ipHash`（限速用） |
| `oauthClient` | `clientId`（`mcp-` 加隨機 base64url）、`clientName`、`redirectUris`（JSON）、`ipHash`（DCR 限速用）、`createdAt` |
| `oauthPending` | `id`（32 bytes 隨機值，兼作給 Google／Apple 的 `state`）、`clientId`、`redirectUri`、`codeChallenge`、`scope`、`clientState`、`resource`、`bindHash`、`provider`、`nonce`（raw）、`userId`（callback 驗過後才填）、`consentTokenHash`、`createdAt`、`expiresAt`（10 分鐘）、`consumedAt`、`ipHash`（`/authorize` 限速用，可為 null） |
| `oauthCode` | `codeHash`（主鍵）、`clientId`、`redirectUri`、`codeChallenge`、`scope`、`resource`、`userId`、`familyId`、`expiresAt`（120 秒）、`usedAt` |
| `oauthRefresh` | `refreshHash`（主鍵）、`familyId`、`userId`、`clientId`、`scope`、`resource`、`createdAt`、`expiresAt`（30 天，每次輪替重算）、`revokedAt`、`replacedBy`（後繼列的 `refreshHash`） |

- 不用 KV。所有「只能用一次」的動作都是單一條件式寫入，例如：

```sql
UPDATE oauthCode SET usedAt=? WHERE codeHash=? AND usedAt IS NULL AND expiresAt>? RETURNING *
```

- D1 不存任何可還原的 token，只存 SHA-256。

### 4.3 DCR `/register`

- 收 `redirect_uris`（1–5 個）與 `client_name`（≤100 字，可省略）。
- `redirect_uris` 必須是 https，或 hostname 為 `localhost`／`127.0.0.1` 的 http，不得帶 fragment。
- 持久化後回 201，形狀照 REF：
  - `client_id`
  - `token_endpoint_auth_method:"none"`
  - `grant_types:["authorization_code","refresh_token"]`
  - `response_types:["code"]`
  - `client_secret_expires_at:0`
  - `scope:"mcp"`
- **限速依來源 IP 計算**：
  - `ipHash` 取 `SHA-256("dcr|" + key)`。`key` 由 `CF-Connecting-IP` 算出：IPv4 原樣，IPv6 取前 64 位元（`2001:db8:1:2::/64`，一台主機通常握有整個 /64），開發建置沒有這個標頭時用 `local`。
  - 同一個 `ipHash` 每小時最多 10 筆，超過回 429。
  - 不設全域上限，否則任何人送 30 個請求就能讓全家連不上新的 connector。

### 4.4 `/authorize` 流程

**瀏覽器綁定 cookie**
- 名稱 `daydo_oauth_bind_<pending id 前 16 字元>`，每個 pending 一個 cookie，所以同一個瀏覽器同時開多個授權分頁互不覆蓋；屬性 `HttpOnly; Secure; SameSite=None; Path=/authorize; Max-Age=600`（等於 pending 的有效期，過期自動消失），值是 32 bytes 隨機值，D1 只存它的雜湊 `bindHash`。
- 用 `SameSite=None` 是為了讓 Apple 的跨站 form_post（頂層導覽）也帶得到這個 cookie。
- **兩個 callback、同意頁 GET、同意 POST 都比對這個 cookie。**
- callback 比對失敗時，把 pending 標成 `consumedAt`（終結）並顯示錯誤頁。
- 這樣「發起授權的瀏覽器」就必須等於「完成登入的瀏覽器」，可以擋住授權注入：攻擊者開了授權流程，再把 provider 網址丟給受害者登入。

**限速**
- 建立 pending 前，依來源 IP 計數：`ipHash` 取 `SHA-256("authorize|" + key)`，`key` 的算法與 DCR 相同（IPv6 取 /64）。
- 同一個 `ipHash` 每小時最多建 30 筆 pending，超過回 429 錯誤頁，不寫入、不發 cookie。參數或 client 驗證失敗的請求不寫入，所以不計數。

**流程**

1. **`GET /authorize`**（不帶 `pending`）
   - 驗證參數，規則照 REF `validateParams`：
     - `response_type=code`
     - `code_challenge` 必填，`code_challenge_method=S256`
     - scope 必須在支援清單內，且包含 `mcp`
   - 另外要求：
     - `client_id` 已註冊。
     - `redirect_uri` **精確等於**註冊值之一。
     - `resource`（可省略）滿足 `new URL(resource).origin === origin`。
   - 不符時顯示錯誤頁，**不**導回 `redirect_uri`，避免 open redirect。
   - 通過後建立 `oauthPending`，設綁定 cookie，頁面顯示 Google、Apple 兩個按鈕與第三個選項「信箱」（見下方「信箱驗證碼」）。
   - 按鈕連到 `/authorize/start?pending=<id>&provider=…`。這是一支 GET，比對 cookie、把 provider 寫進 pending，再 302 到 provider；路徑在 `/authorize/` 底下。
2. **Google**
   - 導向 `GOOGLE_AUTH_URL`（預設 `https://accounts.google.com/o/oauth2/v2/auth`），參數：
     - `client_id=GOOGLE_WEB_CLIENT_ID`
     - `redirect_uri=<origin>/authorize/google/callback`
     - `response_type=code`、`scope=openid email profile`
     - `state=<pending id>`、`nonce=<raw nonce>`、`prompt=select_account`
   - `GET /authorize/google/callback`：
     1. 依 `state` 取 pending，檢查未過期、未消耗、provider 相符。
     2. 比對 cookie。
     3. 帶 `error`（例如 `access_denied`）時顯示「已取消，請重新開始」，**不**消耗 pending，使用者可以按另一個按鈕重試。
     4. 用 `GOOGLE_TOKEN_URL`（預設 `https://oauth2.googleapis.com/token`）加 `GOOGLE_WEB_CLIENT_SECRET` 換 `id_token`。
     5. 用 `verifyGoogleToken` 驗證：`audience=GOOGLE_WEB_CLIENT_ID`，並新增可選的 nonce 比對（Google 回傳 raw nonce）。
3. **Apple（Sign in with Apple JS，無 .p8）**
   - 導向 `APPLE_AUTH_URL`（預設 `https://appleid.apple.com/auth/authorize`），參數：
     - `client_id=APPLE_WEB_AUDIENCE`
     - `redirect_uri=<origin>/authorize/apple/callback`
     - `response_type=code id_token`、`response_mode=form_post`
     - `state`、`nonce=sha256Hex(rawNonce)`
     - 不要求 scope：我們不需要 email 與姓名。
   - `POST /authorize/apple/callback`：
     1. 用 `c.req.parseBody()` 讀 `state`、`id_token`、`error`。
     2. 依 `state` 取 pending，並比對 cookie。
     3. 帶 `error`（例如 `user_cancelled_authorize`）時與 Google 相同處理：顯示錯誤，不消耗 pending。
     4. 用既有的 `verifyAppleToken` 驗證，參數為 `audience=APPLE_WEB_AUDIENCE`、`nonce=rawNonce`。它比對 `payload.nonce === sha256Hex(raw)`，可以直接重用。
     5. 丟棄 `code`（沒有 client secret 可以換）。
3b. **信箱驗證碼（第三個選項）**
   - 使用者輸入信箱 → `POST /authorize/email/start`（帶 pending id，比對綁定 cookie；路徑在 `/authorize/` 底下）→ 寄碼並顯示輸入驗證碼的頁面 → `POST /authorize/email/verify`（pending id、email、code，同樣比對 cookie）。
   - 限速與碼規則與 `spec/sync.md` 的信箱登入相同（碼 6 位、10 分鐘、一次性、每碼猜錯 5 次；每信箱 5 次／小時、每 IP 20 次／小時，與 App 共用額度，超過仍顯示「已寄出」但不寄信並記 log；同信箱 24 小時內兩種流程合計猜錯 10 次即鎖定，鎖定時 start 同樣顯示「已寄出」但不寄信，verify 顯示錯碼訊息）。碼綁定該 pending，不能拿來完成別的 pending，App 也不能用；新 start 只作廢同一個 pending 的舊碼，不影響 App 的碼與其他 pending 的碼。
   - verify 成功後只做「綁定既有使用者」：查 `identity('email', <信箱>)`，找不到時顯示與 Google／Apple 相同的未知身分錯誤頁（**公開的 MCP 主機不註冊帳號**，使用者要先在 API 側用信箱登入建立帳號或用其他方式登入）；找到時接上下一步的條件式 UPDATE 與 consent token，之後與其他 provider 完全相同。
   - `oauth.authorize` 的 log 結果沿用既有分類，信箱路徑的驗證碼錯誤記為 `provider_error`；log 不記驗證碼。
4. **身分對應**
   - 只讀查詢 `SELECT userId FROM identity WHERE provider=? AND sub=?`。
   - 找不到時顯示「這個 Google／Apple／信箱帳號還沒有 DayDo 帳號，請先在 DayDo App 用同一個帳號登入一次」。**不建立帳號，也不呼叫 `createSessionForIdentity`。**
   - 找到時，用條件式 UPDATE（`userId IS NULL AND consumedAt IS NULL`）把 `userId` 寫回 pending，並產生一次性 consent token（D1 存雜湊）。之後 303 到 `GET /authorize?pending=<id>&ct=<consent token>`。
5. **同意頁（`GET /authorize?pending=…&ct=…`）**
   - 比對 cookie、consent token，並確認 pending 已綁定 `userId`。
   - 頁面顯示 DayDo 使用者名稱、client 名稱、redirect 主機，以及要求的權限（讀寫任務、清單、標籤與 ICS 訂閱）。
   - 回應標頭：`Content-Security-Policy: frame-ancestors 'none'`、`X-Frame-Options: DENY`、`Cache-Control: no-store`。
6. **`POST /authorize`（同意或拒絕）**
   - 要求 pending id、consent token、cookie 三者都相符。
   - 用條件式 UPDATE 把 pending 標成 `consumedAt`，只能成功一次。
   - 同意：產生 32 bytes 隨機 code，存進 `oauthCode`（含 `userId`、`resource` 與新的 `familyId`），302 到 `redirect_uri?code=…&state=<clientState>`。
   - 拒絕：302 帶 `error=access_denied`。
7. 頁面文案用繁中，HTML 一律跳脫（沿用 REF 的 `esc`）。

**假身分（開發與 e2e）**
- 不加任何繞過登入的路由。
- e2e 用本機私鑰簽 Apple `id_token`（`aud=APPLE_WEB_AUDIENCE`、`nonce=sha256Hex(raw)`），透過既有的 `APPLE_JWKS_URL` 覆寫指向測試 JWKS，再帶 cookie 直接 POST 到 `/authorize/apple/callback`。
- Google 路徑用 `GOOGLE_TOKEN_URL` 覆寫，指向測試 server 簽的 token。
- 這樣測到的是正式的程式碼路徑。

### 4.5 `/token`

- body 接受 `application/x-www-form-urlencoded` 與 JSON。
- 錯誤格式為 `{error, error_description}`，帶 `Cache-Control: no-store`、`Pragma: no-cache`。
- 非 POST 回 405；`unsupported_grant_type` 回 400。
- **`client_id` 可省略**，照 REF（`src/oauth/token.ts` 兩種 grant 都是「有帶才比對」）：有帶就必須等於 code 或 refresh 列的 `clientId`，不符回 400 `invalid_grant`；沒帶就接受。REF 的這個行為已用 Claude、ChatGPT、Codex 實測過；OAuth 2.1 要求 public client 帶 `client_id`，這裡刻意放寬，避免某家 client 沒帶就換不到 token。

**authorization_code**
1. 要求 `code`、`code_verifier`（缺漏回 `invalid_request`）。檢查 `sha256b64url(verifier) === codeChallenge`。
2. `redirect_uri`、`client_id` 若有帶，必須與 code 記錄相同。PKCE、`redirect_uri`、`client_id` 不符時不消耗 code。
3. 用條件式 UPDATE 原子消耗 code。
4. 確認 `user` 仍存在。
5. 發 access token 與 refresh token，family 為 code 的 `familyId`。**不論 scope 有沒有 `offline_access` 都發 refresh**：ChatGPT 與 Codex 不會要求它，沒有 refresh 的話一小時後就斷線。

**refresh_token**（刻意與 App 的 `session.ts` 不同，理由見第 15 節第 6 條）

- 第一個 refresh token 是 32 bytes 隨機值。之後每次輪替的後繼是確定性的：`successor = base64url(HMAC-SHA256(K_refresh, presentedToken))`。
  - `K_refresh = HKDF(JWT_SECRET, salt="daydo-mcp", info="mcp-refresh-v1")`。
  - D1 只存 SHA-256。光拿到 D1 的內容，算不出任何 token。
- **正常輪替**（D1 batch）：
  1. `INSERT successor ... ON CONFLICT(refreshHash) DO NOTHING`。
  2. `UPDATE 舊列 SET revokedAt=now, replacedBy=successorHash WHERE refreshHash=? AND revokedAt IS NULL AND expiresAt>now`。
- **並發或回應遺失**：
  - 舊 token 在輪替後 10 分鐘內再次出現，而且後繼列仍未撤銷、未過期時，重新計算出**同一個**後繼並回傳，同時重發 access token。
  - 兩個並發請求中，條件式 UPDATE 輸掉的一方會重讀一次，改走這條路徑，所以兩邊拿到相同的 refresh token，不會互相撤銷。
- **其餘重用**（超過寬限期，或後繼已被使用）：撤銷整個 family，回 400 `invalid_grant`。
- 另外要驗證 `client_id`（有帶時）相符、`user` 仍存在；這兩項不符時直接回 `invalid_grant`，不輪替也不撤銷。
- 期限：access token 1 小時；refresh 30 天，每次輪替重算，等於滑動期限。
- 回應形狀：`{access_token, refresh_token, token_type:"Bearer", expires_in:3600, scope}`。

### 4.6 Token 隔離（MCP token 與 App token 不互通）

- MCP access token 是 JWT HS256：
  - 簽章金鑰為 `HKDF-SHA256(JWT_SECRET, salt="daydo-mcp", info="mcp-access-v1")`。
  - header `typ:"at+jwt"`。
  - claims 為 `iss=origin`、`aud=origin`、`sub=userId`、`scope`、`client_id`、`iat`、`exp`。
- 不需要新 secret：金鑰不同，簽章就互相驗不過。
- 縱深防禦：App 用的 `verifyAccessToken` 遇到 payload 帶 `aud`，或 header `typ` 是 `at+jwt`，直接拒絕。**不**要求 App token 帶新的 `aud`，因為現有 App token 沒有這個欄位。
- MCP Bearer 檢查照 REF `serveMcp` 的順序：
  1. 簽章與 `exp`
  2. `iss===origin`
  3. `new URL(aud).origin===origin`
  4. scope 含 `mcp`
  5. 通過後取 `sub` 當 `userId`，並確認 `user` 存在。
- 失敗時回 401，帶 CORS 與 `WWW-Authenticate: Bearer realm="daydo", resource_metadata="<origin>/.well-known/oauth-protected-resource", error="invalid_token"`。
- 雙向測試：App token 打 `/` 要回 401；MCP token 打 API 主機的 `/sync/pull` 也要回 401。

### 4.7 Log

- 每次 MCP 呼叫記一行 `mcp.call`，欄位為 method、tool、`arg_keys`（只記鍵名）、outcome、ms、client_id、userId、ray。
- OAuth 事件記 `oauth.register`、`oauth.authorize`、`oauth.token`。
  - `oauth.authorize` 的結果分類為 `unknown_identity`、`denied`、`provider_error`、`bind_mismatch`、`ok`、`invalid_request`。
- 不記 code、token、verifier、id_token、ICS URL。

### 4.8 過期列清理（`src/oauth/cleanup.ts`）

- 由 ICS 的 5 分鐘 cron 在每個 UTC 整點後的第一輪執行（`scheduledTime` 落在整點後 5 分鐘內），每張表每次最多刪 500 列，用 `DELETE … WHERE pk IN (SELECT … LIMIT 500)`。
- 刪除條件：
  - `emailCode`：`expiresAt` 早於 1 天前（`EMAIL_CODE_RETENTION_MS` 取自跨碼鎖定的 24 小時窗，發出未滿 24 小時的列都留著）。
  - `oauthPending`：`expiresAt` 早於 1 天前。
  - `oauthCode`：`expiresAt` 早於 1 天前。
  - `oauthRefresh`：`expiresAt` 早於 30 天前。每一列都在發出後 30 天內到期，所以已撤銷的列也涵蓋在內；只看到期時間是為了讓撤銷過的列多留 30 天，期間重送舊 token 仍會撤銷整個 family。
  - `oauthClient` 不刪：pending、code、refresh 刪掉之後分不出「從沒用過」和「很久以前用過」，刪掉仍在用的 client 會讓它無法重新連線。
- 成功記一行 `oauth.cleanup`（三張表各刪幾列）。失敗記 `oauth.cleanup.failed` 警告且不 throw，ICS 同步照常執行。

## 5. MCP 傳輸（照搬 REF `src/mcp.ts`）

- `PROTOCOL_VERSION="2025-06-18"`，Streamable HTTP 的純 JSON 子集：沒有 SSE，也沒有 session。
- `SERVER_INFO={name:"daydo", version:<package.json version>}`，有測試守門。
- `initialize` 一律回 `2025-06-18`，capabilities 為 `{tools:{}}`。
- notification（`id` 為 undefined 或 null）回 202 空 body；`ping` 回 `{}`；`tools/list` 一次回全部工具。
- 錯誤碼與 HTTP 狀態：

  | 狀況 | 錯誤碼 | HTTP |
  |---|---|---|
  | `tools/call` 缺工具名 | -32602 | 200 |
  | 未知方法 | -32601 | 200 |
  | 內部例外 | -32603 | 200 |
  | JSON 解析失敗 | -32700 | 400 |
  | 非物件、batch、缺 method | -32600 | 400 |

- 工具層錯誤不是 JSON-RPC error，而是 `{content:[{type:"text",text:"Error: …"}], isError:true}`。
- 成功時回 `{content:[{type:"text",text: JSON.stringify(result)}]}`。
- `validateArgs` 照搬：
  - required 欄位不得為空。
  - **拒絕 schema 沒宣告的欄位**，錯誤訊息列出可接受的欄位。
  - enum 欄位的值必須在列舉內。
  - 另有 `requireStr`、`requireInt`。
- annotations 由 `HINTS` 表集中產生，測試要求每個工具都有 HINTS。

## 6. 伺服器端讀寫

### 6.1 讀：`src/serverops/snapshot.ts`

- `loadSnapshot(db, userId, getScopeStub)` 以 `executeSyncPull(cursors:{}, limit:1000)` 迴圈，直到每個 scope 的 `hasMore=false`。
- **snapshot 保留原始列**：
  - 包括垃圾桶裡的任務（`deletedAt`）與 tombstone（`purgedAt`）。tombstone 保留原本的 `projectId`（`merge.ts` 的 delete 分支複製既有列），所以只要清單仍可見，就會出現在 pull 裡。
  - 只排除 `gone` 列。
  - 每列保留 `clocks`。
- 其他內容：
  - `memberships`：`projectId → role`，取自 pull 回應的 `memberships`。
  - `meMemberId`：**另外查 D1 `user.meMemberId`**，pull 回應沒有這個欄位。
  - `inboxProjectId`：自己 scope 裡 `isInbox` 為真、沒有 `purgedAt` 的清單。
- 可見性過濾放在 helper，由工具層呼叫：
  - `liveTasks()`：`deletedAt` 為 null、沒有 `purgedAt`，且所屬清單未刪除、未封存。
  - `liveProjects()`
  - `canWrite(projectId)`：role 是 `owner` 或 `editor`。
  - ICS engine 與 `complete_task` 直接用原始列。
- pull 的副作用（成員投影對帳、重試 purge 通知）是冪等的，可以接受。
- 一次工具呼叫最多讀一次 snapshot；寫完後以 push 回應的 row 更新記憶體中的列。

### 6.2 寫：`src/serverops/writer.ts`

- 把 MCP／ICS 的意圖組成 op：`{opId, hlc, entity, entityId, op:'upsert', fields, row}`，呼叫 `executeSyncPush(db, {userId, deviceId:'mcp'|'ics', ops, getScopeStub, clock})`。
  - db 用 `createDb(env.DB, {session:'first-primary'})`。
  - clock 用 `src/sync/serverClock.ts` 的單例，與 `/sync/push` 共用。
  - 每批最多 200 個 op，超過就切塊；同一塊內「任務在前、子列在後」。
- **id**：
  - 新實體用 UUIDv7。
  - opId 每個 op、每次嘗試都用新的 UUIDv7。
  - 冪等性來自伺服器事先決定好的實體 id：ICS 會先把 id 存進 mapping。不靠重用 opId，因為重用的 opId 只會拿回舊結果。
- **HLC**：
  - 更新既有列時，hlc 取 `max(now, 該列所有 clocks 的最大 ms) + 1` 毫秒，裝置欄位寫 `server`。
  - 同一批對同一列的多個 op，counter 遞增。
  - 新列用 serverClock 的 `tick(now)`。
- **schedule 是一組**：只要動到任何一個 schedule 欄位，五個欄位（`startDay`、`startMinute`、`endDay`、`endMinute`、`timeZone`）全部放進 `fields`，`row` 帶完整的目前值，沒有值的欄位省略。
- **結果以回應為準，不重送**：
  - 比對 `results[i].row` 與預期值。有欄位沒套用（輸給裝置的 LWW）時，工具回 `isError`，附上伺服器的 row 與未套用的欄位名，請呼叫端重新讀取後再試。
  - 工具回傳的一律是伺服器回應的 row，不是「原本想寫的值」。
  - `rejected` 與 `Forbidden` 原樣轉成工具錯誤。
- **無資料帳號**：`meMemberId` 為 null 或找不到收件匣時，所有寫入工具與 ICS 同步一律拒絕，訊息為「請先在 DayDo App 登入並同步一次」。伺服器不建立 member 或收件匣。
- **值域驗證**：伺服器 push 只驗型別，壞值會讓 App 卡住或崩潰，所以由這一層驗。
  - `priority∈{0,1,3,5}`；task `status∈{0,2}`；checklist `status∈{0,1}`。
  - `startDay`／`endDay` 是真實日期且補零；`startMinute`／`endMinute` 在 0–1439。
  - `timeZone` 用 `Intl.DateTimeFormat` 驗證是有效的 IANA 名稱。
  - 伺服器產生的 `sortKey` 必須符合 `^[0-9a-z]*[1-9a-z]$`（非空、不以 `0` 結尾）。
  - 提醒字串可解析；RRULE 屬於支援子集。
  - `status=2` 時同時寫 `completedAt`；沒有排程時 `reminders=[]`、`repeatRule=null`。
  - `project.ownerId` 是 `meMemberId`；`isInbox` 永遠是 false。

## 7. 領域移植（`src/domain/`，以 Swift 原碼與 fixture 為測試向量）

- **uuid**
  - `uuidv7()`：前 48 bit 是毫秒時間戳，版本 7、variant 10。
  - `uuidv5(name)`：namespace `b4f8c2a0-6e3d-4c1b-9a7f-1d5e8c3a9042`，SHA-1。
  - 向量：namespace 加 `01a1dd5b-fc89-75e1-b4c4-fb62891e2107|2026-11-15|1140` 得到 `cc64dbd5-1983-5448-8442-0fba63492416`（FIX:573）。
- **sortKey**
  - 逐行移植 `between`、`before`、`after`。`a>=b` 時丟錯，不 crash。
  - 向量：
    - after 鏈：`i,r,v,x,y,z,zi,zr,zv`
    - before 鏈：`9,4,2,1,0i,09,04,02`
    - `between("i","r")="m"`、`between("i","j")="ii"`
    - 已知怪例：`between("i","i0")="i0i"`（不嚴格介於兩者之間）
  - 取鍵規則：新任務用 `before(MIN(同清單所有任務))`；checklist、標籤、清單用 `after(MAX)`。
  - **清單 sortKey 要唯一**：`after(MAX(所有可見清單))` 後面接 2 個隨機 base36 字元，**最後一碼不能是 `0`**。上界若等於下界加 `0`，就沒有嚴格介於兩者的鍵，App 的 `moveProject` 會排錯。
  - 「不以 `0` 結尾」只是伺服器產生鍵時的規則，不拿來驗既有列。
- **schedule**
  - 移植 `Schedule.fromAPI`，以及輸出的 `start`／`due`／`all_day`／`timezone`。
  - 牆鐘用 `Intl.DateTimeFormat` 取該時區的年月日時分組件來換算，不用「午夜＋分鐘數」。
  - 定時任務的時區推斷順序：
    1. 呼叫者給的 `timezone`
    2. 原任務的 `timeZone`
    3. 從 offset 推斷：先試 `DEFAULT_TIMEZONE`，再試 App 的 8 個固定時區，以**事件當下**的 offset 比對；都不符合就用 `UTC`。
  - 沒有 offset 也沒有時區時是浮動時間（`timeZone=null`），與 App 相同。浮動任務輸出不帶 offset 的牆鐘字串。
  - 更新任務只給 `due` 時，直接在牆鐘欄位上運算。
- **reminders**：解析與 canonical 輸出照 `Reminders.swift`，例如 `-PT24H`→`TRIGGER:-P1D`、0 秒→`TRIGGER:PT0S`。輸入的 `reminder` 是逗號分隔字串。
- **recurrence**
  - `validateRepeat` 與 `next(after:)` 照 `Recurrence.swift`。
  - 不照抄 App 的缺陷：負的 `BYMONTHDAY` 直接拒絕。
- **tags**：正規化照 `LocalDayDoAPI.normalizeTags`：trim、去掉頭尾 `#`、`name` 用小寫、同一次呼叫內去重。只有 MCP 的 `create_task`／`update_task`／`create_tag` 會用到，ICS 不建標籤（第 9.1 節）。

## 8. MCP 工具

名稱與輸入欄位沿用 REF。
- 任務的輸出形狀用 `spec/openapi.yaml` 的 `Task`（snake_case）：`id, project_id, title, content, priority, status, start, due, all_day, timezone, reminders, repeat, tags, items, completed_at, created_at, updated_at, import_note`。
- 清單的輸出多帶 `role` 與 `can_write`，讓 AI 不要一直嘗試寫唯讀清單。
- 列表型工具輸出摘要：`content` 截成 100 字，`items` 改成數量。

| 工具 | HINT | DayDo 語意 |
|---|---|---|
| `list_projects` | read | 可見清單，收件匣排最前，含 `role`、`can_write` |
| `get_project` | read | `project_id*` |
| `get_project_data` | read | `{project, tasks[]}`，只含未完成任務 |
| `create_project` | write | `name*`、`color`（`#RRGGBB`／`#RGB`）、`view_mode`（list／kanban／timeline）、`kind`（TASK／NOTE） |
| `update_project` | idempotent-overwrite | `project_id*`、`name`、`color` |
| `delete_project` | destructive | 只有 owner 能刪，收件匣不能刪。先軟刪除清單內所有未刪除的任務，再設清單的 `deletedAt` |
| `list_recent_tasks` | read | `project_id*`、`limit`（預設 10）、`active_only`、`tag`；依 `updatedAt` 由新到舊 |
| `list_tasks` | read | `project_id` 可省略；只含未完成，依 `sortKey` |
| `search_tasks` | read | `query*`、`active_only`；比對標題、內容、標籤、checklist 標題；先依 status、再依 `updatedAt` 排序，最多 200 筆 |
| `get_task` | read | `project_id*`、`task_id*`；`project_id` 不符就報錯；回完整紀錄 |
| `create_task` | write | `project_id*`、`title*`、`content`、`priority`（none／low／medium／high）、`start`、`due`、`all_day`、`timezone`、`reminder`、`repeat`、`subtasks`、`tags`。有 `reminder` 卻沒有日期時拒絕；`content` 裡字面的 `\n` 轉成真換行；清單必須可寫。描述沿用 REF 的規則，拿掉 TickTick 專屬段落 |
| `update_task` | idempotent-overwrite | 同上，加 `task_id*`。`repeat:""` 清除重複；`start:""` 清除排程，同時清 reminders 與 repeat；`subtasks` 整份取代（舊項目軟刪除，以新 id 重建，與 App 相同） |
| `complete_task` | idempotent-write | 見下 |
| `delete_task` | destructive | **軟刪除**（`deletedAt`），可以從 App 垃圾桶還原；回 `{deleted:true, task_id, title}`。任務不在該清單時報錯 |
| `move_task` | idempotent-write | `task_id*`、`from_project_id*`、`to_project_id*`；兩邊都要有寫入權 |
| `move_all` | idempotent-write | 搬移來源清單所有未完成任務 |
| `get_completed_tasks` | read | `project_id` 可省略；依 `completedAt` 由新到舊 |
| `list_tags` | read | 使用者自己的標籤 |
| `create_tag` | write | `name*`、`color`；沒有 `parent`（DayDo 沒有巢狀標籤） |
| `add_ics_source` | write、openWorld | 見第 9 節；多一個可選欄位 `timezone` |
| `list_ics_sources` | read | 回傳自己的來源，含 `url` |
| `remove_ics_source` | destructive | `source_id*`（integer）；刪除來源與 mapping，不刪已同步的任務 |
| `sync_ics_now` | destructive、openWorld | `source_id`、`dry_run`、`include_changes`、`allow_mass_delete`（必須同時帶 `source_id`）；描述保留「至少 5 筆且超過一半」的門檻 |
| `get_ics_sync_status` | read | `{id, name, enabled, lastSyncAt, lastStatus, lastStats(字串), mappingCount}` |

**`complete_task`**
- 非重複任務：寫 `status=2` 與 `completedAt`。
- 重複任務照 `LocalDayDoAPI.completeTask`：
  1. 副本 id 用 `uuidv5("<taskId>|<startDay>|<startMinute 或空字串>")`。
     - snapshot 裡該 id 有 `purgedAt` 時，改用 v7。
     - push 回應的 row 帶 `purgedAt` 時（tombstone 不在 snapshot 裡），以 v7 再送一次。
  2. 副本已存在且未刪除時，只更新狀態。
  3. 複製原任務的未刪除 checklist（v5 id），並把原項目重設成未完成。
  4. 原任務 `moved(to: next)`。用 `timeZone ?? DEFAULT_TIMEZONE` 算出的「今天」補進度，最多 1000 次。
  5. `updatedAt=max(now, 舊值+1)`。
  6. op 順序：副本 → checklist → 原任務。回傳副本。
- 已完成的任務原樣回傳。

不搬的工具：
- habit 四個（`list_habits`、`create_habit`、`delete_habit`、`checkin_habit`）
- `make_subtask`（DayDo 只有 checklist，沒有父子任務）
- `get_user_settings`、`get_user_profile`
- `upload_attachment`（附件檔案還不上傳）

`create_task` 與 `update_task` 不宣告 `kind`：DayDo 沒有對應欄位，送了會被 `validateArgs` 以未知欄位拒絕。openapi 上的其他操作（`uncomplete_task`、`restore_task`、checklist 單項、資料夾）之後再加。

## 9. ICS 訂閱同步

### 9.1 移植範圍

- `parser.ts`、`filters.ts`、`types.ts` 幾乎原樣搬，包括：
  - envelope 驗證
  - ical.js 展開與預算上限
  - 身分 `[uid, occurrenceId]`
  - 版本選擇
  - 取消
  - `seriesSignature`
- 改動：
  - 寫死的 `Asia/Taipei` 改成參數，由來源的 `timezone` 傳入，預設 `DEFAULT_TIMEZONE`。
  - `TickTickError` 換成本地的錯誤類別。
  - `eventToTaskBody` 改成 `eventToTaskDraft`，直接產出 DayDo 的 schedule 五欄。
  - 刻意偏離參考實作：只有 RDATE、沒有 RRULE 的重複系列，展開時也包含 DTSTART 那一次（RFC 5545：DTSTART 屬於重複集合；ical.js 在沒有 RRULE 時只吐 RDATE，參考實作因此漏掉它）。DTSTART 那次一樣套用 RECURRENCE-ID 例外，EXDATE 指到它時標為取消。
- **對應到 DayDo 任務**：
  - 標題直接用 `summary`，**不加 `[HH:MM]` 前綴**：DayDo 列表本來就會顯示時間。
  - `content`：description；有地點時空一行接「📍 地點」。
  - 全天事件：`startDay`；`endDay` 為含當天的最後一天，與 start 同一天時不存。
  - 定時事件：以事件的 TZID 換成牆鐘（UTC 事件用來源時區）；浮動時間用來源時區。
  - 只在建立時設定：
    - `priority`：`priorityHigh` 為 5，否則 0。
    - 定時事件的 `reminders=["TRIGGER:-PT15M"]`。
    - `importNote="ICS：<來源名稱>"`。
  - **不把 `CATEGORIES` 轉成標籤**：Outlook／Google feed 常帶 Busy、Meeting 之類的分類，會灌進使用者的標籤清單。
  - 不設 `repeatRule`：重複事件展開成一個個獨立任務。
- **欄位所有權**：
  - ICS 只擁有 `title`、`content`、schedule 五欄。取消與重新開啟時，另外寫 `status`、`completedAt`、`reminders`。
  - 使用者在 App 改的優先度、標籤、提醒、checklist、sortKey 都保留。
  - ICS 永遠不把 `deletedAt` 放進 `fields`，只有「來源刪除事件」例外（見下）。

### 9.2 資料表（與 OAuth 同一支 migration）

- `icsSource`：
  - `id` 是 integer autoincrement，與 REF 的 `source_id` 型別相同。
  - 其他欄位：`userId`、`name`、`url`、`projectId`、`enabled`、`syncIntervalSec`（預設 900，最小 300）、`filterJson`、`timezone`、`lastSyncAt`、`lastStatus`、`lastStats`、`leaseToken`、`leaseUntilMs`、`createdAt`、`updatedAt`。
- `icsMapping`：
  - 主鍵 `(sourceId, icsUid, occurrenceId)`。
  - 其他欄位：`taskId`、`projectId`、`fingerprint`、`sequence`、`dtstamp`、`state`、`seriesSignature`、`lastError`、`updatedAt`。
  - `state` 為 `pending`、`updating`、`applied`、`cancelled`、`purged` 其中之一。
- 所有 store 方法都以 `userId` 限定。只有 cron 用的 `dueSources(now, limit)` 跨使用者，回傳的來源含 `userId`。
- 租約、保留、mapping 更新的條件式 SQL 照 REF `D1IcsStore`：
  - 租約 5 分鐘。
  - 保留用 `ON CONFLICT DO NOTHING`。
  - 更新要求 taskId 相同，且持有有效租約。
- **mapping 寫入改成批次**：
  - `markUpdating(mappings[])` 與 `commitMappings(mappings[])` 各用一次 `db.batch`。
  - 每條語句都帶租約條件；租約失效時整批作廢。
- `removeSource` 用 `db.batch` 同時刪除 mapping 與來源。
- 每位使用者最多 10 個來源。

### 9.3 Engine（`syncSource`）：語意照 REF，寫入目標換成 DayDo

1. 取租約，失敗回 `busy`。
2. 檢查無資料帳號；是的話記 `error` 並結束。
3. 每輪讀一次 snapshot（原始列，第 6.1 節），取代 REF 的 `client.sync()` 與已完成清單。
4. **來源清單必須存在且可寫**（role 為 owner／editor）。不可寫時整輪記一次 `error` 就停，什麼都不寫。這涵蓋清單被刪、被降成 viewer、被移出。
5. 依序執行：
   - `fetchIcs` → `parseIcs` → 只套關鍵字的 filter。
   - 重新定義防護，**以 UID 為單位**：依各 UID 的 master（不看時間窗內展開出哪些 slot）判斷，下列情況該 UID 記一次錯誤、在它的 mapping 留 `lastError`，不寫入也不刪除它的任務，同一來源的其他事件照常同步。
     - 單一事件變成重複系列：master 現在有 RRULE／RDATE，而 mapping 裡有 `occurrenceId=''` 的那筆；或只剩一個 RECURRENCE-ID 例外取代了已匯入的單一事件。
     - 規則被改：去掉 UNTIL／COUNT 後的 `seriesSignature`（DTSTART 與 RRULE）和 mapping 存的不同，例如改了 FREQ、BYDAY、DTSTART。
   - `removed` 計算：關鍵字排除的事件不算刪除。重複系列只改了結尾（UNTIL／COUNT 提前、行事曆的「這次及以後」拆成新 UID、拿掉 RDATE）時，展開範圍內（slot 的原始時間早於時間窗結尾減一天）已匯入、但來源已沒有的 slot 算來源刪除，走第 9 點的軟刪除；可能落在時間窗之後的 slot 保留。來源給的是某 UID 比已匯入更舊的版本（任一 slot 依 SEQUENCE、同 SEQUENCE 再比 DTSTAMP 判定較舊）時，該 UID 這輪一個 slot 都不刪，記為 skip，之後新版回來照常同步。
   - 大量刪除防護：≥5 筆且超過已匯入數的一半時整輪拒絕，什麼都不寫。cron 永不傳 `allowMassDelete`。系列縮短刪掉的 slot 也算在內。
6. **新事件**（沒有 mapping）：
   - 先 `reserveMappings`，給每個 key 一個 UUIDv7 taskId，狀態 `pending`。
   - 然後用一次（或切塊）push 送出完整的建立 op。
   - push 回應就是讀回結果。
7. **既有 mapping**：
   - 指紋相同且狀態是 `applied`／`cancelled` 時跳過，不讀也不寫。
   - 其他情況先查 snapshot 有沒有這列：
     - **有列**（包括 `pending`／`updating` 狀態，也就是上次回應遺失、其實已建立的任務）：只送 ICS 擁有的欄位。已完成的任務若來源改了就重新開啟；取消事件把標題加 `[已取消] ` 前綴、`status=2`、`completedAt`、`reminders=[]`。垃圾桶裡的任務照常更新，留在垃圾桶裡。
     - **沒有列且狀態是 `pending`**：重送完整的建立 op，沿用保留的 id。
     - **沒有列且狀態不是 `pending`**：保留 mapping、記錯誤、不重建，與 REF 相同。這只會發生在任務被移到使用者看不到的清單時。
   - 寫入前先用 `markUpdating` 存 sequence 與 dtstamp。
   - 以回應的 row 確認之後，才用 `commitMappings` 提交指紋與狀態。
8. **purged 終態**：下列任一情況把 mapping 改成 `purged`，之後不再寫入，也不重建：
   - snapshot 或回應的 row 帶 `purgedAt`。
   - push 回 `Project is purged`。
   - `Forbidden` **不是**終態：它也代表權限被降，保留 mapping，下次可以重試。
9. **來源刪除事件**：任務改成**軟刪除**（`deletedAt=now`），以回應確認後才刪除 mapping。
10. 結尾 `setSourceSync`，狀態為 `success`／`partial`／`error`。`finally` 一定釋放租約。

### 9.4 抓取與安全（`src/ics/fetch.ts`）

- 只接受 `https:`；`webcal:` 換成 `https:`。
- 拒絕下列 host：
  - IP 字面值落在私有、loopback、link-local、CGNAT、`0.0.0.0/8` 範圍。
  - 主機名是 `localhost`、`*.local`、`*.internal`。
- `redirect:'manual'`，最多跟 3 次，每次都重新檢查。
- 逾時 30 秒、上限 8 MiB，照 REF。
- `ICS_ALLOW_INSECURE_HOSTS`（例：`127.0.0.1`）只在開發建置有效，讓 e2e 能從本機 http server 抓 fixture；正式建置一律忽略。
- 來源 URL 只出現在 `list_ics_sources` 的回傳，log 只記 source id。

### 9.5 Cron

- `crons/ics-sync.ts`：`export const cron = "*/5 * * * *"`，handler 先 `await runOAuthCleanup(db, controller.scheduledTime)`（每小時一次，不會 throw，見 4.8），再直接 `await runIcsCron(env)`，**不用 `ctx.waitUntil`**。
  - Void 1.8.0 的 `handleScheduled` 會 await handler，並把失敗彙整成 `AggregateError`。用 `waitUntil` 就會吃掉失敗。
- `runIcsCron`：
  - 用 handler 參數的 `env` 建 db（`createDb(env.DB, {session:'first-primary'})`），用 `Scope.get` 取 DO。
  - 依序同步到期來源，**每輪最多 5 個**，以限制單次執行的 subrequest 數與執行時間。
  - engine 吸收單一來源的錯誤（記在 `lastStatus`），所以 `partial` 不會讓 cron 失敗。只有 run 層級的失敗才 throw，例如 `dueSources` 查詢失敗。
- 先做一個 spike，證明 cron 裡 `createDb`、`Scope.get` RPC、`env` 都能用。D1 方言下 Void 不包 `withRuntimeEnv`。spike 失敗就回頭調整設計，再做 ICS 其他票。

**M2 spike 結果（Void 1.8.0）**：開發建置（`POST /__void/scheduled`，需 `x-void-dev-trigger` token）下，cron handler 的 `env` 拿得到 `JWT_SECRET`，用 `env.DB` 建 `createDb` 能查 D1 的 `user`，`Scope.get('u:…').getInboxProjectId` 的 DO RPC 也成功，`e2e:ics --only cron_runtime` 斷言 `ics.cron.probe {db:ok,scope:ok,env:ok}` 通過。正式建置只做了靜態檢查，沒有實際執行：`vite build` 產物的 `scheduled()` 入口在 `withRuntimeEnv(env, …)` 內呼叫 handler，只過濾 `__VOID_`／`__PROJECT_` 前綴的內部綁定，`DB`、`SCOPE`、secrets 都保留，`Scope.__bind("SCOPE")` 在同一個 worker entry 執行，`worker.config.json` 有 `*/5 * * * *` 的 scheduled trigger。正式環境的實際 cron 觸發要部署後才看得到。

## 10. 環境變數與 secrets

| 名稱 | 類型 | 說明 |
|---|---|---|
| `MCP_HOST` | 預設 `daydo-mcp.audichuang.app` | 主機名閘門 |
| `GOOGLE_WEB_CLIENT_ID` | 預設 `710830841029-i2n5hhd9kgg56r3svnmb0c5g32no5lmv.apps.googleusercontent.com` | 網頁 client id |
| `GOOGLE_WEB_CLIENT_SECRET` | optional，**Worker secret** | 換 code 用；沒設時 Google 按鈕顯示「未設定」 |
| `GOOGLE_AUTH_URL`、`GOOGLE_TOKEN_URL` | 預設官方網址 | e2e 覆寫 |
| `APPLE_WEB_AUDIENCE` | 預設 `com.audichuang.daydo.web` | Services ID |
| `APPLE_AUTH_URL` | 預設官方網址 | e2e 覆寫 |
| `DEFAULT_TIMEZONE` | 預設 `Asia/Taipei` | ICS 浮動時間、時區推斷、重複任務補進度的「今天」 |
| `EMAIL` | Cloudflare Email Service `send_email` binding | 寄驗證碼，寄件人 `DayDo <no-reply@audichuang.app>`；開發建置改用可注入的記憶體 mailer，沒有此 binding 時 start 仍回 202 但不寄信並記 log |
| `ICS_ALLOW_INSECURE_HOSTS` | optional，只在開發建置有效 | e2e 抓本機 fixture |

- `JWT_SECRET` 沿用；MCP 的 access 金鑰與 refresh 金鑰都由它經 HKDF 衍生。
- 正式環境唯一新增的 secret 是 `GOOGLE_WEB_CLIENT_SECRET`；信箱登入只新增 `EMAIL` binding，不是 secret。

**E1 spike 結果（Void 1.8.0，`EMAIL` binding）**：Void 的 `CloudflareConfig` 型別有 `send_email`，`void.config.ts` 的 `cloudflare.send_email: [{ name: 'EMAIL' }]` 會原樣帶進 `vite build` 產物：`dist/ssr/wrangler.json` 有 `send_email`，`.cloudflare/output/v0/workers/default/worker.config.json` 的 `env.EMAIL` 是 `{type: 'send-email'}`；`void prepare` 也自動產生 `.void/bindings.d.ts`，讓 `c.env.EMAIL` 的型別是 `SendEmail`，`env.ts` 不用改。不需要退回 REST API。Void 內建的 `void/email` 的 `sendEmail` 讀的是名為 `SEND_EMAIL` 的 binding，所以不用它，由 `src/mail/mailer.ts` 直接呼叫 `env.EMAIL.send({from, to, subject, text, html})`（寄件人用物件形式 `{name:'DayDo', email:'no-reply@audichuang.app'}`）；`send` 不 throw，失敗只記 `mail.send` 與 Cloudflare 的錯誤代碼（`E_*`），不記主旨與內文。開發建置一律用模組層級的記憶體 mailer（每個收件人留最後一封），Void dev server 是單一 isolate，`npm run e2e` 驗證了一個請求寄出的信，下一個請求能從 `GET /test/mail?to=` 讀到。正式建置不含 `/test/mail`。實際寄送沒有測過：寄給任意收件人需要 Workers Paid，且寄件網域 `audichuang.app` 要先完成 Email Sending 的設定（SPF／DKIM），這是部署前的前置作業。另外 dev server 與 `vite build` 會依設定改寫 `void.lock.json` 的 `send_email`，部署時一起 commit。

## 11. 測試策略

- **單元測試**（vitest，`tests/`）：
  - 領域移植的向量。
  - OAuth：
    - PKCE 向量、DCR 與 `/authorize` 依 IP 限速（IPv6 依 /64）、redirect 精確比對、`resource` 驗證。
    - 過期列清理只刪超過保留期的列、每次有上限、只在整點那一輪執行、失敗不 throw。
    - code 只能用一次。
    - `client_id` 必填並比對。
    - refresh 輪替、寬限期回同一個後繼、並發兩個請求拿到同一個後繼、後繼已用後重用會撤銷 family。
    - token 雙向隔離。
  - authorize：
    - 用假 JWKS 簽的 Apple／Google token。
    - 未知身分不建帳號。
    - provider 回 `error` 時不消耗 pending。
    - **持 cookie 的瀏覽器與完成登入的瀏覽器不同時，callback 必須失敗。**
    - consent GET／POST 也要比對 cookie。
  - MCP 傳輸：照搬 REF `mcp.test.ts`。
  - 工具：用真的 `ScopeObject` 搭配 `createTestD1`，驗證：
    - 寫入後另一台裝置 pull 看得到。
    - LWW 輸掉時回 `isError` 並列出欄位。
    - viewer 清單寫入被拒。
  - ICS：
    - 照搬 REF 的 `parser`、`filters`、`identity` 測試。
    - store 用 node:sqlite。
    - engine 依 REF 的情境清單改寫，加上：回應遺失後使用者修改不被蓋掉、tombstone 變 purged、viewer 降級整輪不寫。
- **e2e**（加進 `npm run check`）：
  - `e2e:mcp`：
    - 主流程：register → authorize（Apple form_post 假身分）→ 同意 → token → initialize → tools/list → `create_task` → 第二台裝置用 App token `/sync/pull` 看到任務。
    - 另含：refresh、主機名閘門雙向 404、token 隔離、Google 路徑（假 token endpoint）、未知身分不建帳號、cookie 不符會失敗。
  - `e2e:ics`：
    - cron runtime 探測。
    - 本機 http server 提供 ICS fixture → `add_ics_source` → `sync_ics_now` → 第二台裝置 pull 看到任務。
    - 改 fixture 後用 `/__void/scheduled` 觸發 cron → 任務更新。
    - 刪除事件 → 任務進垃圾桶。

## 12. 加進 `spec/sync.md`「已知限制」

- refresh 寬限期內，後繼已被使用之後，另一個 client 又拿舊 token 來換，會讓整個 family 被撤銷，需要重新授權（需要異常的 client）。
- 沒用到的 DCR client 不清理（分不出沒用過與很久前用過）；過期的 pending、code、refresh 列由每小時的清理刪除（4.8）。`opApplied` 會隨 ICS 長期增長（家庭用量下可以接受）。
- DCR 與 `/authorize` 依 IP 限速（IPv6 依 /64），攻擊者換很多 IP 或很多 /64 仍可灌入 client 與 pending 列（只會讓表變大，不影響已連線的使用者；pending 一天後會被清掉）。`/token` 沒有限速：code 是 256-bit 隨機值。
- refresh 列在到期 30 天後刪除，之後再送那個舊 token 只會得到 `Unknown refresh token`，不會撤銷 family。
- MCP 與 ICS 寫入要等 App 下次 pull 才看得到（沒有推播）。
- 重複任務的副本與原任務若落在不同範圍（共享清單），兩邊的更新不是原子的，與 App 相同。
- 在同一份來源中重新定義重複系列（改 FREQ、BYDAY、DTSTART，或單一事件改成重複）時，ICS 不寫入該 UID，每輪記一次錯誤，需要人工處理；同一來源的其他事件照常同步。只改結尾時刪掉的 slot 會移到垃圾桶。
- ICS 任務被移到使用者看不到的清單時，該 mapping 每輪記一次錯誤，不重建。
- ICS 的 `CATEGORIES` 不轉成標籤。
- iOS App 還沒有信箱登入畫面；信箱驗證碼只能經 API 與 MCP 授權頁使用，且同信箱不會與 Google／Apple 帳號合併。
- 知道某人信箱的人可以故意用完他每小時的寄碼額度，或猜錯 10 次觸發 24 小時鎖定（阻斷服務，不會登入他的帳號）。

## 13. 合併後手動步驟（不在票內）

部署前的手動設定與部署後的驗收見 `server/README.md`「MCP Server」，只維護那一份。

## 14. 決策紀錄

| 決策 | 理由 |
|---|---|
| MCP 掛在主機根目錄 `/` | 與 REF 相同，三家 client 已實測 |
| D1 條件式寫入存 OAuth 狀態，不用 KV | 強一致，能原子消耗 code |
| MCP 金鑰由 `JWT_SECRET` 經 HKDF 衍生，加上 `aud`／`typ` | 與 App token 互不相通，又不用多管一個 secret |
| refresh 後繼由 HMAC(舊 token) 確定性產生 | 並發與回應遺失時拿到同一個後繼；D1 不存可還原的 token；不需要 AES-GCM |
| 綁定 cookie 用 `SameSite=None`，兩個 callback 與同意頁都比對 | 擋住授權注入；一步完成，不必多一個中繼頁 |
| DCR 依 IP 限速 | 全域上限會讓任何人封鎖新的連線 |
| 不加繞過登入的開發路由 | e2e 用假 JWKS 走正式路徑 |
| 未知身分不建帳號、無資料帳號不寫入 | 避免與 App 第一次登入的流程衝突 |
| snapshot 保留原始列，可見性在工具層過濾 | ICS 要更新垃圾桶裡的任務；`complete_task` 要偵測 tombstone |
| LWW 輸了不重送，直接回報 | 只有讀寫之間剛好有裝置推送才會發生；回報即可 |
| `delete_task` 與 ICS 移除事件用軟刪除 | 可從垃圾桶還原，也不會留下不能再用的 tombstone id |
| 重複任務完成照 App 移植 | 只設 `status=2` 會讓整個系列停掉，等於資料遺失 |
| ICS 標題不加時間前綴，categories 不轉標籤，時區預設 `Asia/Taipei` 可依來源覆寫 | DayDo 列表本來就顯示時間；避免灌爆標籤；家人都在台灣 |
| ICS 任務 id 用 UUIDv7，送出前先保留在 mapping；有列時只寫 ICS 擁有的欄位 | 重啟或回應遺失後仍然冪等，也不會蓋掉使用者的編輯 |
| opId 每次嘗試都是新的 | 重用 opId 只會拿回舊結果 |
| cron 直接 await，每輪 5 個來源，mapping 批次寫入 | 失敗能進 Void 的彙整；限制 subrequest 數與執行時間 |

## 15. 取捨：審查意見逐條判定

1. **授權注入（callback 不檢查 cookie）：採納。** 改成 `SameSite=None; Secure` 綁定 cookie，在兩個 callback、同意頁 GET、同意 POST 都比對；callback 比對失敗時終結 pending。
   - 沒選「Apple callback 303 到同站 complete 頁」的做法：若 complete 頁只靠 state 與 cookie，攻擊者能用自己的 cookie 打開 complete 頁，把受害者的身分綁上去，必須再加一次性 token，比較複雜。
   - 加了「兩個瀏覽器」的失敗測試。
2. **snapshot 過濾與 ICS／complete_task 矛盾：採納，但部分否決。** 已查證：tombstone 保留原本的 `projectId`（`merge.ts` delete 分支複製既有列），所以清單可見時 pull 會帶回 tombstone；DO pull 依可見清單過濾（`scope.ts:1495-1512`）。snapshot 改成保留原始列，過濾移到工具層。
   - 終態只認 `purgedAt` 與 `Project is purged`。
   - **否決「Forbidden 當成 purged」**：`Forbidden` 也代表 viewer 降級或被移出（`scope.ts:909-958`），那種情況必須保留 mapping、可以重試。
   - 「`projectId=''` 加非 scope owner」那條分支只在對不存在的列送 delete 時才會出現。ICS 保留的 id 一律綁推送者自己的 scope `u:<userId>`，推送者就是 scope owner，所以碰不到這條分支，不另外處理。
3. **回應遺失後重送完整建立 op 會蓋掉使用者編輯：採納。** 已對照 REF `engine.ts:186-237`：pending mapping 先找任務，找到就走更新路徑。設計 9.3 第 7 步改成「snapshot 有列就只寫 ICS 擁有的欄位」。
4. **DCR 全域上限可被用來封鎖：採納。** 改成依 `CF-Connecting-IP` 雜湊，每小時 10 筆。換 IP 灌表的情況列入已知限制。
5. **cron 的 `ctx.waitUntil` 吃掉失敗：採納。** 已查證 `wrapper-CVMZarxf.mjs:577-592` 會 await handler 並以 `AggregateError` 回報。改成直接 await，只有 run 層級的失敗才 throw；單一來源的 `partial` 不算失敗。
6. **refresh 寬限期的描述與 session.ts 不符：採納描述的更正，保留「回同一個後繼」的語意。** 已查證 `session.ts:284-364` 在寬限重試時發新的後繼，並撤銷舊後繼。照抄的話，並發的兩個 MCP client 請求中，拿到舊後繼的一方下次使用就會撤銷整條 chain，這正是 REF 想避免的情況。
   - 所以明寫這是**刻意偏離** App 語意。
   - 改用 HMAC(舊 token) 確定性產生後繼，取代原本的 AES-GCM `successorSealed`：不存密文、不用加密 key。並發時條件式 UPDATE 輸掉的一方改走寬限路徑，拿到同一個值。
7. **清單 sortKey 隨機後綴不能以 `0` 結尾：採納。** 已照 `SortKey.swift` 推演，`between("i","i0")="i0i"`。產生鍵時最後一碼排除 `0`，並加測試向量。這只是產生規則，不拿來驗既有列（App 自己不會產生以 `0` 結尾的鍵）。
8. **cron 每輪 20 個來源可能超出 subrequest／CPU 上限：採納。** 改成每輪 5 個，mapping 寫入批次化，並把確認 Workers 方案列入合併後手動步驟與風險。上限數字本身未查證。
9. **LWW 輸了重送一次是多餘的複雜度：採納。** 改成只比對回應的 row，回 `isError` 並列出未套用的欄位。
10. **pull 回應沒有 meMemberId：採納。** 已查證 `pull.ts:25-29`。snapshot 另外查 D1 `user.meMemberId`。
11. **viewer 的處理：採納。**
    - 清單輸出 `role`、`can_write`。
    - ICS 第 4 步在來源清單不可寫時整輪記一次錯誤就停。
    - 寫入工具票與 ICS engine 票都加 viewer 測試。
12. **參數驗證缺口：採納，有一處調整。**
    - (1) `resource` 用 `new URL(resource).origin === origin` 比對，沿用 REF `canonicalResource` 的實測行為，不做嚴格字串比對。
    - (2) `/token` 的 `client_id` 改成必填。這偏離 REF 已實測的行為，所以列入風險，部署後要用三家 client 驗證。
    - (3) provider 回 `error` 時顯示錯誤頁，不消耗 pending。
13. **票太大：採納。** M6、M7、M9、M11、M15 各拆成兩張，每張都有自己的 vitest 檔。
14. **categories 灌進標籤：採納。** 預設不轉成標籤。這偏離「engine 語意照 REF」，但只影響建立時的欄位對應，同步語意不變。是否要開放成選項，列入使用者決策。
