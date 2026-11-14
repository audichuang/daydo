# DayDo

待辦 App。設計稿在 `design/`（`design/source/*.html` 是原始設計元件，`design/shots/` 是截圖），畫面編號 1a–6b 對應設計板標題。

## 結構

```
DayDoCore/   Swift Package：資料模型、SQLite（GRDB）、DayDoAPI 指令層、日期/重複/提醒邏輯
ios/         SwiftUI App（iOS 26+，iOS 27.2 SDK），XcodeGen 產生專案（project.yml）
spec/        openapi.yaml：DayDoAPI 的 HTTP 合約，第二階段 Worker 與 MCP 共用
design/      設計稿
```

## 規則

- UI 不直接碰資料庫：所有讀寫走 `DayDoAPI`（`LocalDayDoAPI` 是本機實作）。新增功能時先加 API 方法與 `spec/openapi.yaml`，再接 UI。
- API 名稱與欄位對齊 ticktick-mcp（`ssh ubuntu:~/research/audiskill/ticktick/ticktick-mcp/src/tools.ts`）：priority 0/1/3/5、status 0/2、`TRIGGER:` 提醒、RRULE、ISO 8601 `start`/`due` + `time_zone` + `all_day`。之後的 MCP 直接沿用那套工具名。
- Schema 為同步預留：id 由 client 產生（UUIDv7），時間戳是 epoch ms，刪除用 `deletedAt` 軟刪除，每次寫入在同一 transaction 寫一筆 `change`（outbox，含變更欄位名）。改 schema 用新的 migration，不改 `v1`。
- 排序鍵用 `SortKey`（fractional index），不要重新編號。
- 單機階段沒有帳號與成員：UI 不得顯示假的「已同步」、成員或留言數。

## 指令

```bash
cd DayDoCore && swift test                       # 核心單元測試
cd ios && xcodegen generate                      # 改了 project.yml 或增刪檔案後
cd ios && xcodebuild test -project DayDo.xcodeproj -scheme DayDo \
  -destination 'platform=iOS Simulator,id=<DD 模擬器 UDID>' CODE_SIGNING_ALLOWED=NO   # UI 流程測試
```

啟動參數（Debug 用）：`-DayDoReset` 清空資料與偏好、`-DayDoDemo` 載入設計稿範例資料、`-DayDoScreen <drawer|detail|date|time|calendar|events|editlist|compose|settings|search|shared>` 直接開到某畫面。

## 模擬器

代號 `DD`。常駐機：`DD iPhone 18 Pro`（iOS 27.2）。平行任務可臨時建 `DD …`，用完刪掉；不碰其他代號的模擬器。

## 發版（TestFlight）

- App Store Connect app id `6834936769`，bundle id `com.audichuang.daydo`，team `37HFR5V2JJ`，內部群組「自己」。
- 沒有 Xcode Cloud，只有手動上傳：

```bash
cd ios && BUILD_NUMBER=$(~/Project/audi-skill/ios-release/scripts/tf next-build --app 6834936769) ./scripts/testflight.sh
~/Project/audi-skill/ios-release/scripts/tf verify --app 6834936769 --build <N> --group "自己" --wait 20m
```

- 簽章走 Xcode 已登入的帳號；帶 API key（`-authenticationKey*`）時 Xcode 27.2 回 `Authentication failed: bearer token`。
- build 號用 `tf next-build` 的流水號，不用時間戳。

## 第二階段（未做）

Cloudflare Worker + D1（資料）+ Durable Objects（每個清單或使用者一個，序列化寫入、推送變更），註冊登入、多人共享、成員指派。App 端把 `change` outbox 推上去、拉回遠端變更；MCP 掛在 Worker 上，工具名沿用 ticktick-mcp。
