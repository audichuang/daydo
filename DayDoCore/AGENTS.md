# DayDoCore/：App 的資料與規則層

> 本檔只寫 DayDoCore 的增量；跨 App 與 server 的規則在根目錄 AGENTS.md。

App 與 Widget 共用的 Swift Package：任務規則、SQLite 儲存與同步都在這裡，`ios/` 只負責畫面。

- `API/LocalDayDoAPI` 是業務規則的正本（角色權限、完成重複任務、checklist、標籤）。共享走 `Sharing/ListSharing`，同步走 `Sync/SyncEngine`，畫面不依同步狀態分支。
- `Sync/`：`SyncEngine` 負責推送、拉取、首次登入對帳；`SyncApplier` 逐欄 HLC 合併，子列比父列先到時先暫存。

## 改這裡也要改那裡

- Domain 的 Schedule、Recurrence、Reminders，Support 的 SortKey、Identifiers，`LocalDayDoAPI` 的 `normalizeTags` 與 create／update／complete／move／checklist，在 `server/src/domain/` 與 `server/src/serverops/taskWrites.ts` 各有一份移植，改一邊就改另一邊。
- server 刻意偏離的地方不要改回來對齊 Swift：負的 `BYMONTHDAY` 直接拒絕（`spec/mcp.md` 第 7 節）、提醒有上限（`server/src/domain/reminders.ts` 檔頭：Swift 的 Int 乘法溢位會讓所有成員的 App 閃退）。
- Widget 用 `DayDoStorage.openReadOnly` 開檔，不跑 migration：改 Records 或 schema 後，資料庫比 Widget 新或沒 migrate 完都會開檔失敗。

## 踩過的雷

- `SyncEngine` 依位置把 push 結果對回 op，`rejected` 也算已確認、不再重送，有 row 就用伺服器的列覆蓋本機。這條決定了 server 什麼時候可以回 `rejected`（規則在 `server/AGENTS.md`）。
- App 進背景時持有 SQLite 檔鎖會被系統殺掉（0xdead10cc）：資料庫在背景暫停，開檔用 `NSFileCoordinator` 與持久 WAL。會開檔案資料庫的測試 suite 要依序執行，平行跑會互相觸發暫停通知。
- 完成重複任務時副本 id 是確定性 UUIDv5，讓兩台裝置離線完成同一次時只留一筆；那個 id 已被永久刪除（`purgedId`）就改用隨機 id，否則副本寫進 tombstone 後不生效，完成的副本就消失了。
