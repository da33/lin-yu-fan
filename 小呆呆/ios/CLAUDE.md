# 小呆呆 iPhone App（交接給 Mac 本機的 Claude）

小呆呆是林祐凡（Rino）的語音助理。戴 AirPods、手機鎖著放口袋，喊「小呆呆」就醒；之後由辦公室這台 Mac 用 Claude（claude CLI、Rino 的訂閱）把事情做完，再用講的回報。
完整的決定在 Notion Memory「小呆呆語音助理」，以及 GitHub da33/lin-yu-fan 的 `小呆呆/README.md`。

**不要搞混：** `~/代碼程式/超級賈維斯/`（Mark-LV、Gemini Live 的舊賈維斯）是另一個東西，不要動，也不要拿來改。

## 現在做到哪（2026-10-24）

- 這個資料夾是**第一個測試 App**，只測喚醒詞：鎖屏喊「小呆呆」就叮一聲，並記錄電量、被打斷和自動恢復。還不會回答問題，也還不會連到 Mac。
- 喚醒詞用 sherpa-onnx 中文關鍵詞偵測（Swift 套件 2.0.0），模型由 `fetch-model.sh` 下載，關鍵詞寫在 `Model/keywords.txt`，靈敏度預設「標準」（門檻 0.15、加權 1.5）。
- 雲端驗證過：
  - 16 kHz、48 kHz 都叫得醒，相近的話不會誤醒。
  - GitHub Actions（`.github/workflows/xiaodaidai-ios.yml`，Xcode 26.6）：iPhone 模擬器 4 個單元測試全過，實機版（不簽名）編譯成功。
- **還沒在實機上跑過。**

## 在這台 Mac 上要做的（Rino 在旁邊，一步一步來）

1. 確認 Xcode：`xcodebuild -version`。如果沒有，請 Rino 從 App Store 安裝。檔案很大，先告訴他大概多大再開始。
2. 程式還不在 `~/代碼程式/小呆呆/ios` 的話，執行：
   `curl -fsSL https://raw.githubusercontent.com/da33/lin-yu-fan/main/%E5%B0%8F%E5%91%86%E5%91%86/ios/get.sh | bash`
   已經在的話，執行 `./setup-mac.sh`。這兩個都會下載模型、用 XcodeGen 產生專案、打開 Xcode。
3. 請 Rino 自己在 Xcode 登入 Apple ID（Settings → Accounts）。帳號密碼不要碰。
4. 手機接線並信任這台電腦，打開「設定 → 隱私權與安全性 → 開發者模式」。
5. **其餘盡量由你用指令代勞，Rino 不想在 Xcode 裡點來點去：**
   - 找 Personal Team 的 Team ID：例如 `defaults read com.apple.dt.Xcode IDEProvisioningTeamByIdentifier`，或請 Rino 看 Xcode 的 Signing 畫面。
   - 把 Team ID 寫進 `Local.xcconfig`（`DEVELOPMENT_TEAM = XXXXXXXXXX`），再執行 `xcodegen generate`。
   - 用 `xcrun devicectl list devices` 找手機的 UDID。
   - 編譯：`xcodebuild -project XiaoDaiDai.xcodeproj -scheme XiaoDaiDai -destination 'platform=iOS,id=<UDID>' -allowProvisioningUpdates -derivedDataPath build build`
   - 安裝：`xcrun devicectl device install app --device <UDID> build/Build/Products/Debug-iphoneos/XiaoDaiDai.app`
   - 指令不行時，退回 Xcode：Signing & Capabilities 選 Team「(Personal Team)」，選手機按 ▶︎。
6. 手機「設定 → 一般 → VPN 與裝置管理」信任開發者，打開 App、允許麥克風。
7. 照 App 裡「怎麼測」做：
   - 喊 10 次看叮幾次。
   - 放著 1 小時看誤醒和耗電。
   - 開關「AirPods 高品質收音」比較聽音樂的音質。
8. Rino 按「分享測試紀錄」給你 CSV 後，算出：
   - 叫醒率
   - 誤醒次數
   - 每小時耗電
   - 被打斷後有沒有自己恢復

   用白話回報。

免費 Apple ID 裝的 App 每 7 天過期，回辦公室接上手機，用上面的編譯、安裝指令重裝就好。Rino 考慮過 Sideloadly、AltStore、SideStore，最後選 Xcode（2026-10-24）。測試期間不花錢，不要建議買 99 美元的開發者帳號。

## 開發

- 專案由 `project.yml` 產生（XcodeGen）。不要直接改 `.xcodeproj`，改完 `project.yml` 再 `xcodegen generate`。
- 模擬器測試：`xcodebuild test -project XiaoDaiDai.xcodeproj -scheme XiaoDaiDai -destination 'platform=iOS Simulator,name=<模擬器名稱>' CODE_SIGNING_ALLOWED=NO`
- 程式改好要推回 GitHub da33/lin-yu-fan 的 `小呆呆/ios/`（main 分支），雲端那邊才接得上。

## Rino 的習慣

- 繁體中文、講白話、要簡短。
- 新功能先評估、討論，再動手；只改他要求的東西。
- 能免費就免費；下載大檔案前先講來源和大小。
- 不要開一堆終端機或瀏覽器視窗。
- 不讀、不印 API key 和密碼。
