# 待做

- macOS 版。
- 提醒超過 60 筆的背景補排（`LocalDayDoAPI.upcomingReminders(limit: 60)`）。
- 跟隨系統 Dynamic Type。
- 寫入後縮小刷新範圍：目前每次寫入都重讀全部 lookup 並重排提醒。
- iOS 26 原生 `TabView` 改版（獨立搜尋分頁、捲動時縮小分頁列、底部附加列）：會偏離設計稿的浮動導覽列，要先決定。
- iOS 27 才有的任務列左右滑（`swipeActionsContainer`）與拖曳排序（`reorderable`），包 `#available` 保留 iOS 26 行為。
- 時間格拖曳（週／3日／日）後續：拖到畫面邊緣自動捲動與翻週（現在一次只能拖一個畫面約 9 小時）；放開後復原；週視圖窄欄並排多個任務時長按目標太小；任務塊改成非按鈕後少了按下回饋與 iPad 鍵盤開啟；拉出新增時預覽塊比時間膠囊慢半拍、疊在既有任務上文字重疊；非整格時間（09:07）拖動後不對齊格線；拉上下緣改長度；全天列拖曳。
- `DayDoCore/Package.resolved` 每次 xcodebuild 都被改寫；`project.pbxproj` 的 `LastUpgradeCheck` 與 `DayDo.xcscheme` 每次重產都變（1430→1600、多一行 `buildArchitectures`）。找根因，或把重產結果 commit 一次讓它不再變。
- 動畫小瑕疵：收合成單週時點跨月日期會多播一次換月滑動；非重複任務勾完約 1 秒內點不掉；重複任務在專案清單會先打勾再換成下一次。
- `testDetailDateAndTimeBlock` 偶發失敗（拖到 18:50，預期 19:00），單獨重跑會過。
- iPad UI 測試偶發「App animations complete notification not received」：打字後 XCUITest 等不到 App 靜止，每步卡 60 秒，動畫改版前（`2433710`）也會發生；移除注音鍵盤無效，根因未明。下一步是卡住當下用 lldb 列出 `animationKeys` 非空的 layer。
- 系統淺色、App 深色時冷啟動，LaunchScreen 交接給 SwiftUI 視窗的瞬間狀態列仍有 1–2 格（約 16–33 ms）黑字；SwiftUI 在 `willConnect` 前就 `makeKeyAndVisible`，目前的視窗覆寫趕不上。
- `ArchitectureTests` 的寫死顏色護欄以整個檔案放行（`CalendarScreen` 以外 7 個檔），檔內新加的 `.white`／`Color(hex:)` 不會被擋；之後改成逐行或逐用途放行。
- 底部分頁切換、月曆收合／展開每次仍約掉 2 幀（最長 70–85ms，模擬器），DayDo 程式碼已不到 10ms，剩 SwiftUI 內部排版與繪製；要實機用 Instruments 的 Hitches 才看得到細節（量法見 `ios/scripts/perf/README.md`）。
- 常駐分頁的邊界情況（2026-11-22 Codex 審查，判定改版前就有或需異常時序）：停在日曆分頁時點無日期的日曆 Widget 不會回到今天；切回日曆後 SQLite 讀取失敗會留著上一次的任務；同步刪除清單與切換清單時序重疊時，舊請求的錯誤會把 scope 改回今天。
- `testAppearanceChoicePersistsAcrossRelaunch` 偶發失敗：點「設定」後 0.18 秒就點「外觀」，落在分頁淡入期間沒生效，單獨重跑會過。
