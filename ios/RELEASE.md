# 發版

兩個平台都從合併後的 main 打包，不從 worktree 打。主 checkout 有別人未收的改動擋住快轉時，不動那些改動：把分支推到 `origin/main`，再從 `git worktree add --detach <路徑> origin/main` 的乾淨副本打包，打完移除。

- App Store Connect app id `6834936769`，bundle id `com.audichuang.daydo`，team `37HFR5V2JJ`。
- 群組：內部「自己」（使用者本人）；外部「家人」（使用者與家人，`tf distribute` 一律帶 `--group`）。新 build 只發給「自己」；要發給「家人」必須使用者明說這版已穩定。外部群組每個版本的第一個 build 要過 Apple 的 Beta App Review（審查聯絡資訊與測試說明已在 App Store Connect 設好）。`ios/ExportOptions.plist` 不能加回 `testFlightInternalTestingOnly`，加了上傳的 build 就不能送外部測試。
- 外部群組送審：`tf` 只管內部群組，「家人」用 `asc builds add-groups --build-id <id> --group <家人群組 id> --submit --confirm`（群組 id 用 `asc testflight groups list --app 6834936769` 查；測試人員沒收到邀請時用 `asc testflight testers invite --app 6834936769 --email <email>` 重寄）。同一個版本一次只能有一個 build 在 Beta App Review，而且送出後撤不回；前一個還在排隊時送下一個會回 `Another build in the same train is already in beta review`，要等它審完再送（可以先把新 build 加進群組、不帶 `--submit`）。
- 家人用 Google 登入前，要把他的 Gmail 加進 Google Cloud 專案 `daydo-514804` 的 OAuth 測試使用者（測試模式）。
- App 連正式環境用的 Access service token 在打包時由 `ios/scripts/gen-secrets.sh` 從 1Password 寫進 `ios/Secrets.xcconfig`（gitignored），`testflight.sh` 會自動跑；模擬器要連正式環境就先手動跑一次。
- 沒有 Xcode Cloud，只有手動上傳：

```bash
cd ios && BUILD_NUMBER=$(tf next-build --app 6834936769) ./scripts/testflight.sh
tf verify --app 6834936769 --build <N> --group "自己" --wait 20m
```

- 簽章走 Xcode 已登入的帳號；帶 API key（`-authenticationKey*`）時 Xcode 27.2 回 `Authentication failed: bearer token`。
- `testflight.sh` 的 `-exportArchive` 用 `ExportOptions.plist` 的 `destination=upload` 同一個指令就上傳；只有 `export.log` 顯示在上傳前失敗（例如取得 App Store Connect store configuration／帳號這步報「No Accounts with App Store Connect Access」加「The request cannot be processed at this time. Please try again later」的暫時錯誤，並非帳號登出）才確定沒上傳，可用同一個 build 號重跑。上傳階段的錯誤（連線中斷、逾時）結果不明，`tf verify` 回 PENDING 時繼續查，確認 Apple 沒收到才重用 build 號。
- build 號用 `tf next-build` 的流水號，不用時間戳。
- 上傳後 build 不會自動進「自己」，照 `tf verify` 的 `next=` 跑 `tf distribute`，到 `RESULT READY` 才算發出去。

## Mac（Homebrew）

Developer ID 簽章、公證後，zip 放 `audichuang/daydo` 的 GitHub Release，cask 是 `audichuang/homebrew-tap` 的 `Casks/daydo.rb`（腳本第一次會自己建）。

```bash
cd ios && ./scripts/mac-release.sh
```

- 版號 `<MARKETING_VERSION>.<main 的 commit 數>`，tag `mac-v<版號>`，與 TestFlight 的 build 號無關。腳本要求 `HEAD` 等於 `origin/main`；同一版重跑會跳過已完成的步驟（Release 已上傳就只補 cask）。
- Developer ID 私鑰在 `codexbar-signing` 鑰匙圈（密碼在 1Password Agent），鎖著時 codesign 會跳密碼視窗、xcodebuild 無聲卡住；腳本會先解鎖。公證用 notarytool profile `codexbar-notary`。
- Release 是公開的，zip 裡含 Access service token（`spec/sync.md` 已接受 token 拆得出來）。
- 發完用 `brew upgrade --cask audichuang/tap/daydo` 裝起來、開得了並登入成功才算發出去。
