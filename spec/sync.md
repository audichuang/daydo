# 同步協議（第二階段）

目標：每台裝置離線也能寫入，連上網後所有裝置最終看到同一份資料（最終一致）。

## 已定的決策（2026-11-15，使用者確認）

| 主題 | 決定 |
|---|---|
| 登入 | Sign in with Apple＋Google，**必須登入才能使用** App。Google iOS client：`710830841029-g836eiphrs51fm45f9fgtleg95foohv0.apps.googleusercontent.com`（Google Cloud 專案 `daydo-514804`，測試模式，測試使用者要加進名單）。 |
| 衝突 | 同一欄位以修改時間決定，後改的贏；時間用 HLC。**伺服器合併後的資料列是唯一正確答案**，App 一律照它覆蓋（只保留本機未送出且較新的欄位）。 |
| 時鐘 | 伺服器把快 5 分鐘以上的 HLC 校正成伺服器時間；push 回應帶 `serverTime`，App 用它推進自己的 HLC，同一台裝置的修改不會被自己蓋掉。 |
| 多人架構 | 以服務多人為前提：每個使用者一個 Durable Object（**範圍**），存在 DO 自帶的 SQLite。每筆資料永遠住在**建立它的人**的範圍（子項目、附件、留言住在所屬任務的範圍），「在哪份清單」只是資料上的欄位：移進別人建立的共享清單也只是改欄位，資料不搬家。共享、轉移擁有者只改 D1 的權限。看一份共享清單時，從每個存有它資料的範圍各拿一部分。pull 每個範圍各一個游標。（原本寫「每份共享清單一個 DO」，後來改成「清單住在建立者範圍」，兩者都會在移動任務時跨 DO 搬資料、中間有空檔，2026-11-15 使用者同意改成資料不搬家。） |
| 對外網址 | `https://daydo-api.audichuang.app`，前面加 Cloudflare Access：App 每個請求都帶 service token 的 `CF-Access-Client-Id`／`CF-Access-Client-Secret`；Worker 驗 `Cf-Access-Jwt-Assertion`；關掉 `workers.dev` 與 preview 網址。token 編在 App 裡、拆得出來，只擋亂打的流量，真正的保護是帳號登入。設定照既有的 `OkiBus API (iOS app only)` Access 應用程式，用 `cf` CLI 操作。 |
| 第一次登入 | 登入回應帶：帳號有沒有資料、伺服器上的「我」與收件匣 id。新裝置（平板、重新安裝）：不建預設資料，直接把全部資料拉下來；帳號沒資料才建預設資料並上傳。已在用的舊版手機（本機有資料）：帳號沒資料就整份上傳；帳號有資料就把本機「我」與收件匣換成伺服器的 id、丟掉沒動過且沒任務的預設清單，其他照常上傳。id 對應要在第一次 push 前、同一個交易裡完成，**連尚未送出的 outbox 一起改**：`row` 裡的引用與 `entityId`（含 projectMember 的複合鍵）；被丟掉的預設清單，它們的建立 op 一併刪掉。 |
| 永久刪除與副本 id | App 用 `purgedId` 記住永久刪除過的 id（含套用伺服器 tombstone 時），重複任務副本的確定性 id 已被刪過就改用隨機 id。 |
| push 批次 | App 每批 50 個 op；伺服器上限維持 200，部署後實測再調。 |
| 共享清單 | 用邀請連結：擁有者產生連結、用訊息傳給對方，對方登入後加入。`projectInvite.email` 只用來顯示「邀請了誰」。 |
| 驗收 | 「兩台裝置收斂」的 API 模擬測試：Swift 測試裡兩個各自有資料庫的 App 核心，用本機 JWKS 簽的假 token 登入本機 Worker，交錯修改、刪除、離線重送後，兩邊與伺服器完全一致。 |
| 之後 | iPad 原生版面、macOS 版（方向已定，這一階段不做）。 |

框架：程式在 `server/`，用 Void（Cloudflare 的框架，底層 Hono），固定 void 1.8.0（npm 設定只裝發布滿 3 天的版本）。不用 KV 存任務資料或 op 去重：KV 是最終一致，剛寫入的值可能讀不到。

## 流程

