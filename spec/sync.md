# 同步協議（第二階段）

目標：每台裝置離線也能寫入，連上網後所有裝置最終看到同一份資料（最終一致）。

使用者已決定（2026-11-15）：

- 登入：Sign in with Apple、Google。
- 衝突：同一欄位以「修改時間」決定，後改的贏。

以下其餘內容都是提案，尚未確認：

- 時間用 HLC，不直接用手機時鐘。
- 架構：Cloudflare Worker + D1（存資料）+ 一個 Durable Object（寫入依序處理、WebSocket 通知），程式在 `server/`，用 Void（Cloudflare 的框架，底層是 Hono）。目前固定 void 1.8.0：npm 設定只裝發布滿 3 天的版本。不用 KV 存任務資料或 op 去重：KV 是最終一致，剛寫入的值可能讀不到，同一個 op 會被套用兩次。

## 流程

```
裝置寫入 ──► 本機 SQLite + change(opId, hlc)  ← 同一個 transaction
         ──► push 未送達的 op ──► Worker 轉給寫入 DO：依 opId 去重，逐欄位 LWW
                                   合併進 D1，每個被改到的資料列各拿一個新 server_seq
         ◄── 每個 op 的結果（applied / rejected）＋合併後的整列
其他裝置 ◄── DO 用 WebSocket 通知「有新資料」
         ──► pull since=<游標> ──► 回傳 server_seq > 游標、且使用者看得到的資料列
```

送出時機：每次寫入後（延遲約 1 秒，把連續的寫入合成一批）、回到前景、網路恢復、開 App。不比對兩邊的 ID 清單：重送所有未收到 ack 的 op，伺服器靠 opId 去重。

## 線上格式（App 與 Worker 共用，兩邊各自實作前先以這裡為準）

- **entity 名稱**與 App 的資料表同名：`member`、`folder`、`project`、`projectMember`、`task`、`checklistItem`、`tag`、`attachment`、`comment`。
- **entityId**：一般是該列的 `id`（UUIDv7，**小寫** hex，`ID.make()` 產生）。`projectMember` 是 `"<projectId>:<memberId>"`；`tag` 是標籤的 `name`。
- **欄位名**用 App Record 的 Swift 屬性名（camelCase，例如 `startDay`、`deletedAt`），JSON 與 D1 欄位都用同一個名字，不轉 snake_case。
- **`row`** 是 App `JSONEncoder`（`sortedKeys`）編出的整列。值為 nil 的 optional 欄位**不會出現在 `row` 裡**；所以「欄位在 `fields` 裡、卻不在 `row` 裡」代表把它設成 null。
- **型別**：時間戳是 epoch ms 整數；`Bool` 在 JSON 是 `true`/`false`，D1 存 0/1，pull 回傳時轉回 `true`/`false`；`[String]`（`reminders`、`tags`）整個陣列視為一個值，D1 存 JSON 字串。
- **`op`**：`upsert` 或 `delete`（硬刪除，`fields` 為空、`row` 為 `{}`）。
- **合併的欄位群組**：task 的 `startDay`、`startMinute`、`endDay`、`endMinute`、`timeZone` 是同一個時間設定，合併時視為一組，共用 `clocks["schedule"]`：只要 `fields` 含其中任何一個，就整組一起比 HLC、一起寫入（缺的欄位依上一條視為 null）。否則一台改日期、另一台改時區，合併後會變成兩邊都沒設定過的時間。
- **不同步的欄位**：`member.isMe`（每台裝置、每個使用者各自不同；Worker 不存，回傳時依請求的使用者算出來：使用者第一個帶 `isMe: true` 推上來的 member 綁定為他自己）、`attachment.localPath` 與 `attachment.originalPath`（裝置上的檔案路徑；附件檔案上傳之後再設計）。App 套用伺服器資料列時，這些欄位**一律保留本機的值**，不套用「欄位不出現＝null」的規則；`isMe` 在第一次登入的 id 對應完成前也不能拿伺服器的值蓋掉。
- **tombstone**：伺服器回傳的資料列可能帶 `purgedAt`（硬刪除的時間）。App 收到帶 `purgedAt` 的列，要在本機硬刪除這一列（子列由外鍵連帶刪除），不寫 outbox，也不能把它當一般資料列存回去。對已硬刪除的 id 再送 upsert，伺服器回 `applied`，但不會套用，回傳的仍是 tombstone。
- **push 回應與 pull 的資料列格式**：每筆是並列的 `row` 與 `clocks`（不是把 `clocks` 放進 `row` 裡）。`row` 只含上面的同步欄位，加上 `purgedAt`（只有 tombstone 才有）和 member 的 `isMe`。
- **HLC 字串**：`<13 位數 epoch ms，前面補 0>:<4 位數計數，前面補 0>:<deviceId 小寫>`。計數到 9999 時，ms 加 1、計數歸 0。
- **fixture**：App 端測試會產出一份真實編碼的 op 範例 `spec/fixtures/sync-ops.json`，Worker 端的測試直接讀這份檔案。格式有爭議時，以這份檔案和本節為準。

