# DayDo

## 我們在做什麼

DayDo 是待辦加日曆的 iPhone App，給自己和家人用，互動對標 TickTick。分三個階段：

1. **單機 App**（已完成，在 TestFlight）：資料只存在手機的 SQLite；今天、清單、任務詳情、日期面板、時間區塊、日曆（清單／年／月／週／3日／日）、搜尋、垃圾桶。
2. **同步與多人**（下一步）：Cloudflare Worker + D1 + Durable Objects，註冊登入、多裝置同步、共享清單、成員指派。
3. **MCP**：掛在 Worker 上，讓 AI 讀寫任務，工具沿用 ticktick-mcp 的名稱與欄位。

另外待做：桌面小工具（設計稿 6a/6b）、macOS 版；提醒超過 60 筆的背景補排、跟隨系統 Dynamic Type、寫入後縮小刷新範圍（目前每次寫入都重讀全部 lookup 並重排提醒）。

設計稿在 `design/`（`design/source/*.html` 是原始設計元件，`design/shots/` 是截圖），畫面編號 1a–6b 對應設計板標題；設計稿用的是舊名 Doneday。

## 結構

```
DayDoCore/   Swift Package：資料模型、SQLite（GRDB）、DayDoAPI 指令層、日期/重複/提醒邏輯
ios/         SwiftUI App（iOS 26+，iOS 27.2 SDK），XcodeGen 產生專案（project.yml）
spec/        openapi.yaml：DayDoAPI 的 HTTP 合約，第二階段 Worker 與 MCP 共用
design/      設計稿
```

## 規則

- UI 不直接碰資料庫：所有讀寫走 `DayDoAPI`（`LocalDayDoAPI` 是本機實作）。新增功能時先加 API 方法與 `spec/openapi.yaml`，再接 UI。
- API 名稱與欄位對齊 ticktick-mcp（私有 repo `audichuang/ticktick-mcp` 的 `src/tools.ts`，本機沒有 clone，用 `gh api repos/audichuang/ticktick-mcp/contents/src/tools.ts --jq .content | base64 -d` 讀）：priority 0/1/3/5、status 0/2、`TRIGGER:` 提醒、RRULE、ISO 8601 `start`/`due` + `timezone` + `all_day`。之後的 MCP 直接沿用那套工具名。
- Schema 為同步預留：id 由 client 產生（UUIDv7），時間戳是 epoch ms，刪除用 `deletedAt` 軟刪除，每次寫入在同一 transaction 寫一筆 `change`（outbox，含變更欄位名）。改 schema 用新的 migration，不改 `v1`（`v2` 加入 `projectInvite` 記錄待同步的共享邀請）。
- 排序鍵用 `SortKey`（fractional index），不要重新編號。
- 這個 App 目前是測試用：畫面照使用者給的 TickTick 截圖做齊，後端（第二階段同步）還沒好的功能也保留入口，在本機可操作（例如邀請記為「等待同步」）；不放「尚未開放」「僅存於這台裝置」之類的說明文字。共享掛在清單上，不另開分頁。
- API 回傳的 `schedule` 已換成裝置時區。更新任務時，只有日期或時間真的改了才送 `schedule`，否則會把任務原本的時區改掉（只改提醒也會中招）。
- 牆鐘時間用該時區的年月日時分組件建立，不用「當天午夜＋分鐘數」：夏令時間切換日會差一小時。第二階段的 Worker 也照這條。

## 分支與 worktree

這個 repo 常有多個 session 同時在做，`ticktick/` 這個 main checkout 只用來合併與發版，不直接改：

- 每個需求（連文件、小修）先開 worktree：`git worktree add ../ticktick-wt/<名稱> -b <名稱> main`，之後所有改檔、測試、commit 都在那個目錄。
- 做完在 worktree 先併入最新 main、跑過測試，再回 main checkout `git merge <名稱>`、push；合併成功後 `git worktree remove ../ticktick-wt/<名稱>`、`git branch -d <名稱>`。
- TestFlight 從合併後的 main 打包。
- 別的 session 的 worktree 與分支（例如 `sync-*`）不動、不合併、不刪，要動先問使用者。

## 指令

```bash
cd DayDoCore && swift test                       # 核心單元測試
cd ios && xcodegen generate                      # 改了 project.yml 或增刪檔案後
cd ios && xcodebuild test -project DayDo.xcodeproj -scheme DayDo \
  -destination 'platform=iOS Simulator,id=<DD 模擬器 UDID>' CODE_SIGNING_ALLOWED=NO   # UI 流程測試
```

啟動參數（Debug 用）：`-DayDoReset` 清空資料與偏好、`-DayDoDemo` 載入設計稿範例資料、`-DayDoScreen <drawer|detail|date|calendar|events|week|editlist|compose|settings|search>` 直接開到某畫面。

## 模擬器

代號 `DD`。常駐機：`DD iPhone 18 Pro`（iOS 27.2）。平行任務可臨時建 `DD …`，用完刪掉；不碰其他代號的模擬器。

- Codex 審查與 agy 也會在 DD 常駐機跑 UI 測試；自己跑完整 UI 測試前先 `pgrep -fl xcodebuild`，有別的在跑就等它結束（同時跑會在啟動時失敗：`Failed to send signal 19`）。
- Xcode 27.2 沒有 Simulator.app，模擬器視窗改由 `Xcode.app/Contents/Applications/DeviceHub.app` 開啟（它也列出其他專案的機器，別按到別人的 Start）。
- 互動驗收用 `DayDoUITests`：跑測試時設 `TEST_RUNNER_DAYDO_SHOTS=<目錄>`，`shot()` 會把截圖寫進去，再和 `design/shots` 或使用者給的參考圖對照。

## 發版（TestFlight）

- App Store Connect app id `6834936769`，bundle id `com.audichuang.daydo`，team `37HFR5V2JJ`，內部群組「自己」。
- 沒有 Xcode Cloud，只有手動上傳：

```bash
cd ios && BUILD_NUMBER=$(~/Project/audi-skill/ios-release/scripts/tf next-build --app 6834936769) ./scripts/testflight.sh
~/Project/audi-skill/ios-release/scripts/tf verify --app 6834936769 --build <N> --group "自己" --wait 20m
```

- 簽章走 Xcode 已登入的帳號；帶 API key（`-authenticationKey*`）時 Xcode 27.2 回 `Authentication failed: bearer token`。
- build 號用 `tf next-build` 的流水號，不用時間戳。
- 上傳後 build 不會自動進「自己」，照 `tf verify` 的 `next=` 跑 `tf distribute`，到 `RESULT READY` 才算發出去。

## 第二階段（未做）

Cloudflare Worker + D1（資料）+ Durable Objects（每個清單或使用者一個，序列化寫入、推送變更），註冊登入、多人共享、成員指派。App 端把 `change` outbox 推上去、拉回遠端變更；MCP 掛在 Worker 上，工具名沿用 ticktick-mcp。
