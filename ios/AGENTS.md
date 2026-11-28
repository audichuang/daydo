# ios/：SwiftUI App 與 Widget

> 本檔只寫 ios 的增量；跨 App 與 server 的規則、指令、模擬器與發版在根目錄 AGENTS.md。

UI 改動一律同時維護 iPhone、iPad、Mac 三個平台：同一個畫面三邊都要看過、附截圖；只改其中一邊時，回報寫明另外兩邊為什麼不用改（iPad 月曆曾停在手機版小月格，Mac 早已有撐滿的月格卻沒跟上）。

狀態與寫入都經 `DayDo/App/AppModel.swift`（`@Observable`，持有 DayDoCore 的 `DeviceStore`）；規則改在 DayDoCore，不寫在畫面裡。

## 畫面地圖（`DayDo/Screens/` → 設計板號）

- 檔案依功能放在 `Screens/` 的子資料夾（Root、Tasks、Calendar、Drawer、Lists、Account、Search、Settings），一個檔放一個概念；`ArchitectureTests` 有幾道護欄寫死檔案路徑，搬檔或拆檔要一起改，否則護欄會因為讀不到檔而失敗。
- `DrawerView` 清單抽屜 1a｜`TaskListScreen` 任務列表 1b、1c｜`CalendarScreen` 日曆：清單視圖 2a、2b、事件月曆 2c，年／週／3日／日沒有板
- `TaskDetailSheet` 任務詳情 3a、3b｜`DatePanel` 日期面板 4a、4b｜`TimeBlockEditor` 時間區塊 4c、4d｜`EditListSheet` 新增／編輯清單 5
- `RootView`：根容器、底部分頁（任務／日曆／搜尋／設定）與共用 `ScreenHeader`。設計板的底欄有「共享」沒有「設定」，現在的分頁是刻意改的。
- 沒有板的：`ComposerSheet` 鍵盤上方的快速新增、`SearchScreen`、`SettingsScreen`、`SignInView`、分享與邀請的幾個 sheet（第二階段新增）。

改動畫、轉場、手勢或觸覺前讀 `ios/MOTION.md`。
找哪個動畫卡、比較改前改後的掉幀：`ios/scripts/perf/README.md`。

## Widget（`DayDoWidgets/`，板號 6a、6b）

- 讀 App Group 裡同一個 SQLite，資料與 timeline 規則在 DayDoCore 的 `Domain/WidgetData.swift`。改資料形狀或 timeline 要一起改三個 Widget View 與 `DayDoTests/WidgetSnapshotTests`。
- 主題色、外觀（`appearance`）與「日曆顯示已完成」放在 App Group 的 UserDefaults，鍵名 App 與 Widget 兩邊要一起改。App 寫入後由 `AppModel.scheduleWidgetReload()` 去抖再重載 timeline。
- 從 Widget 深連結進日曆某天時要清掉成員與清單篩選，日曆 Widget 也要遵守「隱藏已完成」。

## Mac 版（Mac Catalyst）

使用者要的是「桌面 App」，不是放大的 iPad；看到平板痕跡會直接退件。參照是 TickTick Mac。Mac 的 UI 準則：

