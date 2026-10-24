#!/usr/bin/env bash
# Jarvis 第一步：在 Mac 安裝 claude-voice 本機免費模式
#   語音辨識：whisper.cpp + 多語言模型 large-v3-turbo（Metal 加速）
#   中文語音：macOS 內建台灣國語「美佳」（取代原本念不好中文的 Kokoro）
#   大腦：你已登入的 claude CLI（用訂閱，不用 API key）
#
# 用法：curl -fsSL https://raw.githubusercontent.com/da33/lin-yu-fan/main/jarvis/install-mac.sh | bash
# 重跑安全：已經裝好的步驟會跳過。全部裝在 ~/.jarvis，不動系統的全域 npm。
set -euo pipefail

BASE_URL="${JARVIS_BASE_URL:-https://raw.githubusercontent.com/da33/lin-yu-fan/main/jarvis}"
JARVIS_HOME="$HOME/.jarvis"
WORKDIR="$HOME/Jarvis"
CV_HOME="$HOME/.claude-voice"
WHISPER_TAG="v1.9.5"
WHISPER_MODEL="${JARVIS_WHISPER_MODEL:-ggml-large-v3-turbo-q8_0.bin}"
CLAUDE_VOICE_VERSION="0.1.5"
OPENCC_VERSION="1.4.2"

SELF="${BASH_SOURCE[0]:-}"

step() { printf '\n\033[1;35m▶ %s\033[0m\n' "$*"; }
ok() { printf '  \033[32m✔\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m⚠ %s\033[0m\n' "$*"; }
die() {
  printf '  \033[31m✖ %s\033[0m\n' "$*"
  exit 1
}

