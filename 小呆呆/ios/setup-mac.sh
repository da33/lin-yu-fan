#!/usr/bin/env bash
# 在辦公室 Mac 上準備小呆呆 App：裝 XcodeGen、下載喚醒詞模型、產生 Xcode 專案並打開
set -euo pipefail
cd "$(dirname "$0")"

if ! xcodebuild -version >/dev/null 2>&1; then
  echo "✖ 這台 Mac 還沒有 Xcode。到 App Store 搜尋「Xcode」免費下載（檔案很大），裝好打開一次再跑這個指令。" >&2
  exit 1
fi
echo "✔ $(xcodebuild -version | head -1)"

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
