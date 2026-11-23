# macOS 版（Mac Catalyst）

方向（使用者 2026-11-23 定）：沿用同一個 target 與 iPad 的三欄架構，但 Mac 上要像桌面 App，不能看起來是放大的 iPad；鍵盤與滑鼠優先。TickTick Mac 截圖是互動參考：月份標題與「‹ 今天 ›」在頂列、清單頂端的「添加任務至…」輸入框、日曆裡點任務跳浮動小卡。發佈走 Homebrew tap（Developer ID）。

已驗證：只改 `ios/project.yml` 就能編過並執行；Developer ID 匯出、公證、Gatekeeper 都過（Mac 用 `DayDo/DayDo-mac.entitlements`，不含 Sign in with Apple：Catalyst 的 Developer ID profile 不支援）。簽章用的 Developer ID 在 `codexbar-signing` 鑰匙圈，鎖著時 codesign 會跳密碼視窗把 xcodebuild 卡住。

## 票

每張票：改完開 Mac 版實際操作並截圖；動到 `ios/DayDo/Screens` 的跑 iPad UI 測試。

1. **Mac Debug 資料隔離**：Debug 與 brew 正式版共用 App Group 容器；Mac Debug 改用獨立目錄與 Keychain service，之後才能放心用 `-DayDoReset`／`-DayDoDemo`。
2. **帳號連結**（使用者要求：一個帳號可綁多種登入方式）：spec（`/auth/link`）→ server → 三端設定頁「登入方式」。已屬於別的帳號的身分拒絕綁定、不合併。要部署 Worker、發 iOS TestFlight（自己）。
3. **Mac 登入頁重新設計**：桌面版雙欄、Google ＋ Email 驗證碼（server 已支援 App 的 email 登入，App 還沒有入口），Mac 不顯示 Apple 登入。
4. **桌面化**：大標題改工具列標題、浮動 + 改清單頂端快速新增、Menu 下拉箭頭、sheet 改 popover 或較小視窗、側欄底部大按鈕改列。
5. **日曆**：觸控板翻頁（UIKit pan 收捲動事件）、工具列月份標題與「‹ 今天 ›」、⌘← ⌘→、⌘T；點任務跳小卡。
6. **鍵盤操作清單**：↑↓、Space 完成、Esc。
7. **發版**：`ios/scripts/mac-release.sh`、`ios/ExportOptions-mac.plist`、tap 的 `Casks/daydo.rb`、`ios/RELEASE.md` Mac 節；從 main 打包（需要 `gen-secrets.sh` 產生的 Access token）。
8. **固化**：依 Fable 的放置規範更新根 AGENTS.md、`ios/AGENTS.md`（同一 target、`Platform.isMac` 一般 `if`、`#if targetEnvironment(macCatalyst)` 只包 iOS 編不過的 API、`uitest.sh mac`）。待建的名稱等實物進 main 才寫。
9. **（待定）月曆格內顯示任務條**。
