# 待做

- macOS 版。
- 提醒超過 60 筆的背景補排（`LocalDayDoAPI.upcomingReminders(limit: 60)`）。
- 跟隨系統 Dynamic Type。
- 寫入後縮小刷新範圍：目前每次寫入都重讀全部 lookup 並重排提醒。
- iOS 26 原生 `TabView` 改版（獨立搜尋分頁、捲動時縮小分頁列、底部附加列）：會偏離設計稿的浮動導覽列，要先決定。
- iOS 27 才有的任務列左右滑（`swipeActionsContainer`）與拖曳排序（`reorderable`），包 `#available` 保留 iOS 26 行為。
- 動畫小瑕疵：收合成單週時點跨月日期會多播一次換月滑動；非重複任務勾完約 1 秒內點不掉；重複任務在專案清單會先打勾再換成下一次。
- `testDetailDateAndTimeBlock` 偶發失敗（拖到 18:50，預期 19:00），單獨重跑會過。
- iPad UI 測試偶發「App animations complete notification not received」：打字後 XCUITest 等不到 App 靜止，每步卡 60 秒，動畫改版前（`2433710`）也會發生；移除注音鍵盤無效，根因未明。下一步是卡住當下用 lldb 列出 `animationKeys` 非空的 layer。
- 系統淺色、App 深色時冷啟動，LaunchScreen 交接給 SwiftUI 視窗的瞬間狀態列仍有 1–2 格（約 16–33 ms）黑字；SwiftUI 在 `willConnect` 前就 `makeKeyAndVisible`，目前的視窗覆寫趕不上。
- `ArchitectureTests` 的寫死顏色護欄以整個檔案放行（`CalendarScreen` 以外 7 個檔），檔內新加的 `.white`／`Color(hex:)` 不會被擋；之後改成逐行或逐用途放行。
