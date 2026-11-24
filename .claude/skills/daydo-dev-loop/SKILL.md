---
name: daydo-dev-loop
description: DayDo 的開發與優化迴圈：agy 實作、Codex 審查、Claude 審 diff 並自測，最後出 TestFlight 給「自己」到 READY。Use when 在 DayDo 做功能、UI 改版、優化或修 bug，或使用者說「持續優化」「修到沒問題」「確定 app 沒問題」「出一版」。
---

# DayDo 開發迴圈

使用者要求優化或修 bug 時，已授權下面整串（審查、修、commit、push、出 TestFlight 給「自己」到 READY），中途不用再問（第 3 輪審完仍有 Act on 例外，見步驟 3）；新功能先列「要做／先不做」給使用者看過再派工。發給「家人」、`void deploy` 仍要使用者明說。

## 分工

- **agy 寫**：功能與 UI 改版用 agy skill 的 `implement` 模式（預設 hydrogen-high）。一兩行的小改或除錯參數 Claude 直接改。
- **Codex 審**：唯讀審查，照 AGENTS.md 的 Code Review Rules 分桶。
- **Claude 審與自測**：讀 `git diff`、自己重跑測試、看截圖，判斷要不要修。

## 流程

1. 開 worktree。派給 agy 的 prompt 寫明：只在這個 worktree 改、驗收條件、UI 測試只用 `ios/scripts/uitest.sh`（DD 模擬器；回 8 是別人在用這台或還在等鎖，照報不要繞過）、手動驗收先 `uitest.sh up` 拿 UDID、動到畫面的新 UI 測試在畫面到位後留一個 `shot()`（agy 曾自己看完就拿掉，Claude 要截圖只能再暫時加回去重跑）、不 commit 不上傳。
2. agy 完成後讀 `git diff`，照 AGENTS.md「指令」自己重跑受影響部分的測試（新 worktree 的 server 要先 `npm ci`）；UI 全套只測凍結的樹——commit 之後、派下一輪修正之前才跑。動到畫面就設 `TEST_RUNNER_DAYDO_SHOTS` 看截圖；動到動畫或手勢改用 `ios/scripts/record-uitest.sh` 錄影逐格看（錄影由 `uitest.sh` 在持 lease 期間啟停），截圖拍不到過渡；看錄影時核對測試每一步在畫面上真的發生（曾有「捲到 12 點」其實沒捲、測試照樣通過）。新 UI 測試除了單獨跑，還要在全套裡過一次，而且不能依賴執行時間（時間格的初始捲動位置跟著現在幾點走）。動到 iPhone／iPad 共用的畫面，合併前在最終 commit 跑一次 iPad 全套。Mac 沒有 UI 測試：動到 Mac 會顯示的畫面，照 `ios/.claude/skills/verify/` 由 Claude 用 lcu 在 Mac 實際操作並截圖（agy 與 Codex CLI 的回報不算 Mac 驗收）。xcodebuild 每次編譯都會改 `DayDoCore/Package.resolved`，不在任務範圍，commit 前還原。iPad 全套偶發「App animations complete notification not received」（等不到 App 靜止，每步卡 60 秒，改版前就有）：回報出現次數，因此失敗的測試單獨重跑並註明；根因見 `docs/backlog.md`，不要憑幾套結果下結論。有問題用 agy 的 `--continue` 交回同一個對話修。
3. 優化或修 bug 類：Codex 審（動到互動或狀態時，另開一個 Opus 子代理平行獨立審，不給它 Codex 的結論）→ 轉述原文並篩選 → agy 修（派工 prompt 固定寫「不跑裸 xcodebuild（編譯檢查用 `ios/scripts/uitest.sh build`）、不 down／park」）→ Claude 審 diff 與自測 → Codex 再審。最多 3 輪；第 3 輪結束仍有 Act on 就不修、不開第 4 輪，也不進步驟 4，照 review-gate 的 stalled-loop 把診斷交給使用者決定，其餘 finding 列進回報不修。
4. 併入最新 main 並重跑測試，合併、push，照 `ios/RELEASE.md` 出 TestFlight 給「自己」，`tf verify` 到 `RESULT READY`。之後收尾（AGENTS.md「模擬器」）：自己 `up` 的先 `ios/scripts/uitest.sh down` 交回 lease（`up` 回 8 說這個 worktree 已有人 `up` 時，`up`／`down`／測試都帶自己的 `DD_SIM_OWNER`），整批做完再 `ios/scripts/uitest.sh park` 收進 NAS。看最後一行 `park rc=N`：8 是別人的 lease 還在、DD 測試鎖等不到，或有沒 lease 的舊版 `uitest.sh` 在跑（舊版批次要先結束），照訊息回報；若 owner 的 worktree 已不存在、或確認那個 session 已結束，才可 `sim-vault release "<名稱>" --lease <owner>` 清掉這筆孤兒 lease；不要清別人仍在用的；總結前跑 `sim-vault status "DD iPhone 18 Pro"`（用過 iPad 也查那台），把結果附進回報。

## 回報

先附 agy 的原文回報，再寫自己的審查結果與測試輸出。