```
裝置寫入 ──► 本機 SQLite + change(opId, hlc, projectId)  ← 同一個 transaction
         ──► POST /sync/push（未送達的 op，每批 50）
             Worker：驗 Access、驗 token，依 op 的 projectId 查 D1 找到它所在的範圍，
                     檢查權限，把 op 依範圍分組（保持原順序）交給各範圍 DO
             範圍 DO：transactionSync 裡依 opId 去重、逐欄位 LWW 合併、
                     每個改到的資料列拿一個新的 serverSeq（每個範圍各自遞增）
         ◄── 每個 op 的結果（applied / rejected）＋合併後的整列＋serverTime
其他裝置 ◄── 範圍 DO 用 WebSocket 通知「這個範圍有新資料」（之後做）
         ──► POST /sync/pull（每個範圍一個游標）──► 回傳各範圍 serverSeq > 游標、且使用者看得到的資料列
```

送出時機：每次寫入後（延遲約 1 秒，把連續的寫入合成一批）、回到前景、網路恢復、開 App。不比對兩邊的 ID 清單：重送所有未收到 ack 的 op，伺服器靠 opId 去重。

## 範圍（scope）與權限

- **範圍**：id 是 `u:<userId>`，一個使用者一個 DO 實例。寫入都在 `transactionSync` 裡做；DO 的 SQLite 是同步呼叫，天然一次只處理一個請求，不需要自己排隊（2026-11-15 在 void 1.8.0 本機實測：20 個同時呼叫依序得到 1 到 20、交易失敗會回滾、兩個 DO 互不影響、dev server 重開資料還在）。
- **資料永遠不搬家**：每筆資料住在建立它的人的範圍；checklistItem、附件、留言住在所屬任務的範圍（不論是誰加的）。D1 的 `entityHome(entity, entityId → scope)` 在第一次建立時寫入、之後不變：Worker 用一個 `batch()` 做 `INSERT … ON CONFLICT DO NOTHING` 再讀回綁定的範圍，讀回的不是自己要寫的範圍就是被別人先佔了（每次新建多一次 D1 寫入，這個規模可以接受），Worker 找路只看它；新建時：任務、清單等住推送者的範圍，子列住其任務的範圍。已綁定到別的範圍的 id 再送新建，回 `rejected`，原因 `id-in-other-scope`。標籤不做全域綁定：每個人的標籤以 `(推送者範圍, name)` 為鍵，住推送者自己的範圍，彼此同名也不衝突。
- **「在哪份清單」只是欄位**：task 的 `projectId` 可以指向任何清單，包括別人建立的共享清單；子列跟著它的任務。移動任務＝在任務的範圍裡改 `projectId`，DO 在**同一個交易**裡把它的子列清單標記一起改掉、全部給新的 serverSeq，並為離開的清單寫離開紀錄。沒有跨 DO 的兩步驟，所以沒有中間空檔。
- **哪些範圍存有某份清單的資料**：D1 的 `listScopes(projectId, scope)`。**寫入前先登記**：op 會讓資料列進入某份清單（新建、移動）時，Worker 先在 D1 用一個 `batch()`（D1 在 Worker 裡只有 batch 是原子的，沒有互動式交易）執行「清單沒有被永久刪除才寫入 `listScopes`」的條件式 INSERT，加上讀回這份清單是否已永久刪除，才交給 DO；已永久刪除就回 `rejected`。目的清單從 op 的 `row.projectId` 得知（新建與移動的 op 一定帶它）；子列不登記，跟著任務。看一份共享清單時，從這些範圍各拿屬於它的列。
- **權限只看 D1 的成員資格**：`projectMembership(projectId, userId, role)` 是唯一來源，建立者也一樣。清單第一次被推上來時，Worker 在 D1 寫入建立者的 owner 成員資格（重送不重複）。每份清單只有一個 owner。

  | 角色 | 讀 | 寫任務與子項目、清單的顯示欄位 | 刪除／封存清單、成員與邀請、轉移 |
  |---|---|---|---|
  | owner | ✓ | ✓ | ✓ |
  | editor | ✓ | ✓ | ✗ |
  | viewer | ✓ | ✗ | ✗ |

  member、folder、tag 只屬於自己，只能寫自己範圍裡的。

