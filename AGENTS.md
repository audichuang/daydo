# DayDo

## 我們在做什麼

DayDo 是待辦加日曆的 iPhone／iPad／Mac App，給自己和家人用，互動對標 TickTick。分三個階段：

1. **單機 App**（已完成，在 TestFlight）：資料只存在手機的 SQLite；今天、清單、任務詳情、日期面板、時間區塊、日曆（清單／年／月／週／3日／日）、搜尋、垃圾桶。
2. **同步與多人**（已上線，剩 WebSocket 通知）：Cloudflare Worker + D1 + Durable Objects，註冊登入、多裝置同步、共享清單、成員指派。
3. **MCP**（已上線）：掛在 Worker 上，讓 AI 讀寫任務，工具沿用 ticktick-mcp 的名稱與欄位。

設計稿在 `design/`（`design/source/*.html` 是原始設計元件，`design/shots/` 是截圖），畫面板號 1a–6b 印在 `design/shots/*.png` 的圖標題上（HTML 檔名與板號無關）；設計稿用的是舊名 Doneday。

## 結構

```
DayDoCore/   Swift Package：資料模型、SQLite（GRDB）、DayDoAPI 指令層、日期/重複/提醒邏輯
ios/         SwiftUI App（iOS 26+，iOS 27.2 SDK），XcodeGen 產生專案（project.yml）；Mac 版是同一個 target 的 Mac Catalyst，沒有另外的 macOS target
server/      第二階段同步後端：Void（Cloudflare Workers，底層 Hono）＋ D1 ＋ 每位使用者的範圍 Durable Object
spec/        openapi.yaml：DayDoAPI 的 HTTP 合約，第二階段 Worker 與 MCP 共用；sync.md：同步協議；mcp.md：MCP 伺服器、OAuth 與 ICS 同步設計；fixtures/sync-ops.json：App 實際編出的 op，server 測試直接讀
design/      設計稿
```

## 規則

- UI 不直接碰資料庫：所有讀寫走 `DayDoAPI`，App 只拿得到 `DeviceStore.api`（`any DayDoAPI`）；資料庫型別在 DayDoCore 內部，開檔一律經 `DayDoStorage`。清單角色權限由 API 寫入路徑檢查，UI 只負責隱藏按鈕。新增功能時先加 API 方法與 `spec/openapi.yaml`，再接 UI。
- API 名稱與欄位對齊 ticktick-mcp（私有 repo `audichuang/ticktick-mcp` 的 `src/tools.ts`，本機沒有 clone，用 `gh api repos/audichuang/ticktick-mcp/contents/src/tools.ts --jq .content | base64 -d` 讀）：priority 0/1/3/5、status 0/2、`TRIGGER:` 提醒、RRULE、ISO 8601 `start`/`due` + `timezone` + `all_day`。MCP（`server/src/mcp/`）也沿用那套工具名。
- Schema 為同步預留：id 由 client 產生（UUIDv7），時間戳是 epoch ms，刪除用 `deletedAt` 軟刪除，每次寫入在同一 transaction 寫一筆 `change`（outbox，含變更欄位名）。改 schema 用新的 migration，已有的不改。
- 排序鍵用 `SortKey`（fractional index），不要重新編號。
- 會顯示其他成員的畫面（共享成員、指派）：名字與頭像取自登入帳號（Google 名字與大頭照、Apple 第一次授權的名字），拿不到才請使用者填；預設值不能人人相同，自己那列標「（你）」，「我」這類佔位名不當成會同步出去的資料。驗收要有兩個帳號並排的截圖或 UI 測試 fixture。
- 互動照 TickTick，配色與字級照設計稿；兩者衝突時互動跟 TickTick。使用者會貼 TickTick 與 DayDo 的截圖附一句話回饋，先比對 TickTick 截圖的結構與互動再改。
- 只處理正常使用會碰到的情況：需要異常 client、刻意重用 id、極端並發時序才會發生的，記進 `spec/sync.md`「已知限制」，不加新機制（權限檢查、輸入驗證、防資料遺失不在此限）。功能範圍以家人實際會用到的為準，少用的往後排。
- 這個 App 目前是測試用：畫面照使用者給的 TickTick 截圖做齊，後端還沒做的功能也保留入口、在本機可操作；不放「尚未開放」「僅存於這台裝置」之類的說明文字。共享掛在清單上，不另開分頁。
- API 回傳的 `schedule` 已換成裝置時區。更新任務時若送回與回傳值相同的 `schedule`，API 會忽略而不覆寫原本存的時區；真正改了日期、時間或時區才會寫入送來的值。
- 牆鐘時間用該時區的年月日時分組件建立，不用「當天午夜＋分鐘數」：夏令時間切換日會差一小時。第二階段的 Worker 也照這條。