## App 端

新增 migration `v3`（不改 `v1`、`v2`；`v2` 是 main 的 `projectInvite`）：

- `change` 加 `opId`（UUIDv7）、`hlc`、`ackedAt`（null 表示還沒送達）、`result`。
- `meta` 存 `deviceId`、`hlc`（上次用過的時鐘）、`pullCursor`、登入狀態。token 不放 `meta`，存 Keychain。
- 舊的 `change` 列（`v1` 起從未清除）在 migration 裡補上 `opId` 與 `hlc`（用 `at` 換算），第一次登入時就能把既有資料整份重播上傳。

送出與 ack：

- 依 `seq` 順序送，每批最多 200 筆。
- `applied`（含伺服器之前已套用過的重複 op）與 `rejected` 都寫 `ackedAt`，之後不再送。兩種結果都附上伺服器合併後的整列和 `clocks`（rejected 時，伺服器上若還沒有這一列，就沒有東西可附），照下面「套用伺服器資料列」的規則寫回本機。這一步不能省：本機的 op 如果在某個欄位輸給別台較新的修改，伺服器會丟掉這個欄位但仍回 `applied`；本機若只標記已送達，就會一直留著伺服器沒有的值，而那一列的 `server_seq` 不會再變，之後 pull 也拉不到它。
- HTTP 429 或 5xx：整批稍後重送，間隔以指數倍增，最長 5 分鐘。401：先刷新 token 再送。
- 寫入逾時或沒收到回應時，不知道伺服器有沒有套用：直接重送同一批即可，opId 去重保證只套用一次。

拉取與套用：

- 套用順序：pull 依 `serverSeq` 排序，子列可能比父列先到，跨頁也一樣；App 的外鍵是立即檢查的。所以同一頁的資料列在**同一個 transaction** 裡套用，並開 `PRAGMA defer_foreign_keys = ON`；commit 時父列仍不存在的子列，先放進暫存區，等之後的頁或下一次 pull 拿到父列再套用。
- 套用伺服器資料列（pull 與 push 回應都適用）：資料列帶 `clocks`。對每個欄位，只有本機有未送達的 op 改了這個欄位、而且它的 HLC 比 `clocks[欄位]` 新時，才保留本機的值；其他情況一律用伺服器的值。
- 套用遠端資料不寫 `change`（不然會被當成本機修改再送回去）。

## HLC（混合邏輯時鐘）

格式：`<13 位 epoch ms>:<4 位計數>:<deviceId>`，固定長度，可以直接用字串比大小。

- 本機產生：`ms = max(現在時間, 上次的 ms)`；ms 沒變就計數加 1，否則計數歸 0。
- 收到伺服器的 HLC：如果比本機新，本機時鐘推進到那個值。這樣手機時鐘慢了，也不會一直輸給別台。
- 計數相同時，比 deviceId 決定勝負，結果固定。
- 伺服器端上限：op 的 HLC 比伺服器時間快 5 分鐘以上，就改用伺服器目前時間的 HLC。否則一台時鐘設錯（設到未來）的裝置，每次衝突都會贏。

## 合併規則（Worker）

每個資料列存 `clocks`（JSON：欄位名 → 最後寫入它的 HLC）。

- `upsert`：只處理 op 的 `fields` 裡列出的欄位，不用 `row` 整列覆蓋。對每個欄位，op 的 HLC 比 `clocks[欄位]` 新才寫入。資料列還不存在就整列建立。
- 軟刪除與還原：`deletedAt` 就是一般欄位，照 LWW 處理。
- 硬刪除（`op = delete`，目前只有 `purgeTask`）：留下 tombstone（`purgedAt`），不再接受這一列之後的 upsert，回 `applied`（不回 `rejected`，避免另一台裝置一直重送）。伺服器負責把它的 checklist、附件、留言一起刪除，因為 App 端這些連帶刪除不會寫進 outbox。
- 標籤以名稱當主鍵，兩台裝置建立同名標籤時會合併成同一列，這是預期的行為。
- 一台裝置編輯、另一台同時軟刪除：兩邊都會保留，結果是「已刪除但內容是新的」，從垃圾桶還原就看得到最新內容。

## 要先處理的 App 端問題

1. **每台裝置各自建立的初始資料**：`bootstrap` 會建「我」、收件匣、預設清單，id 都是隨機的。登入時：
   - 帳號在伺服器上還沒有資料：整份上傳，這台裝置的 id 就成為正式 id。
   - 帳號已經有資料：把本機「我」的 member id 和收件匣 id 換成伺服器上的，任務一併改指過去；從未修改、也沒有任務的預設清單直接丟掉；其他資料照常上傳。這一步在上傳前完成，並改寫本機尚未送出的 `change`。
