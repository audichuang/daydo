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
ASSET_NAME="DayDo-${VERSION}.zip"
ZIP="${OUT}/${ASSET_NAME}"

if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
  echo "工作區有未提交的改動，先 commit 或還原" >&2; exit 1
fi
git fetch -q origin
if [[ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ]]; then
  echo "HEAD（$(git rev-parse --short HEAD)）不是 origin/main（$(git rev-parse --short origin/main)），請切到最新的 main 再發版" >&2; exit 1
fi

RELEASE_STATE=""
if RELEASE_STATE="$(gh release view "$TAG" -R "$REPO" --json isDraft,assets \
  --jq "if .isDraft then \"draft\" elif any(.assets[]; .name == \"${ASSET_NAME}\") then \"ready\" else \"missing_asset\" end" 2>&1)"; then
  case "$RELEASE_STATE" in
    draft)
      echo "${TAG} 目前是 draft Release，請先發布或刪除該 draft 後再重跑" >&2; exit 1
      ;;
    missing_asset)
      echo "${TAG} 已存在但缺少資產 ${ASSET_NAME}，請補齊資產或刪除該 Release 後再重跑" >&2; exit 1
      ;;
    ready)
      echo "${TAG} 與 ${ASSET_NAME} 已存在，跳過建置與上傳，下載資產並檢查 cask"
      ;;
    *)
      echo "無法辨識 ${TAG} 狀態：${RELEASE_STATE}" >&2; exit 1
      ;;
  esac
elif [[ "$RELEASE_STATE" == *"release not found"* ]] || [[ "$RELEASE_STATE" == *"Not Found"* ]]; then
  RELEASE_STATE="none"
else
  echo "查詢 GitHub Release ${TAG} 失敗：${RELEASE_STATE}" >&2; exit 1
fi

git -C "$TAP" fetch -q origin
if [[ -n "$(git -C "$TAP" status --porcelain)" ]] || [[ "$(git -C "$TAP" rev-parse HEAD)" != "$(git -C "$TAP" rev-parse '@{u}')" ]]; then
  echo "tap（${TAP}）有未提交改動或與遠端不同步，先處理" >&2; exit 1
fi

mkdir -p "$OUT"
if [[ "$RELEASE_STATE" == "ready" ]]; then
  gh release download "$TAG" -R "$REPO" -p "$ASSET_NAME" -D "$OUT" --clobber
  SHA=$(shasum -a 256 "$ZIP" | awk '{print $1}')
else
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
fi

if [[ -f "$CASK" ]] && grep -q "^  version \"${VERSION}\"$" "$CASK" && grep -q "^  sha256 \"${SHA}\"$" "$CASK"; then
  echo "${TAG}（${SHA}）與 cask 已完成，無需更新"
  exit 0
fi

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
