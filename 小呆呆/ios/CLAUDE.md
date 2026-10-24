# 小呆呆（交接給 Mac 本機的 Claude）

小呆呆是林祐凡（Rino）的語音助理。Rino 戴 AirPods、手機鎖著放口袋，喊「小呆呆」就醒，接著直接問。辦公室這台 Mac 用 Claude（claude CLI、Rino 的訂閱）想答案，再用講的回報。

完整的決定在：
- Notion Memory「小呆呆語音助理」
- GitHub da33/lin-yu-fan 的 `小呆呆/README.md`

**不要搞混：** `~/代碼程式/超級賈維斯/`（Mark-LV、Gemini Live 的舊賈維斯）是另一個東西，不要動，也不要拿來改。

## 現在做到哪（2026-10-24 晚上）

**第一版問答已經在 Rino 的 iPhone 17 Pro（iOS 27.2）上跑了。**

流程：喊「小呆呆」→ 叮 → 直接問 → 安靜約 1 秒自動送出（嘟）→ 從 AirPods 聽到美佳念的回答。

| 誰 | 做什麼 | 在哪 |
|---|---|---|
| iPhone App | 聽喚醒詞（sherpa-onnx）、判斷講完、自己把話轉成字（Apple SpeechTranscriber）、播回答 | 這個資料夾 `ios/` |
| 連線 | Tailscale；App 用 `ws://` 連 Mac 的 port 8787 | — |
| 辦公室 Mac | 問 Claude（Sonnet，只開 WebSearch、WebFetch）、美佳念成 WAV 傳回手機、存每句聲音 | `../mac/`，說明在 `../mac/README.md` |

- **實測（2026-10-24）**：
  - iPhone 講完 0.15 秒就轉好字，講完到聽到回答約 2.6 秒。
  - 要上網查的，3 秒內答不出來就先說「收到，我去做」，做好再叮一聲報告，約 20 秒。
- **第一版的限制**：只回答問題、上網查；不改檔案、不跑指令、不傳訊息；一次一句，不記得前面聊過什麼。
- **試用中**：「聽懂」原本在 Mac 上用 Qwen3-ASR，但這台 Mac 記憶體很緊（18 GB、swap 二十幾 GB），GPU 每幾分鐘出錯一次，服務 30 分鐘內自己重開 9 次。
  - Rino 選了改由 iPhone 聽，同時比較兩邊的準確度。
  - Mac 把每句聲音存在 `../mac/logs/audio/`，用 `uv run python compare_asr.py`（在 `../mac/`）比較。
  - iPhone 比較差的話，把 `../mac/config.json` 的 `asr` 改回 `"mac"`。
- **還沒做**：
  - 1 小時的誤醒和耗電測試（Rino 先跳過）。
  - AirPods 聽音樂音質比較。
  - 追問、看 Google 行事曆、動手做事（要先口頭確認）。
  - 美佳改在手機上念：每句可省約 0.85 秒。

## 這台 Mac 的狀況

