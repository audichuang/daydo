# 待做

- macOS 版。
- 提醒超過 60 筆的背景補排（`LocalDayDoAPI.upcomingReminders(limit: 60)`）。
- 跟隨系統 Dynamic Type。
- 寫入後縮小刷新範圍：目前每次寫入都重讀全部 lookup 並重排提醒。
- iOS 26 原生 `TabView` 改版（獨立搜尋分頁、捲動時縮小分頁列、底部附加列）：會偏離設計稿的浮動導覽列，要先決定。
- iOS 27 才有的任務列左右滑（`swipeActionsContainer`）與拖曳排序（`reorderable`），包 `#available` 保留 iOS 26 行為。
- 動畫小瑕疵：收合成單週時點跨月日期會多播一次換月滑動；非重複任務勾完約 1 秒內點不掉；重複任務在專案清單會先打勾再換成下一次。
- `testDetailDateAndTimeBlock` 偶發失敗（拖到 18:50，預期 19:00），單獨重跑會過。
