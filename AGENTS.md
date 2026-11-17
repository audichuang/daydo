# DayDo

## 我們在做什麼

DayDo 是待辦加日曆的 iPhone App，給自己和家人用，互動對標 TickTick。分三個階段：

1. **單機 App**（已完成，在 TestFlight）：資料只存在手機的 SQLite；今天、清單、任務詳情、日期面板、時間區塊、日曆（清單／年／月／週／3日／日）、搜尋、垃圾桶。
2. **同步與多人**（進行中）：Cloudflare Worker + D1 + Durable Objects，註冊登入、多裝置同步、共享清單、成員指派。
3. **MCP**（已上線）：掛在 Worker 上，讓 AI 讀寫任務，工具沿用 ticktick-mcp 的名稱與欄位。

設計稿在 `design/`（`design/source/*.html` 是原始設計元件，`design/shots/` 是截圖），畫面板號 1a–6b 印在 `design/shots/*.png` 的圖標題上（HTML 檔名與板號無關）；設計稿用的是舊名 Doneday。

## 結構

```
DayDoCore/   Swift Package：資料模型、SQLite（GRDB）、DayDoAPI 指令層、日期/重複/提醒邏輯
ios/         SwiftUI App（iOS 26+，iOS 27.2 SDK），XcodeGen 產生專案（project.yml）
server/      第二階段同步後端：Void（Cloudflare Workers，底層 Hono）＋ D1 ＋ 每位使用者的範圍 Durable Object
spec/        openapi.yaml：DayDoAPI 的 HTTP 合約，第二階段 Worker 與 MCP 共用；sync.md：同步協議；mcp.md：MCP 伺服器、OAuth 與 ICS 同步設計；fixtures/sync-ops.json：App 實際編出的 op，server 測試直接讀
design/      設計稿
```

## 規則

- UI 不直接碰資料庫：所有讀寫走 `DayDoAPI`，App 只拿得到 `DeviceStore.api`（`any DayDoAPI`）；資料庫型別在 DayDoCore 內部，開檔一律經 `DayDoStorage`。清單角色權限由 API 寫入路徑檢查，UI 只負責隱藏按鈕。新增功能時先加 API 方法與 `spec/openapi.yaml`，再接 UI。
- API 名稱與欄位對齊 ticktick-mcp（私有 repo `audichuang/ticktick-mcp` 的 `src/tools.ts`，本機沒有 clone，用 `gh api repos/audichuang/ticktick-mcp/contents/src/tools.ts --jq .content | base64 -d` 讀）：priority 0/1/3/5、status 0/2、`TRIGGER:` 提醒、RRULE、ISO 8601 `start`/`due` + `timezone` + `all_day`。MCP（`server/src/mcp/`）也沿用那套工具名。
- Schema 為同步預留：id 由 client 產生（UUIDv7），時間戳是 epoch ms，刪除用 `deletedAt` 軟刪除，每次寫入在同一 transaction 寫一筆 `change`（outbox，含變更欄位名）。改 schema 用新的 migration，已有的不改。
- 排序鍵用 `SortKey`（fractional index），不要重新編號。
- 互動照 TickTick，配色與字級照設計稿；兩者衝突時互動跟 TickTick。使用者會貼 TickTick 與 DayDo 的截圖附一句話回饋，先比對 TickTick 截圖的結構與互動再改。
- 只處理正常使用會碰到的情況：需要異常 client、刻意重用 id、極端並發時序才會發生的，記進 `spec/sync.md`「已知限制」，不加新機制（權限檢查、輸入驗證、防資料遺失不在此限）。功能範圍以家人實際會用到的為準，少用的往後排。
- 這個 App 目前是測試用：畫面照使用者給的 TickTick 截圖做齊，後端（第二階段同步）還沒好的功能也保留入口，在本機可操作（例如邀請記為「等待同步」）；不放「尚未開放」「僅存於這台裝置」之類的說明文字。共享掛在清單上，不另開分頁。
- API 回傳的 `schedule` 已換成裝置時區。更新任務時，只有日期或時間真的改了才送 `schedule`，否則會把任務原本的時區改掉（只改提醒也會中招）。
- 牆鐘時間用該時區的年月日時分組件建立，不用「當天午夜＋分鐘數」：夏令時間切換日會差一小時。第二階段的 Worker 也照這條。

## 指令

```bash
cd DayDoCore && swift test                       # 核心單元測試
cd server && npm ci && npm run check              # 同步後端：lint＋型別檢查＋單元測試＋本機 dev server 上的登入與同步 e2e
cd ios && xcodegen generate                      # 改了 project.yml 或增刪檔案後
ios/scripts/uitest.sh [iphone|ipad] [xcodebuild 參數…]   # UI 流程測試，單一測試加 -only-testing:DayDoUITests/<類別>/<方法>
```

`xcodegen generate` 之後 `ios/DayDo.xcodeproj/project.pbxproj` 只有 `TEMP_` UUID 變動時是雜訊，可以還原；改了 `project.yml` 的 target 或增刪檔案，重產的 pbxproj 要一起 commit（曾把新增的 `DayDoTests` target 一起還原掉，那些測試從來沒跑過）。

啟動參數（Debug 用）：UI 測試帶 `-DayDoSkipLogin`（跳過登入、只用本機資料）或 `-DayDoDebugStub`（假同步伺服器、token 不進 Keychain），不連正式伺服器（只測登入畫面與啟動畫面的除外）；`-DayDoReset` 清空資料與偏好、`-DayDoDemo` 載入設計稿範例資料、`-DayDoScreen <名稱>` 直接開到某畫面（可用的名稱看 `ios/DayDo/App/DayDoApp.swift` 處理 `-DayDoScreen` 的 switch）。