- **讀取一律依成員資格過濾，連自己的範圍也一樣**：editor 可以把我建立的任務移到他的私人清單，所以我的範圍裡可能有我看不到的列。pull、push 回應、登入回應都只回推送者是成員的清單裡的列；member、folder、tag 只回給它們的建立者。
- **檢查一律在 server、以資料列目前的狀態為準**：Worker 把推送者的成員資格交給 DO；DO 以**資料列目前所在的清單**判斷（子列看所屬任務目前的清單），不信 op 自報的 `projectId`。改了 `projectId` 的 op（移動）要同時有原清單和目的清單的寫入權，檢查不過整筆 `rejected`。同一筆資料同時被改時，照 server 收到的順序、逐欄位 HLC 決定，結果以 server 為準。
- **子列的 `taskId` 不能改**：checklistItem、附件、留言建立後不能改掛到別的任務，改 `taskId` 的 op 回 `rejected`（附目前的列）。
- **新建與未知的列**：DO 找不到這一列時，只有 `fields` 涵蓋該 entity 所有必填欄位的 upsert 才算新建；只改部分欄位卻找不到列，回 `rejected`，原因 `unknown-row`，不會憑空建出一筆。
- **離開紀錄（gone）**：DO 另存 `departure(entity, entityId, projectId, serverSeq)`：資料列離開某份清單（移動、清單被永久刪除）時寫一筆。pull 時，只對**現在已經看不到這一列**的使用者（是原清單成員、但不是資料列目前所在清單的成員）回 `{entity, entityId, gone: true, serverSeq}`；仍看得到的人會在同一範圍拿到移動後的列（serverSeq 較新），本機未送出的修改照常保留。App 收到 gone 就在本機硬刪除這一列與它的子列、丟掉它尚未送出的 op（不記 `purgedId`，id 之後還可能回來）。
- **被拒絕時**：推送者仍讀得到這一列 → `rejected` 附目前的 `row` 與 `clocks`，App 照它覆蓋（例如被降成 viewer 後離線改的標題會被還原）；讀不到了 → `rejected` 附 `gone: true`，App 照上一條處理。
- **永久刪除清單**：owner 永久刪除清單時，Worker 用一個 `batch()` 把清單標成已永久刪除並讀出當下的 `listScopes`（之後任何讓資料進入它的寫入都會在登記那步被拒；登記與標記都在 batch 裡，兩者不會交錯出漏網的範圍），再依讀出的範圍通知每個存有它資料的範圍。各範圍 DO 在交易裡記下「這份清單已永久刪除」、把屬於它的任務與子列永久刪除（留 tombstone），之後對這份清單的寫入一律拒絕。通知是冪等的，未完成的記在 D1 由下一次請求或排程重試，全部範圍都確認後才算完成。
- **成員與邀請不走一般同步**：projectMember 與 projectInvite 只能由 owner 透過專用 API 改（見 Endpoint），先寫 D1、再由伺服器投影到清單建立者範圍的 projectMember 列（給 App 顯示）。投影是冪等的；寫完 D1 但投影失敗時，下一次 pull 該清單前 Worker 會比對 D1 與 DO 補齊。App 送來的 projectMember／projectInvite op 一律 `rejected`（附目前的列）。App 端「等待同步」的邀請在登入且連線後改成呼叫建立邀請的 API。
- **共享清單需要的其他資料**：
  - 成員的顯示資料（名字、縮寫、顏色）存在 D1 的 `user`，使用者推送自己的 member 列時 Worker 一併更新 D1。pull 回應的 `members` 帶「與我共享任何一份清單的人」的 member 列（id 是對方的 `meMemberId`），App 照一般資料列套用。
  - `project.folderId` 是個人分類：只有清單建立者能改。pull 別人建立的清單時不帶 `folderId`，App 對別人建立的清單保留本機的 `folderId`，也不送這個欄位。
- **加入或離開共享清單**：加入時 App 用 pull 的 `backfill: [projectId]` 拿那份清單在各範圍的全部資料（不受游標限制）；離開、被移除或清單被刪時，pull 回應的 `memberships` 不再有它，App 刪掉本機那份清單的資料與相關的待送 op。
- **還原任務**：`restoreTask` 原清單已刪除時改回自己的收件匣；任務仍住在原本的範圍，只改 `projectId`，權限照移動的規則檢查。

## 尚未決定

- **刪除帳號**：資料住在建立者的範圍，所以刪除帳號會一起刪掉這個人在共享清單裡建立的任務。要不要改成先轉給清單 owner，做刪除帳號（上架前必須有）之前要決定。

