#!/usr/bin/env bash
# 把小呆呆服務設成開機自動啟動（launchd）；當掉會自己重開。改過程式後再跑一次就會重新啟動。
set -euo pipefail
cd "$(dirname "$0")"
HERE="$(pwd)"
LABEL=tw.rino.xiaodaidai
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

if ! command -v uv >/dev/null; then
  echo "✖ 找不到 uv：先執行 curl -LsSf https://astral.sh/uv/install.sh | sh" >&2
  exit 1
fi
uv sync --quiet
mkdir -p logs "$HOME/Library/LaunchAgents"

# ProcessType=Interactive：不要被系統當成背景雜事降速
cat >"$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$HERE/.venv/bin/python</string>
    <string>$HERE/server.py</string>
  </array>
  <key>WorkingDirectory</key><string>$HERE</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>ProcessType</key><string>Interactive</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>$HOME/.npm-global/bin:$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    <key>LANG</key><string>zh_TW.UTF-8</string>
  </dict>
  <key>StandardOutPath</key><string>$HERE/logs/server.log</string>
  <key>StandardErrorPath</key><string>$HERE/logs/server.log</string>
</dict>
</plist>
EOF

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
# 舊的要真的關掉才能再啟動，不然會出現 Input/output error
for _ in $(seq 1 20); do
  launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || break
  sleep 0.5
done
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "✔ 小呆呆服務啟動了（開機會自己跑）。紀錄在 $HERE/logs/server.log"
