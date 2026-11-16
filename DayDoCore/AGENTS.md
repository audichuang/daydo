# DayDoCore/：App 的資料與規則層

> 本檔只寫 DayDoCore 的增量；跨 App 與 server 的規則在根目錄 AGENTS.md。

App 與 Widget 共用的 Swift Package：任務規則、SQLite 儲存與同步都在這裡，`ios/` 只負責畫面。

## 子資料夾

- `API/`：`DayDoAPI` 是 App 唯一的讀寫入口。`LocalDayDoAPI` 是業務規則的正本（角色權限、完成重複任務、checklist、標籤），server 的 `src/serverops/taskWrites.ts` 照它移植。
- `Domain/`：純規則（Schedule 牆鐘、Recurrence、Reminders、Grouping 分區、DateDraft 日期面板暫存、WidgetData 給 Widget 的資料與 timeline）。
- `Storage/`：`AppDatabase`（internal，持有 GRDB 與 migration）與對外的開檔入口 `DayDoStorage`；`DeviceStore` 也定義在這裡。
- `Sync/`：`SyncEngine`（推送、拉取、首次登入對帳）、`SyncApplier`（逐欄 HLC 合併、子列先到時暫存）、`SyncWireModels`（線上格式）。
- `Sharing/`：`ListSharing` 是 App 面對的共享契約，離線版與遠端版各一個實作，畫面不依同步狀態分支。
- `Support/`：HLC、UUIDv7／v5、LocalDay、SortKey。

## 改這裡也要改那裡

- Domain 的 Schedule、Recurrence、Reminders、SortKey、Identifiers、`normalizeTags`，以及 `LocalDayDoAPI` 的 create／update／complete／move／checklist，在 `server/src/domain/` 與 `server/src/serverops/taskWrites.ts` 各有一份移植，改一邊就改另一邊。server 刻意偏離的地方不要改回來對齊 Swift：負的 `BYMONTHDAY` 直接拒絕（`spec/mcp.md` 第 7 節）、提醒有上限（`server/src/domain/reminders.ts` 檔頭：Swift 的 Int 乘法溢位會讓所有成員的 App 閃退）。
- 改 Records 或 outbox 編碼要重產 `spec/fixtures/sync-ops.json`（指令在根目錄 AGENTS.md），server 有五個測試檔讀它。
- 改 Records 或 schema 時記得 Widget 用 `DayDoStorage.openReadOnly` 開檔，不跑 migration：資料庫比 Widget 新或沒 migrate 完都會開檔失敗。

## 踩過的雷

- `SyncEngine` 依位置把 push 結果對回 op，`rejected` 也寫 `ackedAt`，之後不再重送，有 row 就用伺服器的列覆蓋本機。所以 server 只能為資料錯誤回 `rejected`；版本不一致、逾時這類暫時性錯誤必須回 429／5xx 讓整批重送，否則使用者的修改會遺失。
- App 進背景時持有 SQLite 檔鎖會被系統殺掉（0xdead10cc）：資料庫在背景暫停，開檔用 `NSFileCoordinator` 與持久 WAL。會開檔案資料庫的測試 suite 要依序執行，平行跑會互相觸發暫停通知。
- 完成重複任務時副本 id 是確定性 UUIDv5；那個 id 已被永久刪除（`purgedId`）就改用隨機 id，否則兩台裝置會重用同一個 id。