## 線上格式（App 與 Worker 共用，兩邊各自實作前先以這裡為準）

- **entity 名稱**與 App 的資料表同名：`member`、`folder`、`project`、`projectMember`、`task`、`checklistItem`、`tag`、`attachment`、`comment`。
- **entityId**：一般是該列的 `id`（UUIDv7，**小寫** hex，`ID.make()` 產生）。`projectMember` 是 `"<projectId>:<memberId>"`；`tag` 是標籤的 `name`。
- **欄位名**用 App Record 的 Swift 屬性名（camelCase，例如 `startDay`、`deletedAt`），JSON 與伺服器的欄位都用同一個名字，不轉 snake_case。
- **`row`** 是 App `JSONEncoder`（`sortedKeys`）編出的整列。值為 nil 的 optional 欄位**不會出現在 `row` 裡**；所以「欄位在 `fields` 裡、卻不在 `row` 裡」代表把它設成 null。
- **型別**：時間戳是 epoch ms 整數；`Bool` 在 JSON 是 `true`/`false`，伺服器存 0/1，回傳時轉回 `true`/`false`；`[String]`（`reminders`、`tags`）整個陣列視為一個值，伺服器存 JSON 字串。
- **`op`**：`upsert` 或 `delete`（硬刪除，`fields` 為空、`row` 為 `{}`）。
- 找路不需要 op 另外帶清單 id：新建時任務、清單住推送者的範圍，子列住其任務的範圍（查任務的 `entityHome`）；其他時候一律查 `entityHome`。
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

- 依 `seq` 順序送，每批 50 筆（伺服器上限 200）。
- `applied`（含伺服器之前已套用過的重複 op）與 `rejected` 都寫 `ackedAt`，之後不再送。兩種結果都附上伺服器合併後的整列和 `clocks`（rejected 時，伺服器上若還沒有這一列，就沒有東西可附），照下面「套用伺服器資料列」的規則寫回本機。這一步不能省：本機的 op 如果在某個欄位輸給別台較新的修改，伺服器會丟掉這個欄位但仍回 `applied`；本機若只標記已送達，就會一直留著伺服器沒有的值，而那一列的 `server_seq` 不會再變，之後 pull 也拉不到它。
- HTTP 429 或 5xx：整批稍後重送，間隔以指數倍增，最長 5 分鐘。401：先刷新 token 再送。
- 寫入逾時或沒收到回應時，不知道伺服器有沒有套用：直接重送同一批即可，opId 去重保證只套用一次。

拉取與套用：

- 套用順序：pull 依 `serverSeq` 排序，子列可能比父列先到，跨頁也一樣；App 的外鍵是立即檢查的。所以同一頁的資料列在**同一個 transaction** 裡套用，並開 `PRAGMA defer_foreign_keys = ON`；commit 時父列仍不存在的子列，先放進暫存區，等之後的頁或下一次 pull 拿到父列再套用。
- 套用伺服器資料列（pull 與 push 回應都適用）：資料列帶 `clocks`。對每個欄位，只有本機有未送達的 op 改了這個欄位、而且它的 HLC 比 `clocks[欄位]` 新時，才保留本機的值；其他情況一律用伺服器的值。
- 套用遠端資料不寫 `change`（不然會被當成本機修改再送回去）。
- 收到帶 `purgedAt` 的列：本機硬刪除，並記進 `purgedId`；收到 `gone: true`：本機硬刪除，不記 `purgedId`。
- push 回應的 `serverTime` 用來推進本機 HLC（`HLC.receive`）。

## HLC（混合邏輯時鐘）

格式：`<13 位 epoch ms>:<4 位計數>:<deviceId>`，固定長度，可以直接用字串比大小。

- 本機產生：`ms = max(現在時間, 上次的 ms)`；ms 沒變就計數加 1，否則計數歸 0。
- 收到伺服器的 HLC 或 push 回應的 `serverTime`：如果比本機新，本機時鐘推進到那個值。這樣手機時鐘慢了，也不會一直輸給別台；時鐘快的手機被伺服器校正後，下一筆修改也會比上一筆新。
- 計數相同時，比 deviceId 決定勝負，結果固定。
- 伺服器端上限：op 的 HLC 比伺服器時間快 5 分鐘以上，就改用伺服器目前時間的 HLC。否則一台時鐘設錯（設到未來）的裝置，每次衝突都會贏。