- **Xcode 27.1** 已裝。開發者工具還指在指令列工具，所以下指令前要加 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`。想永久改的話，請 Rino 自己執行 `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`，密碼由 Rino 輸入。
- **Apple ID** 已在 Xcode 登入，用免費 Personal Team。Team ID 和這台 Mac 的 Tailscale 名稱都在 `Local.xcconfig`，不放上 GitHub；`setup-mac.sh` 會自動寫。
  - Xcode 27 登入後不會寫 `IDEProvisioningTeamByIdentifier`，要在 Signing 畫面選過一次 Team 才讀得到。
- **Tailscale**：Homebrew 版，以管理員身分開機自動跑（`sudo brew services start tailscale`，用 `--operator=mac` 登入，所以 `tailscale status` 不用 sudo）。
  - Homebrew 版不會幫 Mac 自己設 MagicDNS，在 Mac 上測試要用 IP（`tailscale ip -4`）。
  - 金鑰 2027-04-22 過期。
- **Claude 指令**用 Rino 的 Max 訂閱登入。過期的話，請 Rino 在終端機執行 `claude auth login`，帳號由 Rino 自己輸入。
- **小呆呆 Mac 服務**是開機自動啟動（launchd `tw.rino.xiaodaidai`），當掉會自己重開。改完程式在 `../mac/` 跑 `./install-service.sh`。
  - 每一輪的紀錄：`../mac/logs/turns.jsonl`
  - 服務本身的訊息：`../mac/logs/server.log`
- **系統睡眠**設成永不，可以一直開著。

## 常做的事（Rino 不想在 Xcode 裡點來點去，盡量用指令代勞）

手機 UDID 用 `xcrun devicectl list devices` 查（裝置名稱「Rino」）。下面的指令都要先 `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`。

- **重裝到手機**（免費 Apple ID 裝的 App 每 7 天過期，上次是 2026-10-24 裝的）：先請 Rino 把手機接上 Mac 並解鎖。
  ```
  xcodebuild -project XiaoDaiDai.xcodeproj -scheme XiaoDaiDai -destination 'platform=iOS,id=<UDID>' -allowProvisioningUpdates -derivedDataPath build build
  xcrun devicectl device install app --device <UDID> build/Build/Products/Debug-iphoneos/XiaoDaiDai.app
  ```
- **拉手機上的測試紀錄**（不用請 Rino 分享）：
  ```
  xcrun devicectl device copy from --device <UDID> --domain-type appDataContainer --domain-identifier tw.rino.xiaodaidai --source "Documents/小呆呆測試紀錄.csv" --destination <檔案>
  ```
- **看手機畫面**：`xcrun devicectl device capture screenshot --device <UDID> --destination <檔案>.png`
- **打開 App**：`xcrun devicectl device process launch --device <UDID> tw.rino.xiaodaidai`
- Rino 考慮過 Sideloadly、AltStore、SideStore，最後選 Xcode（2026-10-24）。測試期間不花錢，不要建議買 99 美元的開發者帳號。

## 第一次在新的 Mac 上裝（參考）

1. 確認 Xcode：`xcodebuild -version`。沒有的話，請 Rino 從 App Store 安裝；檔案很大，先講大概多大。出現 license 字樣時，請 Rino 打開 Xcode 按 Agree。
2. 程式不在 `~/代碼程式/小呆呆/ios` 的話，執行：
   `curl -fsSL https://raw.githubusercontent.com/da33/lin-yu-fan/main/%E5%B0%8F%E5%91%86%E5%91%86/ios/get.sh | bash`
   已經在的話，執行 `./setup-mac.sh`。兩個都會下載喚醒詞模型、用 XcodeGen 產生專案。
3. 請 Rino 自己在 Xcode 登入 Apple ID（Settings → Accounts），帳號密碼不要碰。再請 Rino 在 Signing & Capabilities 選一次 Team「(Personal Team)」，之後再跑一次 `./setup-mac.sh`，Team ID 就會記進 `Local.xcconfig`。
4. 手機接線並信任這台電腦，打開「設定 → 隱私權與安全性 → 開發者模式」。
5. 用上面的指令裝到手機。請 Rino 到「設定 → 一般 → VPN 與裝置管理」信任開發者。
6. Mac 服務：把 `小呆呆/mac/` 放到 `~/代碼程式/小呆呆/mac`，執行 `./install-service.sh`。Tailscale 和 `claude auth login` 都要 Rino 自己登入。

## 開發

- 專案由 `project.yml` 產生（XcodeGen）。不要直接改 `.xcodeproj`，改完 `project.yml` 再 `xcodegen generate`。
- App 最低版本是 iOS 26，因為要用新的語音辨識 API。
- **iPhone 測試**（模擬器；Mac 服務有開的話，會真的連過去問一次 Claude）：
  ```
  xcodebuild test -project XiaoDaiDai.xcodeproj -scheme XiaoDaiDai -destination 'platform=iOS Simulator,name=<模擬器名稱>' CODE_SIGNING_ALLOWED=NO
  ```
- **Mac 服務測試**：在 `../mac/` 跑 `uv run pytest -q`。
- 手機和 Mac 之間的約定寫在 `../mac/server.py` 開頭；兩邊要一起改。
- 程式改好要推回 GitHub da33/lin-yu-fan 的 `小呆呆/ios/`、`小呆呆/mac/`（main 分支），雲端那邊才接得上。這個 repo 是公開的：
  - 不要放 Tailscale 名稱、Team ID、錄下來的聲音。
  - `Local.xcconfig` 和 `mac/logs/` 都在 .gitignore 裡。

## Rino 的習慣

- 繁體中文、講白話、要簡短。
- 新功能先評估、討論，再動手；只改 Rino 要求的東西。
- 能免費就免費；下載大檔案前先講來源和大小。
- 不要開一堆終端機或瀏覽器視窗。
- 不讀、不印 API key 和密碼。
