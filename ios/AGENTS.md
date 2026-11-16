# ios/：SwiftUI App 與 Widget

> 本檔只寫 ios 的增量；跨 App 與 server 的規則、指令、模擬器與發版在根目錄 AGENTS.md。

畫面層：狀態與寫入都經 `DayDo/App/AppModel.swift`（`@Observable`，持有 DayDoCore 的 `DeviceStore`），畫面不自己寫規則。規則改在 DayDoCore，畫面只負責顯示與隱藏按鈕。

## 畫面地圖（`DayDo/Screens/`，板號是 `design/shots/*.png` 圖上的標題）

- `DrawerView` 清單抽屜 1a｜`TaskListScreen` 任務列表 1b、1c｜`CalendarScreen` 日曆：清單視圖 2a、2b、事件月曆 2c，年／週／3日／日沒有板
- `TaskDetailSheet` 任務詳情 3a、3b｜`DatePanel` 日期面板 4a、4b｜`TimeBlockEditor` 時間區塊 4c、4d｜`EditListSheet` 新增／編輯清單 5
- `RootView`：根容器、底部分頁（任務／日曆／搜尋／設定）與共用 `ScreenHeader`。設計板的底欄是「任務／日曆／共享／搜尋」，現在的分頁是刻意改的：共享掛在清單上，設定改成分頁。
- 沒有板的：`ComposerSheet` 鍵盤上方的快速新增、`OtherScreens` 搜尋與設定、`SignInView`、分享與邀請的幾個 sheet（第二階段新增）。

## Widget（`DayDoWidgets/`，板號 6a、6b）

- Widget 用 `DayDoStorage.openReadOnly` 讀 App Group 裡同一個 SQLite，資料與 timeline 規則在 DayDoCore 的 `Domain/WidgetData.swift`。改資料形狀或 timeline 要一起改三個 Widget View 與 `DayDoTests/WidgetSnapshotTests`。
- 主題色與「日曆顯示已完成」放在 App Group 的 UserDefaults，鍵名 App 與 Widget 兩邊要一起改。App 寫入後由 `AppModel.scheduleWidgetReload()` 去抖再重載 timeline。
- 從 Widget 深連結進日曆某天時要清掉成員與清單篩選，日曆 Widget 也要遵守「隱藏已完成」。

## 踩過的雷

- iPad 版面：開任務詳情一律由 `AppModel` 決定內嵌或 sheet，畫面不要自己判斷；內嵌詳情、垃圾桶、設定子頁都在 iPad 上出過資料遺失或遮擋的 bug，改這幾處要用 `ios/scripts/uitest.sh ipad` 跑過。
- UI 測試不要假設現在的時段（日曆測試曾因此在某些時間失敗），也不要假設通知授權已處理。