## 模擬器

常駐機：`DD iPhone 18 Pro`（iOS 27.2）；iPad 版面用 `DD iPad Pro 11`。

- UI 測試一律走 `ios/scripts/uitest.sh`：依名稱找機器、等別的 `xcodebuild` 跑完再開始（Codex、agy 和其他 session 共用這兩台，同時跑會在啟動時失敗：`Failed to send signal 19`）、關掉平行測試。
- `uitest.sh` 會先自己開機並等開機完成，xcodebuild 就不會在測完時把模擬器關掉。不要繞過腳本直接跑 `xcodebuild test`：模擬器若是 xcodebuild 開的，它測完就會關機，常常只開了 30 秒，PosterBoard 還在寫桌布資料。2026-11-17 就這樣把資料寫壞（膨脹到 5.7G），之後每次開機 PosterBoard 都當。
- 整批工作（多輪測試加互動驗收）都做完，才用 `ios/scripts/uitest.sh down [iphone|ipad]` 關掉本次用過的 DD 常駐機，不要每跑一輪就關一次。不要直接 `xcrun simctl shutdown`：`down` 會先等別人的測試跑完再關，直接關曾在別的 session 開機 14 秒時把機器關掉。只關自己用過的那台。
- 收起：整批 iOS 工作做完、不再需要模擬器時，用 `ios/scripts/uitest.sh park [iphone|ipad]` 把用過的常駐機整台（App、登入、設定）收進 NAS 的 `/Volumes/WorkSpace/ios-sim`，本機刪除。它會先等 xcodebuild 鎖再關機，PosterBoard 資料超過 1G 時拒收，先照下一條修好。之後 `uitest.sh` 找不到常駐機時，會在鎖裡自動用 `sim-vault` 還原，UDID 會換新。要在別的地方用（例如手動驗收），先跑一次 `uitest.sh` 讓它還原，或在沒有 xcodebuild 執行時跑 `sim-vault restore "DD iPhone 18 Pro"`。`sim-vault list` 列出 NAS 上的封存。
- 還原失敗時不重建：WorkSpace 沒掛上（結束碼 5）就先掛上再重跑；NAS 上沒有封存（3）或 runtime 已移除（4）就停下問使用者。空機之後再收起，會蓋掉有登入的封存。
- 別的 session 可能還開著常駐機在驗收；只收自己這批工作用過的那台。
- Mac 跳出 PosterBoard 當機視窗時，查 `~/Library/Logs/DiagnosticReports` 裡含 `SimDevice.<UDID>` 的 `.ips`。堆疊有 `PRPosterDescriptor _initWithPath:` 就先關機，把 `data/Library/Application Support/` 下的 `PRBPosterExtensionDataStore`、`com.apple.PosterKit` 改名備份後重開機，系統會重建。確認沒有新的 `.ips` 再刪備份；常駐機不 `erase`。
- 平行 UI 測試才開臨時機，命名 `DD tmp <任務名>`，用 `ios/scripts/uitest.sh "DD tmp <任務名>"` 跑。
- DD worktree／暫存 review 專案收尾時，DerivedData 清理依 `~/.agents/AGENTS.md`「做事邊界」的 iOS 模擬器規則執行。
- Xcode 27.2 沒有 Simulator.app，模擬器視窗改由 `Xcode.app/Contents/Applications/DeviceHub.app` 開啟（它也列出其他專案的機器，別按到別人的 Start）。
- 互動驗收：跑測試時設 `TEST_RUNNER_DAYDO_SHOTS=<目錄>`，`DayDoUITests` 的 `shot()` 會把截圖寫進去，再和 `design/shots` 或使用者給的參考圖對照。

## 發版（TestFlight）

發版前讀 `ios/RELEASE.md`。一律從合併後的 main 打包；新 build 只發「自己」，發給「家人」要使用者明說這版已穩定。

## 第二階段（進行中）

同步協議（含進度與待決事項）寫在 `spec/sync.md`，改協議或改兩端的行為先改那份文件。

多張票或要跨 session 接續的工作，計畫檔放 `docs/plans/<名稱>.md`：所有 agent 與之後的 session 共用這份，每張票做完記下 commit 範圍與偏離；工作結束就刪掉，該留的決策寫進 commit message 或 spec；GLOSSARY、AGENTS.md、spec 與程式註解不引用計畫檔。

- 只在使用者要求發版或部署時才 `void deploy`。
- 改了 App 的 Record 或 outbox 編碼，要用 `DAYDO_WRITE_FIXTURE=1 swift test` 重新產生 `spec/fixtures/sync-ops.json`，再跑 server 的測試。

## Code Review Rules

- 每個問題照常回報，但標明正常使用 DayDo 會不會碰到；只有異常 client 或極端時序才會發生的，建議記進 `spec/sync.md`「已知限制」，不要求加機制。
- diff 新增的判斷如果別處已經有一份（同一條規則的第二份），標出來並指出該擴充哪個既有 module。
- 修正一類問題時要附一道護欄：server 加在 `.oxlintrc.json` 或 `tests/architecture.test.ts`，App 加在 `DayDoCore/Tests/DayDoCoreTests/ArchitectureTests.swift`，拿掉修正時它要失敗；做不到就寫明原因。
