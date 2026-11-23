# macOS 版（Mac Catalyst）

方向（使用者 2026-11-23 定）：整體沿用 iPad 版面，只針對鍵盤與滑鼠優化。TickTick Mac 截圖是互動參考：月份標題與「‹ 今天 ›」在頂列、清單頂端的「添加任務至…」輸入框、日曆裡點任務跳浮動小卡。

已驗證（spike）：只改 `ios/project.yml` 就能編過並執行；三欄、任務詳情、月曆可用；右鍵選單與 hover 沿用 iPad 的 `.contextMenu`／`.hoverEffect`。

## 票

每張票：改完用 `-DayDoSkipLogin -DayDoDemo` 開 Mac 版實際操作並截圖；iPad UI 測試不能壞。

1. **專案設定進 main**：Catalyst 開關、視窗最小尺寸、`uitest.sh build` 加 Mac 編譯。先確認不影響 iOS archive。
2. **日曆翻頁**：觸控板雙指左右滑翻月／週／日（UIKit pan 要接受捲動事件）；工具列顯示月份標題與「‹ 今天 ›」（`.principal` 在 Mac 不顯示）；⌘← ⌘→ 翻頁、⌘T 回今天。
3. **按鈕樣式**：Menu 按鈕在 Mac 多出的下拉箭頭拿掉。
4. **清單頂端快速新增**：Mac 上清單頂部常駐「新增任務至 <清單>」輸入框，Enter 建立、焦點留著可連續輸入；浮動 + 按鈕在 Mac 隱藏。
5. **鍵盤操作清單**：↑↓ 移動選取、Space 完成、Esc 關詳情（Return 開啟與 Delete 刪除已有）。
6. **日曆點任務跳小卡**：週／月／日裡點任務改成就地 popover（標題、日期、清單），不開整頁詳情。
7. **（待定）月曆格內顯示任務條**：TickTick 月曆每格列出任務，DayDo 現在是點點＋右側清單；版面變動大，前面做完再問。

## 未決

- 簽章：Mac mini 沒註冊在 Apple 開發者帳號，簽章版（登入、同步、Keychain）跑不起來；票 1–6 用 SkipLogin 不簽章驗收即可。
- 要不要上 TestFlight Mac。
