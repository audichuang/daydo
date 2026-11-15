# DayDo

## 我們在做什麼

DayDo 是待辦加日曆的 iPhone App，給自己和家人用，互動對標 TickTick。分三個階段：

1. **單機 App**（已完成，在 TestFlight）：資料只存在手機的 SQLite；今天、清單、任務詳情、日期面板、時間區塊、日曆（清單／年／月／週／3日／日）、搜尋、垃圾桶。
2. **同步與多人**（進行中）：Cloudflare Worker + D1 + Durable Objects，註冊登入、多裝置同步、共享清單、成員指派。
3. **MCP**：掛在 Worker 上，讓 AI 讀寫任務，工具沿用 ticktick-mcp 的名稱與欄位。

另外待做：桌面小工具（設計稿 6a/6b）、macOS 版；提醒超過 60 筆的背景補排、跟隨系統 Dynamic Type、寫入後縮小刷新範圍（目前每次寫入都重讀全部 lookup 並重排提醒）。

設計稿在 `design/`（`design/source/*.html` 是原始設計元件，`design/shots/` 是截圖），畫面編號 1a–6b 對應設計板標題；設計稿用的是舊名 Doneday。

## 結構

```
DayDoCore/   Swift Package：資料模型、SQLite（GRDB）、DayDoAPI 指令層、日期/重複/提醒邏輯
ios/         SwiftUI App（iOS 26+，iOS 27.2 SDK），XcodeGen 產生專案（project.yml）
server/      第二階段同步後端：Void（Cloudflare Workers，底層 Hono）＋ D1 ＋ 每位使用者的範圍 Durable Object
spec/        openapi.yaml：DayDoAPI 的 HTTP 合約，第二階段 Worker 與 MCP 共用；sync.md：同步協議；fixtures/sync-ops.json：App 實際編出的 op，server 測試直接讀
design/      設計稿
```

## 規則

- UI 不直接碰資料庫：所有讀寫走 `DayDoAPI`（`LocalDayDoAPI` 是本機實作）。新增功能時先加 API 方法與 `spec/openapi.yaml`，再接 UI。
- API 名稱與欄位對齊 ticktick-mcp（私有 repo `audichuang/ticktick-mcp` 的 `src/tools.ts`，本機沒有 clone，用 `gh api repos/audichuang/ticktick-mcp/contents/src/tools.ts --jq .content | base64 -d` 讀）：priority 0/1/3/5、status 0/2、`TRIGGER:` 提醒、RRULE、ISO 8601 `start`/`due` + `timezone` + `all_day`。之後的 MCP 直接沿用那套工具名。
- Schema 為同步預留：id 由 client 產生（UUIDv7），時間戳是 epoch ms，刪除用 `deletedAt` 軟刪除，每次寫入在同一 transaction 寫一筆 `change`（outbox，含變更欄位名）。改 schema 用新的 migration，已有的不改。
- 排序鍵用 `SortKey`（fractional index），不要重新編號。
- 這個 App 目前是測試用：畫面照使用者給的 TickTick 截圖做齊，後端（第二階段同步）還沒好的功能也保留入口，在本機可操作（例如邀請記為「等待同步」）；不放「尚未開放」「僅存於這台裝置」之類的說明文字。共享掛在清單上，不另開分頁。
- API 回傳的 `schedule` 已換成裝置時區。更新任務時，只有日期或時間真的改了才送 `schedule`，否則會把任務原本的時區改掉（只改提醒也會中招）。
- 牆鐘時間用該時區的年月日時分組件建立，不用「當天午夜＋分鐘數」：夏令時間切換日會差一小時。第二階段的 Worker 也照這條。

## 指令

```bash
cd DayDoCore && swift test                       # 核心單元測試
cd server && npm ci && npm run check              # 同步後端：型別檢查＋單元測試＋本機 dev server 上的登入與同步 e2e
cd ios && xcodegen generate                      # 改了 project.yml 或增刪檔案後
cd ios && xcodebuild test -project DayDo.xcodeproj -scheme DayDo \
  -destination 'platform=iOS Simulator,id=<DD 模擬器 UDID>' CODE_SIGNING_ALLOWED=NO   # UI 流程測試
```