2. **重複任務完成時建立的副本**：副本 id 改成用 `taskId + 該次的開始時間` 推出來的 UUIDv5，兩台裝置離線時都按完成，只會留下同一筆。
3. **`completeTask` 的 `ifUpdatedAt`** 只在本機有效，伺服器不另外檢查；兩台裝置都完成同一次重複任務時，靠第 2 點去重。

## 登入

- **Apple**：App 用 `ASAuthorizationAppleIDProvider` 取得 `identityToken`（帶 nonce）。Worker 用 Apple JWKS 驗證：`iss = https://appleid.apple.com`、`aud = com.audichuang.daydo`、nonce 雜湊相符。
- **Google**：App 用 GoogleSignIn SDK 取得 `idToken`。Worker 用 Google JWKS 驗證：`iss` 是 `accounts.google.com` 或 `https://accounts.google.com`，`aud` 等於 iOS OAuth client id。
- 帳號用 `(provider, sub)` 識別，不用 email 自動合併帳號：Apple 可能給隱藏的轉寄 email。要讓兩種登入方式共用同一個帳號，登入後在設定裡手動連結。
- Worker 自己發 token：access token 為 JWT，1 小時；refresh token 90 天，每次使用就換一組新的，D1 只存雜湊值。
- App Store 規定：可以建立帳號的 App 必須能在 App 裡刪除帳號。刪除時要一併撤銷 Apple 的授權（需要 authorization code 和 client secret）。

## Endpoint（之後併入 `openapi.yaml`）

| Method | Path | 說明 |
|---|---|---|
| POST | `/auth/apple` | `{identityToken, nonce, deviceId}` → `{accessToken, refreshToken, user, isNewAccount}` |
| POST | `/auth/google` | `{idToken, deviceId}` → 同上 |
| POST | `/auth/refresh` | `{refreshToken}` → 新的一組 token |
| POST | `/auth/link` | 已登入時連結另一種登入方式 |
| DELETE | `/account` | 刪除帳號與所有資料 |
| POST | `/sync/push` | `{deviceId, ops: [{opId, hlc, entity, entityId, op, fields, row}]}` → `{results: [{opId, status, reason?}], serverSeq}` |
| POST | `/sync/push` 回應的 results | 每筆另含並列的 `row`（合併後的整列）與 `clocks` |
| GET | `/sync/pull?since=<seq>&limit=500` | → `{rows: [{entity, row, clocks, serverSeq}], cursor, hasMore}` |
| GET | `/sync/ws` | WebSocket，只推送「有新資料」通知，資料一律用 pull 取得 |

## D1 schema 草稿

- `user`、`identity(provider, sub, user_id)`、`session(refresh_hash, user_id, device_id, expires_at)`、`device`。
- `op_applied(op_id PRIMARY KEY, user_id, status, server_seq)`：去重用，保留 90 天。
- 資料表和 App 端相同，另加 `clocks`、`server_seq`（建索引）、`purged_at`。
- 能看到哪些列：自己的資料，加上自己在 `projectMember` 裡的共享清單。
- `server_seq` 是全域遞增的數字，每寫一個資料列就加 1。游標就是上次拉到的最後一列的 seq，`limit` 怎麼切都不會漏列。
- 合併要先讀 `clocks`、比較、再寫入。D1 從 Worker 呼叫時沒有互動式 transaction（只有 `batch()` 是原子的），兩個 push 同時改同一列可能交錯，較新的值被較舊的蓋掉。所以所有 push 都交給同一個寫入 DO 依序處理；它負責讀 `clocks`、決定結果、一次 `batch()` 寫入。家人規模的流量用一個 DO 就夠，也不用處理「共享清單跨使用者」要歸哪個 DO 的問題。同一個 DO 也負責 WebSocket 通知（用 hibernation）。DO 呼叫 D1 時要等網路回應，等待期間 DO 仍會接下一個請求（input gate 只擋 DO 自己的 storage 操作），所以 DO 裡要自己用一個佇列，一次只處理一批 push。2026-11-15 在本機（void 1.8.0、workerd）實測證實：沒有佇列時，20 個同時送出的讀改寫全部讀到同一個舊值；加上 promise-chain 佇列後才依序執行。`server/scripts/e2e-sync.mjs` 的 concurrency 情境在 `WRITER_QUEUE=off`（只在開發建置有效）時必須失敗，用來證明測試抓得到競態。
- 被加入共享清單時，那份清單的舊資料 `server_seq` 比游標小，pull 拉不到。App 收到自己的 `projectMember` 列後，對那份清單另外跑一次 `pull?project=<id>&since=0`。

## 實作順序

1. App：migration `v3`、HLC、op 序列化（都不需要網路，可以先寫單元測試）。
2. Worker：登入、`/sync/push`、`/sync/pull`、D1 schema，用 Miniflare 測合併規則。
3. App：登入畫面、SyncEngine（送出、拉取、重送時機）、第一次登入的 id 對應。
4. DO WebSocket 通知、共享清單、成員指派。
5. MCP 掛上 Worker。
