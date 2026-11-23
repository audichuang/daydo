#!/bin/zsh
# Mac 版（Mac Catalyst）發到 Homebrew：Developer ID 簽章 → 公證 → GitHub Release → 更新 tap 的 cask。
# 從合併後的 main 跑（見 ios/RELEASE.md）。版號 <MARKETING_VERSION>.<main 的 commit 數>，tag mac-v<版號>。
set -euo pipefail
cd "${0:A:h}/.."
# exportArchive 需要系統 rsync；Homebrew rsync 3.x 會讓它 "Copy failed"。
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"

REPO=audichuang/daydo
TAP="$(brew --repo audichuang/tap)"
CASK="${TAP}/Casks/daydo.rb"
MARKETING=$(sed -nE 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"?([^"]+)"?$/\1/p' project.yml | head -1)
BUILD=$(git rev-list --count HEAD)
VERSION="${MARKETING}.${BUILD}"
TAG="mac-v${VERSION}"
OUT="build/mac-release-${VERSION}"
ZIP="${OUT}/DayDo-${VERSION}.zip"

if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
  echo "工作區有未提交的改動，先 commit 或還原" >&2; exit 1
fi
if gh release view "$TAG" -R "$REPO" >/dev/null 2>&1; then
  echo "${TAG} 已經發過；同一個 commit 不重發" >&2; exit 1
fi
git -C "$TAP" fetch -q origin
if [[ -n "$(git -C "$TAP" status --porcelain)" ]] || [[ "$(git -C "$TAP" rev-parse HEAD)" != "$(git -C "$TAP" rev-parse '@{u}')" ]]; then
  echo "tap（${TAP}）有未提交改動或與遠端不同步，先處理" >&2; exit 1
fi

mkdir -p "$OUT"
./scripts/gen-secrets.sh
if ! grep -Eq '^DAYDO_ACCESS_CLIENT_SECRET[[:space:]]*=[[:space:]]*[^[:space:]]+' Secrets.xcconfig; then
  echo "Secrets.xcconfig 缺少 Access token" >&2; exit 1
fi

# Developer ID 私鑰在獨立的 codexbar-signing 鑰匙圈；鎖著時 codesign 會跳密碼視窗，xcodebuild 就無聲卡住。
set -a; . ~/.config/op/agent-sa.env; set +a
KC_PW="$(op read 'op://Agent/codexbar-signing keychain password/password')"
security unlock-keychain -p "$KC_PW" ~/Library/Keychains/codexbar-signing.keychain-db
unset KC_PW

xcodegen generate --quiet
if ! xcodebuild -project DayDo.xcodeproj -scheme DayDo -configuration Release \
  -destination 'generic/platform=macOS,variant=Mac Catalyst' -archivePath "${OUT}/DayDo.xcarchive" \
  CURRENT_PROJECT_VERSION="$BUILD" -allowProvisioningUpdates archive > "${OUT}/archive.log" 2>&1; then
  { grep -E "error:|ARCHIVE FAILED" "${OUT}/archive.log" || true; } | tail -20; echo "archive 失敗：${OUT}/archive.log"; exit 1
fi
git checkout -q -- ../DayDoCore/Package.resolved
if ! xcodebuild -exportArchive -archivePath "${OUT}/DayDo.xcarchive" -exportOptionsPlist ExportOptions-mac.plist \
  -exportPath "${OUT}/export" -allowProvisioningUpdates > "${OUT}/export.log" 2>&1; then
  tail -30 "${OUT}/export.log"; echo "匯出失敗：${OUT}/export.log"; exit 1
fi

APP="${OUT}/export/DayDo.app"
ditto -c -k --keepParent "$APP" "${OUT}/notarize.zip"
xcrun notarytool submit "${OUT}/notarize.zip" -p codexbar-notary --wait | tee "${OUT}/notary.log"
grep -q "status: Accepted" "${OUT}/notary.log" || { echo "公證沒過：${OUT}/notary.log" >&2; exit 1; }
xcrun stapler staple "$APP"
spctl -a -vv "$APP"
ditto -c -k --keepParent "$APP" "$ZIP"
SHA=$(shasum -a 256 "$ZIP" | awk '{print $1}')

gh release create "$TAG" "$ZIP" -R "$REPO" --target "$(git rev-parse HEAD)" \
  --title "DayDo for Mac ${VERSION}" --notes "brew install --cask audichuang/tap/daydo"

if [[ ! -f "$CASK" ]]; then
  cat > "$CASK" <<'EOF'
cask "daydo" do
  version "0"
  sha256 "0"

  url "https://github.com/audichuang/daydo/releases/download/mac-v#{version}/DayDo-#{version}.zip"
  name "DayDo"
  desc "To-do list and calendar"
  homepage "https://github.com/audichuang/daydo"

  depends_on macos: ">= :tahoe"

  app "DayDo.app"

  zap trash: [
    "~/Library/Group Containers/group.com.audichuang.daydo",
    "~/Library/Containers/com.audichuang.daydo.widgets",
  ]
end
EOF
fi
sed -i '' -E "s/^  version \".*\"/  version \"${VERSION}\"/; s/^  sha256 \".*\"/  sha256 \"${SHA}\"/" "$CASK"
grep -q "version \"${VERSION}\"" "$CASK" && grep -q "sha256 \"${SHA}\"" "$CASK" || { echo "cask 沒改到：${CASK}" >&2; exit 1; }
git -C "$TAP" add Casks/daydo.rb
git -C "$TAP" commit -qm "daydo ${VERSION}"
git -C "$TAP" push -q origin HEAD
echo "已發 ${TAG}；brew upgrade --cask audichuang/tap/daydo"