## 合併規則（Worker）

每個資料列存 `clocks`（JSON：欄位名 → 最後寫入它的 HLC）。

- `upsert`：只處理 op 的 `fields` 裡列出的欄位，不用 `row` 整列覆蓋。對每個欄位，op 的 HLC 比 `clocks[欄位]` 新才寫入。資料列還不存在就整列建立。
- 軟刪除與還原：`deletedAt` 就是一般欄位，照 LWW 處理。
- 硬刪除（`op = delete`，目前只有 `purgeTask`）：留下 tombstone（`purgedAt`），不再接受這一列之後的 upsert，回 `applied`（不回 `rejected`，避免另一台裝置一直重送）。伺服器負責把它的 checklist、附件、留言一起刪除，因為 App 端這些連帶刪除不會寫進 outbox。
- 標籤以名稱當主鍵，兩台裝置建立同名標籤時會合併成同一列，這是預期的行為。
- 一台裝置編輯、另一台同時軟刪除：兩邊都會保留，結果是「已刪除但內容是新的」，從垃圾桶還原就看得到最新內容。

## App 端其他規則

- **重複任務完成時建立的副本**：副本 id 是 `taskId + 該次的開始時間` 推出來的 UUIDv5，兩台裝置離線時都按完成只留一筆；這個 id 已在 `purgedId` 裡就改用隨機 id。
- **`completeTask` 的 `ifUpdatedAt`** 只在本機有效，伺服器不另外檢查。

## 登入

- **Apple**：App 用 `ASAuthorizationAppleIDProvider` 取得 `identityToken`（帶 nonce）。Worker 用 Apple JWKS 驗證：`iss = https://appleid.apple.com`、`aud = com.audichuang.daydo`、nonce 雜湊相符。
- **Google**：App 用 GoogleSignIn SDK 取得 `idToken`。Worker 用 Google JWKS 驗證：`iss` 是 `accounts.google.com` 或 `https://accounts.google.com`，`aud` 等於 iOS OAuth client id。
- 帳號用 `(provider, sub)` 識別，不用 email 自動合併帳號：Apple 可能給隱藏的轉寄 email。要讓兩種登入方式共用同一個帳號，登入後在設定裡手動連結。
- Worker 自己發 token：access token 為 JWT，1 小時；refresh token 90 天，每次使用就換一組新的，D1 只存雜湊值。
- 登入回應另帶 `hasData`（伺服器上已經有這個使用者的收件匣，等同 `inboxProjectId` 不是 null）、`meMemberId`（綁定的「我」，還沒有就是 null）、`inboxProjectId`（自己範圍裡的收件匣，還沒有就是 null）。App 依「已定的決策」的第一次登入規則處理。
- **Cloudflare Access**：正式環境每個請求都要通過 Access（App 帶 service token），Worker 再驗 `Cf-Access-Jwt-Assertion`（簽章、`aud` 等於 Access 應用程式的 AUD）。本機開發與 e2e 用環境變數關掉這一層，只在開發建置有效。
- App Store 規定：可以建立帳號的 App 必須能在 App 裡刪除帳號。刪除時要一併撤銷 Apple 的授權（需要 authorization code 和 client secret）。

## Endpoint（之後併入 `openapi.yaml`）