## 指令

```bash
cd DayDoCore && swift test                       # 核心單元測試
cd server && npm ci && npm run check              # 同步後端完整檢查（lint、型別、單元測試、全部 e2e 含 ics／mcp／fault），合併前跑；日常改動用 npm run check:fast
cd ios && xcodegen generate                      # 改了 project.yml 或增刪檔案後
ios/scripts/uitest.sh [build|iphone|ipad] [xcodebuild 參數…]  # 編譯檢查或 UI 流程測試，單一測試加 -only-testing:DayDoUITests/<類別>/<方法>
ios/scripts/uitest.sh mac                        # Mac 版編譯檢查（不碰模擬器、不拿鎖），印出 .app 路徑；改了 #if targetEnvironment(macCatalyst) 區塊或 project.yml 後
bash ios/scripts/tests/test_uitest_sh.sh         # 改了 uitest.sh／record-uitest.sh／flock-exec.py 後（stub，不碰模擬器）
```

repo 沒有 GitHub Actions：push 後不等 CI，合併前以本機測試結果為準。

`xcodegen generate` 之後 `ios/DayDo.xcodeproj/project.pbxproj` 只有 `TEMP_` UUID 變動時是雜訊，可以還原；改了 `project.yml` 的 target 或增刪檔案，重產的 pbxproj 要一起 commit（曾把新增的 `DayDoTests` target 一起還原掉，那些測試從來沒跑過）。

啟動參數（Debug 用）：UI 測試帶 `-DayDoSkipLogin`（跳過登入、只用本機資料）或 `-DayDoDebugStub`（假同步伺服器、token 不進 Keychain），不連正式伺服器（只測登入畫面與啟動畫面的除外）；`-DayDoReset` 清空資料與偏好、`-DayDoDemo` 載入設計稿範例資料、`-DayDoScreen <名稱>` 直接開到某畫面（可用的名稱看 `ios/DayDo/App/Debug/DebugLaunch.swift` 處理 `-DayDoScreen` 的 switch）。

## 模擬器

常駐機：`DD iPhone 18 Pro`（iOS 27.2）；iPad 版面用 `DD iPad Pro 11`。

