#!/usr/bin/env bash
# 啟動 Jarvis：whisper-server（:8081）＋中文語音（:8880）＋ claude-voice
#   ~/.jarvis/start.sh                 開伺服器並開始對話，離開 claude-voice 時自動關掉伺服器
#   ~/.jarvis/start.sh --servers-only  只開伺服器（跑 test-mac.mjs 用），Ctrl-C 關閉
# 兩個伺服器都只綁 127.0.0.1，外面連不到。
set -euo pipefail

J="$HOME/.jarvis"
CV="$HOME/.claude-voice"
WORKDIR="$HOME/Jarvis"
LOG="$J/logs"
WHISPER_URL="http://127.0.0.1:8081"
TTS_URL="http://127.0.0.1:8880/v1"
# 讓 whisper 傾向輸出繁體中文
WHISPER_PROMPT="${JARVIS_WHISPER_PROMPT:-以下是台灣國語的對話，使用繁體中文。}"

MODEL="$(node -p "require('$CV/config.json').providers.whispercpp.model")"
mkdir -p "$LOG" "$WORKDIR"

pids=()
cleanup() {
  # ${a[@]+...} 寫法：macOS 內建 bash 3.2 遇到空陣列＋set -u 會報錯
  for p in ${pids[@]+"${pids[@]}"}; do kill "$p" 2>/dev/null || true; done
}
trap cleanup EXIT
trap 'exit 130' INT TERM

up() { curl -s -o /dev/null --max-time 1 "$1"; }

if up "$WHISPER_URL"; then
  echo "• whisper-server 已經在跑"
else
  "$J/whisper.cpp/build/bin/whisper-server" -m "$CV/models/$MODEL" -l zh --prompt "$WHISPER_PROMPT" \
    -nt --host 127.0.0.1 --port 8081 >"$LOG/whisper.log" 2>&1 &
  pids+=("$!")
fi
if up "$TTS_URL"; then
  echo "• 中文語音已經在跑"
else
  node "$J/say-tts-server.mjs" >"$LOG/tts.log" 2>&1 &
  pids+=("$!")
fi

for _ in $(seq 1 60); do
  if up "$WHISPER_URL" && up "$TTS_URL"; then break; fi
  sleep 0.5
done
up "$WHISPER_URL" || { echo "✖ whisper-server 沒起來，看 $LOG/whisper.log" >&2; exit 1; }
up "$TTS_URL" || { echo "✖ 中文語音沒起來，看 $LOG/tts.log" >&2; exit 1; }
echo "✔ whisper-server（$MODEL）與中文語音（$(curl -s "$TTS_URL" | sed 's/^ok //')）都好了"

if [[ "${1:-}" == "--servers-only" ]]; then
  echo "  現在可以在另一個視窗跑：node ~/.jarvis/test-mac.mjs（這裡按 Ctrl-C 關閉伺服器）"
  wait
else
  cd "$WORKDIR"
  "$J/node_modules/.bin/claude-voice"
fi