| Method | Path | 說明 |
|---|---|---|
| POST | `/auth/apple` | `{identityToken, nonce, deviceId}` → `{accessToken, refreshToken, user, isNewAccount, hasData, meMemberId, inboxProjectId}` |
| POST | `/auth/google` | `{idToken, deviceId}` → 同上 |
| POST | `/auth/refresh` | `{refreshToken}` → 新的一組 token |
| POST | `/auth/link` | 已登入時連結另一種登入方式（之後做） |
| DELETE | `/account` | 刪除帳號與所有資料（之後做，上架前必須有） |
| POST | `/sync/push` | `{deviceId, ops: [{opId, hlc, entity, entityId, op, fields, row}]}`（最多 200）→ `{results: [{opId, status, reason?, row, clocks}], serverTime}`，`results` 與 `ops` 同順序 |
| POST | `/sync/pull` | `{cursors: {"u:<id>": seq}, backfill?: [projectId], limit?}` → `{scopes: [{scope, rows: [{entity, row, clocks, serverSeq} \| {entity, entityId, gone: true, serverSeq}], cursor, hasMore}], memberships: [{projectId, scope, role}], members: [member 列]}`；沒給游標的範圍從 0 開始 |
| POST | `/invites` | `{projectId, role, email?}`（owner 才能建；email 只用來顯示）→ `{code, url: "daydo://invite/<code>", expiresAt}` |
| GET | `/invites/<code>` | → `{projectName, inviterName, role, expiresAt}`（讓 App 顯示「誰邀你加入哪份清單」） |
| POST | `/invites/<code>/accept` | 加入成員，並投影一筆 projectMember → `{projectId, scope, role}`。D1 用一條「邀請存在、未撤銷、未過期才寫入成員資格」的條件式 INSERT，讀回結果；撤銷與接受同時發生時以 D1 執行順序為準 |
| DELETE | `/invites/<code>` | owner 撤銷邀請 |
| PUT | `/projects/<id>/members/<userId>` | owner 改角色 `{role}`（editor／viewer） |
| DELETE | `/projects/<id>/members/<userId>` | owner 移除成員；成員也可以移除自己（離開） |
| POST | `/projects/<id>/transfer` | `{toUserId, expectedOwnerUserId}`：轉移擁有者，`expectedOwnerUserId` 不符回 409；原 owner 變 editor。用一個 `batch()`，每條 UPDATE 都帶「目前 owner 是 expectedOwnerUserId」的條件，讀回影響列數判斷成功 |
| GET | `/sync/ws` | WebSocket，只推送「某範圍有新資料」，資料一律用 pull 取得（之後做） |

邀請碼是 128-bit 隨機值（base64url），D1 只存雜湊；7 天內有效，可以多人使用，owner 可撤銷。邀請碼是核心，`daydo://invite/<code>` 只是外殼：iOS、iPadOS、macOS 原生 App 都能註冊這個 scheme；之後做 Web 時加 `https://…/invite/<code>` 網頁，打同一個 API。

## 儲存

- **D1**：`user`（含 `meMemberId` 與名字、縮寫、顏色）、`identity(provider, sub, userId)`、`session`、`device`、`projectMembership(projectId, userId, role, createdAt, removedAt)`、`invite(codeHash, projectId, role, createdBy, expiresAt, revokedAt)`、`entityHome(entity, entityId, scope)`（tag 除外）、`listScopes(projectId, scope)`、未完成的清單刪除通知。資料表不放 D1。
- **範圍 DO 的 SQLite**：各 entity 一張表（欄位同 App，加 `clocks`、`serverSeq`、`purgedAt`，子列另存所屬清單），`departure`（離開紀錄），`opApplied(opId, status, serverSeq)`，`counter`（範圍內的 serverSeq）。
- 舊的單一寫入 DO（`writer`）與 D1 的資料表在 T5a 移除；從未部署過，不用搬資料。
- 測試要能證明並發被正確處理：e2e 的 concurrency 情境保留；DO SQLite 本身就依序執行，所以改用只在開發建置有效的故障注入（例如在讀 `clocks` 和寫入之間故意 `await`），開啟時該情境必須失敗。

## 實作順序

1. ✓ App：migration `v3`、HLC、op 序列化。✓ `v4` `purgedId`。
2. ✓ Worker 第一版：登入、push、pull（單一寫入 DO＋D1，本機）。
3. T5a Worker：資料改到範圍 DO（單一使用者，先不做共享）：`entityHome`、移動帶子列、「未知的列不憑空建立」、子列 `taskId` 不可改、讀取依成員資格過濾。
4. T5b Worker：`serverTime`、登入回應的 `hasData`／`meMemberId`／`inboxProjectId`、兩台裝置的 e2e。T7 從這裡開始。
5. T5c Worker：成員與邀請 API、權限矩陣、成員投影、`listScopes` 與多範圍 pull、`gone` 與離開紀錄、加入時的 backfill、共享清單的 members 與 folderId 規則、永久刪除清單的通知。
6. T6：Access 驗證、部署到 `daydo-api.audichuang.app`、對公開網址跑 e2e。
7. T7 App：同步引擎與兩台裝置收斂測試。T8 App：登入畫面、邀請連結畫面。
8. WebSocket 通知、MCP。