- UI 測試一律走 `ios/scripts/uitest.sh`：先拿 DayDo 鎖（固定檔 `~/Library/Developer/CoreSimulator/sim-vault/project-locks/daydo-uitest.lock` 上的 flock，xcodebuild 繼承它，測試程序還活著鎖就在），再等全機別的 `xcodebuild` 跑完（Codex、agy 和其他 session 共用這兩台，同時跑會在啟動時失敗：`Failed to send signal 19`），再用 `sim-vault run --lease dd:run --boot --deny-other-leases` 取機開機並執行測試（held lease 綁在繼承的 fd 上，測試與錄影都結束才自動釋放、期間也會擋住別人後續的 `ensure`；機器保持開機），關掉平行測試。除了呼叫者自己（有設 `DD_SIM_OWNER` 時只放它；沒設則放這個 worktree 的 session lease，即 `sim-vault whoami`）以外有任何 lease（別的 session 的手動驗收）就回 8 不跑：測試的 `-DayDoReset` 會清掉 App 資料與 Keychain。
- `uitest.sh` 會先自己開機並等開機完成，xcodebuild 就不會在測完時把模擬器關掉。不要繞過腳本直接跑 `xcodebuild test`／`build`／`build-for-testing`：測試方面模擬器若是 xcodebuild 開的，測完就會關機，PosterBoard 還在寫桌布資料時斷開會把資料寫壞（2026-11-17 曾膨脹到 5.7G 導致每次開機當掉）；編譯方面，DerivedData 每個 worktree 一份，同一個 worktree 裡 UI 測試進行中再編譯會換掉測試中的 App，編譯檢查一律用 `ios/scripts/uitest.sh build`（它會等全機任何 xcodebuild 結束，最長 30 分鐘後回 8）。
- 手動驗收（install、launch、看畫面）前先 `ios/scripts/uitest.sh up [iphone|ipad]` 拿 UDID，它會登記 lease，park 與別人的 `down` 就不會收走這台。有設 `DD_SIM_OWNER` 時沿用該 owner；沒設時用 sim-vault 的 session lease（`--lease auto --lease-scope <worktree> --lease-prefix dd:up`）。同一個 worktree 先前的 `up` 還持有 lease 時再 `up` 會回 8：先讓那個 session `down`（若 session 已重開、錨點換了，照訊息用 `sim-vault release "<名稱>" --lease <token>` 清掉），或兩個 session 各設不同的 `DD_SIM_OWNER` 再 `up`／`down`／測試。沒設 `DD_SIM_OWNER` 的測試會把這個 worktree 的 session lease（`whoami`）當成自己，所以同一個 worktree 有別的 session 在手動驗收時，自己一定要設 `DD_SIM_OWNER`。沒設 `DD_SIM_OWNER` 時 `up` 不能重跑（第二次也回 8），記住第一次印出的 UDID；前一個 session 沒 `down` 就結束了，新 session 先 `down` 再 `up`。常駐機寫全名（`"DD iPhone 18 Pro"`）與寫 `iphone` 等同。
- 收尾：自己 `up` 的自己 `down`。整批工作（多輪測試加互動驗收）都做完，才用 `ios/scripts/uitest.sh down [iphone|ipad]`（同一個 `DD_SIM_OWNER`；沒設時釋放這個 worktree 的 session lease）交回 lease，沒有別人的 lease 才關機（`sim-vault shutdown`），有就回 8 並列出 owner；看到沒經過 `uitest.sh`（不持 lease）的 xcodebuild 正在這台跑也回 8、不關機，照實回報、不要替別人 release（若 owner 的 worktree 已不存在、或確認那個 session 已結束，才可 `sim-vault release "<名稱>" --lease <owner>` 清掉這筆孤兒 lease；不要清別人仍在用的）。
- 收起：先 `down` 交回自己的 lease，再用 `ios/scripts/uitest.sh park [iphone|ipad]` 把用過的常駐機整台（App、登入）收進 NAS：它拿 DayDo 鎖（等 DD 測試與它們殘留的子程序結束），再 `sim-vault park --shutdown`。別人的 lease 還在時 sim-vault 回 8，照實回報，腳本不會自動清；若 owner 的 worktree 已不存在、或確認那個 session 已結束，才可 `sim-vault release "<名稱>" --lease <owner>` 清掉這筆孤兒 lease；不要清別人仍在用的。最後一行固定印 `park rc=N` 並以同一碼結束。總結前跑 `sim-vault status --json "DD iPhone 18 Pro"`（用過 iPad 也查 `"DD iPad Pro 11"`），看 `leases` 與 `archive` 確認已收起或還有誰在用（不加 `--json` 收起後什麼都不印）。之後 `uitest.sh` 找不到常駐機會用 `sim-vault ensure` 還原，UDID 會換新；手動驗收或新腳本一律用 `up` 印出的 UDID，不要自己依名稱查（收起後查不到，`record-uitest.sh` 曾這樣壞過）。`DD_PARK_TRIM=1` 會加 `--trim-posterboard`，真機驗證前不要用。
- DD 政策：結束碼 3 是 NAS 上沒有封存；4 是封存用的 iOS runtime 沒裝（先裝回 runtime 再跑，不用重建）。兩者都不自動建機，停下問使用者；真的重建才要重新登入。8 是忙碌：等 DayDo 鎖或 xcodebuild 逾時（30 分鐘）、有別人的 lease（測試不跑、park／down 不收不關，訊息列出 owner），同一個 worktree 先前的 `up` 還沒 `down`，`run` 收尾時仍有程序握著 lease fd（`held-by-other`，照訊息查 `lsof` 確認後再 `kill`），或 park／down 看到沒經過 `uitest.sh` 的 xcodebuild 正在這台上跑；2 是用法錯誤，或 PATH 上找不到 sim-vault／版本低於 4.0.0（照訊息 `uv tool install --force "git+https://github.com/audichuang/sim-vault@v4.1.0"`）；等鎖逾時的訊息若說持有者 pid 已結束，是殘留的 xcodebuild 或 recordVideo 還握著鎖：`lsof ~/Library/Developer/CoreSimulator/sim-vault/project-locks/daydo-uitest.lock` 找出來，確認不是別人進行中的測試再結束它；11 是 `record-uitest.sh` 的測試過了但錄影失敗（recordVideo 提前退出、失敗或要強制停止），影片不能用，看 `<prefix>.mp4.recordVideo.log`（測試也失敗時回測試的碼）；其他結束碼原樣傳回，照 `sim-vault --help` 的下一步處理，背景見 modern-ios-guidance 技能。
- 平行 UI 測試才開臨時機，命名 `DD tmp <任務名>`，用 `ios/scripts/uitest.sh "DD tmp <任務名>"` 跑。
- 互動驗收：跑測試時設 `TEST_RUNNER_DAYDO_SHOTS=<目錄>`，`DayDoUITests` 的 `shot()` 會把截圖寫進去，再和 `design/shots` 或使用者給的參考圖對照。目錄指到主 checkout 的 `.agent-work/<主題>/`，不放 worktree 裡：`wt-done` 收 worktree 會一起刪掉，曾因此重跑測試才補出報告截圖。
- UI 測試每一步都印 `App animations complete notification not received`、各等 60 秒時，先 `pgrep -lx xcodebuild` 看有沒有別的專案的測試同時在跑（不用 `-f`：別的 agent session 的提示詞含 xcodebuild，會被當成在跑）（搶模擬器資源，曾因此一項測試跑十幾分鐘），不是 App 壞了；等它結束再重跑沒跑完的項目。