啟動參數（Debug 用）：`-DayDoSkipLogin` 跳過登入、只用本機資料（UI 測試都要帶）；`-DayDoReset` 清空資料與偏好、`-DayDoDemo` 載入設計稿範例資料、`-DayDoScreen <名稱>` 直接開到某畫面（可用的名稱看 `ios/DayDo/App/DayDoApp.swift` 處理 `-DayDoScreen` 的 switch）。

## 模擬器

代號 `DD`。常駐機：`DD iPhone 18 Pro`（iOS 27.2）、`DD iPad Pro 11`（`43C3F165-E561-41CB-A39D-84AD902CCF91`）。

- iPad UI 測試：`cd ios && xcodebuild test -project DayDo.xcodeproj -scheme DayDo -destination 'platform=iOS Simulator,id=43C3F165-E561-41CB-A39D-84AD902CCF91' CODE_SIGNING_ALLOWED=NO`

- Codex 審查與 agy 也會在 DD 常駐機跑 UI 測試；自己跑完整 UI 測試前先 `pgrep -fl xcodebuild`，有別的在跑就等它結束（同時跑會在啟動時失敗：`Failed to send signal 19`）。
- Xcode 27.2 沒有 Simulator.app，模擬器視窗改由 `Xcode.app/Contents/Applications/DeviceHub.app` 開啟（它也列出其他專案的機器，別按到別人的 Start）。
- 通用規則（臨時機、收尾、DerivedData）見 `~/.agents/AGENTS.md` 的 iOS 模擬器那條，這裡只補 DD 專屬：
  - 臨時機命名 `DD tmp <任務名>`，只在平行 UI 測試才開；用完當下 `xcrun simctl shutdown <UDID>`，worktree 收斂時 `xcrun simctl delete <UDID>`。
  - 沒有開機腳本，直接 `xcrun simctl boot|shutdown <UDID>`。自己跑 `xcodebuild` 一律 `-destination 'platform=iOS Simulator,id=<UDID>' -parallel-testing-enabled NO`，不用 `booted` 別名。
  - iPad 版面測試用 `DD iPad Pro 11`，其餘用 `DD iPhone 18 Pro`；UDID 用 `xcrun simctl list devices` 依名稱查。
- 互動驗收用 `DayDoUITests`：跑測試時設 `TEST_RUNNER_DAYDO_SHOTS=<目錄>`，`shot()` 會把截圖寫進去，再和 `design/shots` 或使用者給的參考圖對照。

## 發版（TestFlight）

發版前讀 `ios/RELEASE.md`。一律從合併後的 main 打包；新 build 只發「自己」，發給「家人」要使用者明說這版已穩定。

## 第二階段（進行中）

同步協議（含進度與待決事項）寫在 `spec/sync.md`，改協議或改兩端的行為先改那份文件。

- 正式環境前面是 Cloudflare Access（應用程式「DayDo API (iOS app only)」，只放行 service token）。部署、secrets 與部署後的 smoke 照 `server/README.md` 的 Deploy；service token 與 `JWT_SECRET` 在 1Password `Agent` vault（「DayDo Cloudflare Access service token」「DayDo server JWT_SECRET」）。
- 改了 D1 schema 的部署會先套 migration 並留還原點；只在使用者要求發版或部署時才 `void deploy`。
- void 固定 1.8.0：npm 設定只裝發布滿 3 天的版本，新版會被拒，不要改 npm 設定繞過。
- 每位使用者的 `Scope` DO（`u:<userId>`）用自己的 SQLite 存列資料，寫入包在 `transactionSync` 內同步完成；`SYNC_FAULT=split-txn` 是僅開發建置有效的故障開關，並發測試開啟時必須失敗。
- 改了 App 的 Record 或 outbox 編碼，要用 `DAYDO_WRITE_FIXTURE=1 swift test` 重新產生 `spec/fixtures/sync-ops.json`，再跑 server 的測試。