- 用電腦的操作邏輯：右鍵選單、雙擊空白處新增、hover 回饋、Esc 關閉、可拖寬的欄、快捷鍵；不用觸控邏輯（左滑、長按、大圓鈕、浮動小卡、一層層點進去的頁）。
- 版面：左側圖示欄切分頁；任務分頁是清單欄＋列表主欄＋可拖寬的詳情側欄；頂列自繪、標題靠左，不用系統導覽列；搜尋是浮動面板，設定是左右兩欄。使用者點名過的平板痕跡：列表窄詳情寬、置中標題與圓鈕、卡片式三行任務列、整頁搜尋、一層層點進去的設定、小月曆配行程的日曆。
- 日曆是 Mac 上最常用的畫面：大螢幕要在月格裡直接看到當天內容，所以 Mac 沒有「清單」模式、預設月檢視；左側小月曆與清單篩選，點任務在右側詳情直接編輯。改日曆要照桌面日曆想，不能只沿用 iPad 版。
- 擺放：`RootView` 依平台分三個外殼：手機（`CompactTabContent`＋底欄）、iPad（`RegularSplitView`）、Mac（`MacRootView`），外殼裡不再判斷別的平台；整塊只在 Mac 出現的畫面做成獨立 struct、放同資料夾的獨立檔（如 `MacTaskColumns`、`CalendarMacSidebar`），共用畫面用 `if Platform.isMac` 切過去；Mac 的按鈕、選單外框共用 `Components/MacChrome.swift`。尺寸、字級這類小差異的三元式留在原處即可。已經排除 Mac 的程式碼（手機頂列、`isRegular && !Platform.isMac` 的工具列、觸控滑動列）裡不寫 `Platform.isMac` 分支，那裡永遠不會執行。為 Mac 改外觀不動共用的修飾，否則會一起改到 iPhone／iPad（年曆對齊曾這樣漏過去）。
- 鍵盤、觸控板、快捷鍵的新行為要包 `Platform.isMac`：不分平台時曾讓 iPhone 接外接鍵盤能無確認永久刪除任務。
- 同一筆任務同時只能有一份編輯器：浮動面板（搜尋）蓋在仍在運作的編輯器上，再開一份會讓舊草稿覆寫新存的內容。
- Mac 版沒有 Sign in with Apple（Catalyst 的 Developer ID profile 不支援，Mac 用 `DayDo/DayDo-mac.entitlements`），Apple 登入與連結入口在 Mac 一律隱藏。
- Mac Debug 與 brew 裝的正式版同 bundle id：Debug 資料、偏好、Keychain 已改用獨立位置，但通知中心仍共用，Mac Debug 不重排提醒。
- 動到 `DayDo/Screens` 的改動，合併前跑 `ios/scripts/uitest.sh ipad` 全套，並照 `ios/.claude/skills/verify/`（verify 技能）在 Mac 實際操作一遍。

## 踩過的雷

- iPad 版面：開任務詳情一律走 `AppModel.openTask`（傳入 `inlineAvailable`），畫面不自己建 sheet 或自設內嵌選取；內嵌詳情、垃圾桶、設定子頁都在 iPad 上出過資料遺失或遮擋的 bug，改這幾處要用 `ios/scripts/uitest.sh ipad` 跑過。
- 先改畫面、延遲寫入的樂觀更新：寫入前要重讀任務的最新狀態，否則等待期間同一任務的存檔會把這次動作吞掉。重複任務完成後 id 不變、只換成下一次，樂觀狀態要記「哪一次」，不能只記 id。
- 被 `.clipped()` 裁掉或收合起來看不見的內容仍然點得到，要另外關掉點擊（日曆收合成單週時，隱藏的那幾週曾經點得到）。
- 深淺色：顏色只走 `Palette`（`UIColor(dynamicProvider:)`），深色值要和改版前一致；外觀只經 `AppearanceApplier` 設視窗的 override；啟動畫面的狀態列靠 `UIStatusBarStyleLightContent` 維持白字。
- UI 測試不要假設現在的時段（日曆測試曾因此在某些時間失敗），也不要假設通知授權已處理。
- 手機版任務／日曆／搜尋分頁造訪後常駐（`RootView` 的 `CompactTabContent`，為了切換不重建）：從別的分頁回來時畫面要和新建的一樣（選取日期、篩選、搜尋文字、捲動、鍵盤焦點都回初始），隱藏時不載入資料，查詢條件變了先清掉舊資料。第一版漏了這些，審查指出在日曆換清單後回任務頁會先顯示、也能勾到上一個清單的任務。
- Mac 工具列不顯示 `ToolbarItem(placement: .principal)`；工具列裡的 SwiftUI `Menu` 會忽略 `.menuIndicator(.hidden)`。UIKit pan recognizer 要設 `allowedScrollTypesMask` 才收觸控板捲動。
- iPad 的 form sheet 會隨鍵盤上下移動：表單內容放得下就不要包 `ScrollView`（點擊會被捲動吃掉），驗證碼欄位不用 `.numberPad`（iPad 是會擋按鈕的浮動小鍵盤）。