main() {
  [[ "$(uname -s)" == Darwin ]] || die "這支腳本只給 Mac 用"
  [[ "$(uname -m)" == arm64 ]] || warn "不是 Apple Silicon，whisper 會慢很多"

  step "1/7 檢查必備工具"
  xcode-select -p >/dev/null 2>&1 || {
    xcode-select --install >/dev/null 2>&1 || true
    die "先完成跳出視窗的「指令列開發者工具」安裝，裝好再重跑這行指令"
  }
  if ! command -v brew >/dev/null && [[ -x /opt/homebrew/bin/brew ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  fi
  command -v brew >/dev/null || die "需要 Homebrew：到 https://brew.sh 複製那行指令裝好，再重跑"
  command -v claude >/dev/null || die "找不到 claude 指令（Claude Code）。先裝好並登入：https://claude.com/claude-code"
  ok "指令列開發者工具、Homebrew、claude $(claude --version 2>/dev/null | head -1)"

  step "2/7 安裝 sox（錄音）、ffmpeg（播放）、cmake（編譯）、node"
  pkgs=(sox ffmpeg cmake)
  if ! command -v node >/dev/null || [[ "$(node -p 'process.versions.node.split(".")[0]')" -lt 18 ]]; then
    pkgs+=(node)
  fi
  brew install "${pkgs[@]}"
  ok "node $(node -v)、$(sox --version | head -1)"

  step "3/7 編譯 whisper-server（Homebrew 的 whisper-cpp 已不附 server，要自己編，約 2 分鐘）"
  WHISPER_DIR="$JARVIS_HOME/whisper.cpp"
  WHISPER_BIN="$WHISPER_DIR/build/bin/whisper-server"
  mkdir -p "$JARVIS_HOME"
  if [[ -x "$WHISPER_BIN" ]]; then
    ok "已經編好：$WHISPER_BIN"
  else
    rm -rf "$WHISPER_DIR"
    git clone --depth 1 --branch "$WHISPER_TAG" https://github.com/ggml-org/whisper.cpp.git "$WHISPER_DIR"
    cmake -S "$WHISPER_DIR" -B "$WHISPER_DIR/build" -DCMAKE_BUILD_TYPE=Release \
      -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_SERVER=ON
    cmake --build "$WHISPER_DIR/build" -j "$(sysctl -n hw.ncpu)" --config Release --target whisper-server
    [[ -x "$WHISPER_BIN" ]] || die "whisper-server 編譯失敗，把上面的錯誤訊息貼給 Claude"
    ok "編好了（Metal 加速）"
  fi

  step "4/7 下載 whisper 多語言模型 $WHISPER_MODEL（約 0.9 GB）"
  mkdir -p "$CV_HOME/models"
  MODEL_PATH="$CV_HOME/models/$WHISPER_MODEL"
  if [[ -s "$MODEL_PATH" ]]; then
    ok "已經有了"
  else
    curl -fL --retry 3 -o "$MODEL_PATH.part" \
      "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$WHISPER_MODEL"
    mv "$MODEL_PATH.part" "$MODEL_PATH"
    ok "下載完成"
  fi

  step "5/7 安裝 claude-voice $CLAUDE_VOICE_VERSION 與 Jarvis 檔案"
  SRC_DIR=""
  if [[ -n "$SELF" && -f "$(dirname "$SELF")/say-tts-server.mjs" ]]; then
    SRC_DIR="$(cd "$(dirname "$SELF")" && pwd)"
  fi
  for f in say-tts-server.mjs test-mac.mjs start.sh; do
    if [[ -n "$SRC_DIR" ]]; then
      cp "$SRC_DIR/$f" "$JARVIS_HOME/$f"
    else
      curl -fsSL "$BASE_URL/$f" -o "$JARVIS_HOME/$f"
    fi
  done
  chmod +x "$JARVIS_HOME/start.sh"
  [[ -f "$JARVIS_HOME/package.json" ]] || echo '{ "name": "jarvis-local", "private": true }' >"$JARVIS_HOME/package.json"
  npm install --prefix "$JARVIS_HOME" --no-audit --no-fund \
    "@aayushdebugging/claude-voice@$CLAUDE_VOICE_VERSION" "opencc-js@$OPENCC_VERSION"
  ok "$("$JARVIS_HOME/node_modules/.bin/claude-voice" version 2>/dev/null | tail -1)"

  step "6/7 檢查台灣國語語音"
  voices="$(say -v '?' 2>/dev/null || true)"
  if grep -q 'zh_TW' <<<"$voices"; then
    ok "有：$(grep 'zh_TW' <<<"$voices" | sed -E 's/ +zh_TW.*//' | awk 'NR > 1 { printf "、" } { printf "%s", $0 }')"
  else
    warn "還沒有台灣國語語音。到「系統設定 → 輔助使用 → 朗讀內容 → 系統聲音 → 管理聲音」，"
    warn "勾「中文（台灣）→ 美佳」（有「優化」版就選優化版，比較自然），下載完再跑測試。"
  fi

  step "7/7 設定 claude-voice（中文、本機、台灣國語語音）"
  mkdir -p "$WORKDIR"
  WHISPER_MODEL="$WHISPER_MODEL" CV_HOME="$CV_HOME" node --input-type=module <<'NODE'
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
const path = `${process.env.CV_HOME}/config.json`;
let cfg = {};
try { cfg = JSON.parse(readFileSync(path, 'utf8')); } catch {}
const voicePrompt = [
  '你的回覆會用語音念給使用者聽，這是即時語音對話，請像講電話一樣回答。',
  '一律使用台灣繁體中文和台灣慣用語，口語、自然，先講結論，通常 1 到 4 句。',
  '每句簡短，用全形標點（，。？！）收尾，讓每一句可以邊寫邊念。',
  '不要用條列、表格、程式碼、網址或 Markdown 符號；需要長內容時存成檔案，只告訴使用者檔名。',
  '使用者的話是語音辨識的結果，可能有同音錯字，請依上下文理解；真的不確定就用一句話確認。',
  '刪除、覆寫檔案或對外上傳之前，一定先口頭確認。',
].join('');
cfg = {
  ...cfg,
  stt: 'whispercpp',
  tts: 'kokoro', // 走 Kokoro 的介面，實際由 say-tts-server.mjs 用「美佳」發聲
  voice: 'zf_xiaoxiao',
  language: 'zh',
  model: cfg.model || 'sonnet',
  pushToTalk: false,
  streamSpeech: true,
  voicePrompt,
  providers: {
    ...(cfg.providers || {}),
    whispercpp: { baseUrl: 'http://127.0.0.1:8081', model: process.env.WHISPER_MODEL },
    kokoro: { baseUrl: 'http://127.0.0.1:8880/v1', model: 'kokoro', voice: 'zf_xiaoxiao' },
  },
};
mkdirSync(process.env.CV_HOME, { recursive: true });
writeFileSync(path, JSON.stringify(cfg, null, 2) + '\n');
NODE
  ok "設定檔：$CV_HOME/config.json"

  printf '\n\033[1;32m全部裝好了。\033[0m 接下來：\n'
  printf '  1. 戴上 AirPods，開一個終端機視窗執行：  ~/.jarvis/start.sh --servers-only\n'
  printf '  2. 再開一個終端機視窗執行測試（約 8 分鐘）：node ~/.jarvis/test-mac.mjs\n'
  printf '  3. 想直接跟 Jarvis 聊：關掉第 1 步的視窗，執行  ~/.jarvis/start.sh\n'
  printf '  第一次錄音時 macOS 會問「終端機」能不能用麥克風，請按允許。\n'
}

# 整支包在 main 裡：用 curl | bash 執行時，bash 會先讀完整支腳本才開始跑
main "$@"
