#!/usr/bin/env bash
# 在辦公室 Mac 上準備小呆呆 App：裝 XcodeGen、下載喚醒詞模型、產生 Xcode 專案並打開
set -euo pipefail
cd "$(dirname "$0")"

# 找 Xcode：很多 Mac 的開發者工具還指在「指令列工具」，xcodebuild 會說找不到 Xcode。
# 這時直接指定 /Applications 裡的 Xcode（只對這次有效，不用輸入密碼）
XCODE_APPS_GLOB="${XCODE_APPS_GLOB:-/Applications/Xcode*.app}"
if ! xcodebuild -version >/dev/null 2>&1; then
  # shellcheck disable=SC2086 # 故意不加引號，讓萬用字元展開
  for app in $XCODE_APPS_GLOB; do
    if [[ -d "$app/Contents/Developer" ]]; then
      export DEVELOPER_DIR="$app/Contents/Developer"
      break
    fi
  done
fi
if ! version="$(xcodebuild -version 2>&1)"; then
  if grep -qi "license" <<<"$version"; then
    echo "✖ Xcode 還沒同意授權條款：打開 Xcode，按「Agree」，等它裝完元件，再貼一次同一行指令。" >&2
  elif [[ -n "${DEVELOPER_DIR:-}" ]]; then
    echo "✖ 找到 Xcode（$DEVELOPER_DIR）但還不能用：先打開 Xcode 一次、同意條款、勾 iOS 讓它裝完，再貼一次同一行指令。" >&2
    echo "  Xcode 說：$(head -2 <<<"$version")" >&2
  else
    echo "✖ /Applications 裡找不到 Xcode。到 App Store 搜尋「Xcode」免費下載（檔案很大），裝好打開一次再跑這個指令。" >&2
  fi
  exit 1
fi
echo "✔ $(head -1 <<<"$version")${DEVELOPER_DIR:+（$DEVELOPER_DIR）}"

if ! command -v xcodegen >/dev/null; then
  if [[ -x /opt/homebrew/bin/brew ]]; then eval "$(/opt/homebrew/bin/brew shellenv)"; fi
  echo "↓ 安裝 XcodeGen（用來產生 Xcode 專案）…"
  brew install xcodegen
fi

./fetch-model.sh

# 記住你在 Xcode 選過的 Apple ID（Team），重新產生專案也不用再選
team="$(grep -m1 -oE 'DEVELOPMENT_TEAM = [A-Z0-9]+' XiaoDaiDai.xcodeproj/project.pbxproj 2>/dev/null | awk '{print $3}' || true)"
if [[ -n "$team" ]]; then
  echo "DEVELOPMENT_TEAM = $team" >Local.xcconfig
else
  touch Local.xcconfig
fi

xcodegen generate --quiet
echo "✔ Xcode 專案好了，正在打開…"
open XiaoDaiDai.xcodeproj
