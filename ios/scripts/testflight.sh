#!/bin/zsh
# 打包並上傳 TestFlight（只給內部測試，不用審核）。
# 簽章用 Xcode 自動簽章，走 Xcode 裡已登入的 Apple 帳號（Settings → Accounts）。
# 2026-11-15 實測：帶 -authenticationKey* 時 Xcode 27.2 回 "Authentication failed: bearer token"，
# 同一把 key 用 asc 卻正常，所以不帶 API key。
# App Store Connect app id 6834936769。build 號必須給：
#   BUILD_NUMBER=$(tf next-build --app 6834936769) ./scripts/testflight.sh
set -euo pipefail
cd "${0:A:h}/.."
# exportArchive 需要系統 rsync；Homebrew rsync 3.x 會讓它 "Copy failed"。
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

: "${BUILD_NUMBER:?set BUILD_NUMBER (use: tf next-build --app <app id>)}"
OUT="build/testflight-${BUILD_NUMBER}"
AUTH=(-allowProvisioningUpdates)

mkdir -p "$OUT"
./scripts/gen-secrets.sh
if [[ ! -f Secrets.xcconfig ]] \
  || ! grep -Eq '^DAYDO_ACCESS_CLIENT_ID[[:space:]]*=[[:space:]]*[^[:space:]]+' Secrets.xcconfig \
  || ! grep -Eq '^DAYDO_ACCESS_CLIENT_SECRET[[:space:]]*=[[:space:]]*[^[:space:]]+' Secrets.xcconfig; then
  echo "Secrets.xcconfig 缺少 DAYDO_ACCESS_CLIENT_ID 或 DAYDO_ACCESS_CLIENT_SECRET" >&2
  exit 1
fi
/opt/homebrew/bin/xcodegen generate --quiet
if ! xcodebuild -project DayDo.xcodeproj -scheme DayDo -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "${OUT}/DayDo.xcarchive" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" "${AUTH[@]}" archive > "${OUT}/archive.log" 2>&1; then
  { grep -E "error:|BUILD FAILED|ARCHIVE FAILED" "${OUT}/archive.log" || true; } | tail -20; echo "archive 失敗，完整 log：${OUT}/archive.log"; exit 1
fi
if ! xcodebuild -exportArchive -archivePath "${OUT}/DayDo.xcarchive" -exportOptionsPlist ExportOptions.plist \
  -exportPath "${OUT}/export" "${AUTH[@]}" > "${OUT}/export.log" 2>&1; then
  tail -30 "${OUT}/export.log"; echo "上傳失敗，完整 log：${OUT}/export.log"; exit 1
fi
echo "已上傳 build ${BUILD_NUMBER}；App Store Connect 處理完（約 5～15 分鐘）後會出現在 TestFlight。"