## 發版

發版前讀 `ios/RELEASE.md`。一律從合併後的 main 打包；新 build 只發「自己」，發給「家人」要使用者明說這版已穩定。「發版」沒指明平台時只發 TestFlight；Mac 版（Homebrew）要使用者明說。

## 第二階段：同步

同步協議（含進度與待決事項）寫在 `spec/sync.md`，改協議或改兩端的行為先改那份文件。

多張票或要跨 session 接續的工作，計畫檔放 `docs/plans/<名稱>.md`：所有 agent 與之後的 session 共用這份，每張票做完記下 commit 範圍與偏離；工作結束就刪掉，該留的決策寫進 commit message 或 spec；GLOSSARY、AGENTS.md、spec 與程式註解不引用計畫檔。

- 只在使用者要求發版或部署時才 `void deploy`。
- 改了 App 的 Record 或 outbox 編碼，要用 `DAYDO_WRITE_FIXTURE=1 swift test` 重新產生 `spec/fixtures/sync-ops.json`，再跑 server 的測試。

## Code Review Rules

- 每個問題照常回報，但標明正常使用 DayDo 會不會碰到；只有異常 client 或極端時序才會發生的，建議記進 `spec/sync.md`「已知限制」，不要求加機制。
- diff 新增的判斷如果別處已經有一份（同一條規則的第二份），標出來並指出該擴充哪個既有 module。
- diff 取代既有流程時（例如 Mac 日曆浮窗改成右側詳情），只剩舊流程在用的元件、參數、狀態要在同一個 diff 刪掉；漏刪會變成沒人用卻每次照跑的程式碼，日曆錨點探針就這樣多留了兩輪。
- 只影響實體鍵盤導覽（iPad 外接鍵盤、用 Tab 在欄位間移動）的 finding 照常列出但不修，也不為它多開一輪審查：使用者不用外接鍵盤，這類意見曾連三輪佔掉審查輪數。Mac 的鍵盤操作、觸控與 VoiceOver 照常處理。
- 修正一類問題時要附一道護欄：server 加在 `.oxlintrc.json` 或 `tests/architecture.test.ts`，App 加在 `DayDoCore/Tests/DayDoCoreTests/ArchitectureTests.swift`，拿掉修正時它要失敗；做不到就寫明原因。
