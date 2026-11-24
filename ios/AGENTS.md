# ios/：SwiftUI App 與 Widget

> 本檔只寫 ios 的增量；跨 App 與 server 的規則、指令、模擬器與發版在根目錄 AGENTS.md。

狀態與寫入都經 `DayDo/App/AppModel.swift`（`@Observable`，持有 DayDoCore 的 `DeviceStore`）；規則改在 DayDoCore，不寫在畫面裡。

## 畫面地圖（`DayDo/Screens/` → 設計板號）

- `DrawerView` 清單抽屜 1a｜`TaskListScreen` 任務列表 1b、1c｜`CalendarScreen` 日曆：清單視圖 2a、2b、事件月曆 2c，年／週／3日／日沒有板
- `TaskDetailSheet` 任務詳情 3a、3b｜`DatePanel` 日期面板 4a、4b｜`TimeBlockEditor` 時間區塊 4c、4d｜`EditListSheet` 新增／編輯清單 5
- `RootView`：根容器、底部分頁（任務／日曆／搜尋／設定）與共用 `ScreenHeader`。設計板的底欄有「共享」沒有「設定」，現在的分頁是刻意改的。
- 沒有板的：`ComposerSheet` 鍵盤上方的快速新增、`OtherScreens` 搜尋與設定、`SignInView`、分享與邀請的幾個 sheet（第二階段新增）。

改動畫、轉場、手勢或觸覺前讀 `ios/MOTION.md`。
找哪個動畫卡、比較改前改後的掉幀：`ios/scripts/perf/README.md`。

## Widget（`DayDoWidgets/`，板號 6a、6b）

- 讀 App Group 裡同一個 SQLite，資料與 timeline 規則在 DayDoCore 的 `Domain/WidgetData.swift`。改資料形狀或 timeline 要一起改三個 Widget View 與 `DayDoTests/WidgetSnapshotTests`。
- 主題色、外觀（`appearance`）與「日曆顯示已完成」放在 App Group 的 UserDefaults，鍵名 App 與 Widget 兩邊要一起改。App 寫入後由 `AppModel.scheduleWidgetReload()` 去抖再重載 timeline。
- 從 Widget 深連結進日曆某天時要清掉成員與清單篩選，日曆 Widget 也要遵守「隱藏已完成」。

## Mac 版（Mac Catalyst）

- Mac 沿用 iPad 的 regular 畫面，不開 Mac 資料夾；只有外框照桌面 App 改（使用者看到「放大版 iPad」會直接說奇怪）：左側圖示欄切分頁、只有任務分頁有清單欄、月曆撐滿視窗。只在 Mac 才有的差異用 `Platform.isMac` 的一般 `if`（iOS 編譯也檢查得到 Mac 分支）；`#if targetEnvironment(macCatalyst)` 只包 iOS SDK 編不過的 API。鍵盤、觸控板、快捷鍵的新行為也要包 `Platform.isMac`：不分平台時曾讓 iPhone 接外接鍵盤能無確認永久刪除任務。
- Mac 版沒有 Sign in with Apple（Catalyst 的 Developer ID profile 不支援，Mac 用 `DayDo/DayDo-mac.entitlements`），Apple 登入與連結入口在 Mac 一律隱藏。
- Mac Debug 與 brew 裝的正式版同 bundle id：Debug 資料、偏好、Keychain 已改用獨立位置，但通知中心仍共用，Mac Debug 不重排提醒。`-DayDoReset`／`-DayDoSkipLogin`／`-DayDoDemo` 只在 Debug 生效（ArchitectureTests 擋）。
- 驗收：`open -n <uitest.sh mac 印出的 .app> --args -DayDoReset -DayDoSkipLogin -DayDoDemo`（不加 `-DayDoReset` 會重複灌範例資料，每筆任務出現兩次） 實際操作並截圖；Mac 沒有 UI 測試，動到 `DayDo/Screens` 的 Mac 改動，合併前跑 `ios/scripts/uitest.sh ipad`。

## 踩過的雷

- iPad 版面：開任務詳情一律由 `AppModel` 決定內嵌或 sheet，畫面不要自己判斷；內嵌詳情、垃圾桶、設定子頁都在 iPad 上出過資料遺失或遮擋的 bug，改這幾處要用 `ios/scripts/uitest.sh ipad` 跑過。
- 先改畫面、延遲寫入的樂觀更新：寫入前要重讀任務的最新狀態，否則等待期間同一任務的存檔會把這次動作吞掉。重複任務完成後 id 不變、只換成下一次，樂觀狀態要記「哪一次」，不能只記 id。
- 被 `.clipped()` 裁掉或收合起來看不見的內容仍然點得到，要另外關掉點擊（日曆收合成單週時，隱藏的那幾週曾經點得到）。
- 深淺色：顏色只走 `Palette`（`UIColor(dynamicProvider:)`），深色值要和改版前一致；外觀只經 `AppearanceApplier` 設視窗的 override。Info.plist 不能加回 `UIUserInterfaceStyle`，加了「淺色／跟隨系統」就失效；啟動畫面的狀態列靠 `UIStatusBarStyleLightContent` 維持白字。
- UI 測試不要假設現在的時段（日曆測試曾因此在某些時間失敗），也不要假設通知授權已處理。
- 手機版任務／日曆／搜尋分頁造訪後常駐（`RootView` 的 `CompactTabContent`，為了切換不重建）：從別的分頁回來時畫面要和新建的一樣（選取日期、篩選、搜尋文字、捲動、鍵盤焦點都回初始），隱藏時不載入資料，查詢條件變了先清掉舊資料。第一版漏了這些，審查指出在日曆換清單後回任務頁會先顯示、也能勾到上一個清單的任務。
- Mac 工具列不顯示 `ToolbarItem(placement: .principal)`；工具列裡的 SwiftUI `Menu` 會忽略 `.menuIndicator(.hidden)`。UIKit pan recognizer 要設 `allowedScrollTypesMask` 才收觸控板捲動。
- iPad 的 form sheet 會隨鍵盤上下移動：表單內容放得下就不要包 `ScrollView`（點擊會被捲動吃掉），驗證碼欄位不用 `.numberPad`（iPad 是會擋按鈕的浮動小鍵盤）。
- 任務列表與搜尋結果是 `LazyVStack`：UI 測試要找畫面外的任務列先捲過去。
- UI 測試沒有結果時，先看 log 最後的 `t = …` 步驟：停在 `Wait for com.audichuang.daydo to idle` 是 App 一直不閒置，是程式問題；log 末行停在 `Resolve Package Graph` 不代表卡在套件解析。先用 main 在同一台模擬器跑同一個測試對照，main 會過就對單一測試 `git bisect run`（每步加 `timeout`），不要先判成模擬器環境壞掉：曾因此誤判、還說別的專案也壞了，實際是刪掉一段看似重複的分頁重設造成的。
