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

1. 開 worktree。派給 agy 的 prompt 寫明：只在這個 worktree 改、驗收條件、UI 測試只用 `ios/scripts/uitest.sh`（DD 模擬器）、不 commit 不上傳。
2. agy 完成後讀 `git diff`，照 AGENTS.md「指令」自己重跑受影響部分的測試（新 worktree 的 server 要先 `npm ci`），動到畫面就設 `TEST_RUNNER_DAYDO_SHOTS` 看截圖；動到動畫或手勢改用 `ios/scripts/record-uitest.sh` 錄影逐格看，截圖拍不到過渡。agy 順手改到的 `DayDoCore/Package.resolved` 不在任務範圍，還原。有問題用 agy 的 `--continue` 交回同一個對話修。
3. 優化或修 bug 類：Codex 審（動到互動或狀態時，另開一個 Opus 子代理平行獨立審，不給它 Codex 的結論）→ 轉述原文並篩選 → agy 修 → Claude 審 diff 與自測 → Codex 再審。最多 3 輪；第 3 輪結束仍有 Act on 就不修、不開第 4 輪，也不進步驟 4，照 review-gate 的 stalled-loop 把診斷交給使用者決定，其餘 finding 列進回報不修。
4. 併入最新 main 並重跑測試，合併、push，照 `ios/RELEASE.md` 出 TestFlight 給「自己」，`tf verify` 到 `RESULT READY`。之後用 `ios/scripts/uitest.sh park` 把用過的 DD 常駐機收進 NAS（AGENTS.md「模擬器」）。

## 回報

先附 agy 的原文回報，再寫自己的審查結果與測試輸出。
