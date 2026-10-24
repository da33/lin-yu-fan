# Jarvis 語音助理

戴 AirPods 用台灣國語跟辦公室的 Mac 對話。大腦只用 Claude（`claude` CLI，用訂閱、不用 API key），語音辨識和語音合成都在 Mac 本機、免費。私人工具。

目前是**第一步**：裝好 claude-voice 本機免費模式、把 whisper 換成多語言模型，測三件事——國語辨識準不準、插話會不會停、回應速度。

## 安裝（Mac，約 10 分鐘）

```bash
curl -fsSL https://raw.githubusercontent.com/da33/lin-yu-fan/main/jarvis/install-mac.sh | bash
```

需要先有：Homebrew、已登入的 `claude` CLI。腳本會：

1. `brew install sox ffmpeg cmake`（沒有 node 18+ 也會裝 node）
2. 從原始碼編 `whisper-server`（whisper.cpp v1.9.5，Metal 加速）——**Homebrew 的 whisper-cpp 編譯時把 server 關掉了**，claude-voice 說明書的 `brew install whisper-cpp` 已經不夠
3. 下載多語言模型 `ggml-large-v3-turbo-q8_0.bin`（約 0.9 GB）
4. 把 claude-voice 0.1.5、opencc-js 裝在 `~/.jarvis`（不動全域 npm）
5. 寫好 `~/.claude-voice/config.json`：語言 `zh`、模型 sonnet、中文版語音提示（像講電話、1–4 句、繁體、刪除／覆寫／上傳先確認）

重跑安全，裝好的步驟會跳過。

## 測試（約 8 分鐘）

1. 視窗 A：`~/.jarvis/start.sh --servers-only`
2. 視窗 B：`node ~/.jarvis/test-mac.mjs`
   - 唸 10 句辦公室指令（中英夾雜、數字、系名、「取消」）→ 算錯字率、看輸出是簡體還是繁體、量辨識耗時
   - 量環境噪音和「Jarvis 自己的聲音被麥克風收到多少」→ 決定之後能不能做「開口就打斷」
   - 量 Claude（sonnet、opus）常駐模式的首字時間、第一句時間，估算「講完 → 聽到第一個字」
3. 報告在 `~/Jarvis/jarvis-test-report.md`，整份貼回給 Claude。錄音留在 `~/Jarvis/test-audio/`，之後換辨識引擎用同一批錄音比。

直接跟 Jarvis 聊：`~/.jarvis/start.sh`（空白鍵＝插話／立刻送出，`t` 打字，`q` 離開）。

## 架構

```
AirPods 麥克風 → claude-voice ─→ whisper-server :8081（large-v3-turbo、-l zh、繁體提示詞）
                     │
                     ├─→ claude CLI（stream-json 常駐、--resume 同一對話串）
                     │
AirPods 耳機  ← 播放 ←─ 中文語音 :8880（say-tts-server.mjs → macOS「美佳」台灣國語）
```

兩個伺服器只綁 127.0.0.1。`say-tts-server.mjs` 模仿 Kokoro 的 `/v1/audio/speech` 介面，所以 claude-voice 一行都不用改。

## 雲端預先驗證（2026-10-24）

雲端容器碰不到 Mac，也連不到 Hugging Face，所以用同一組模型權重的 ONNX 版、真人錄音、claude-voice 原始碼和假的 Mac 環境先驗證：

| 項目 | 結果 |
|---|---|
| 國語辨識 whisper large-v3-turbo | 60 句真人朗讀（FLEURS，平均 10 秒）錯字率 **8.0%**；台灣口音錄音（BreezyVoice 範例）**1.5%** |
| 對照 SenseVoice-Small | 同樣 60 句 7.6%、台灣口音 3.1%，但**快 11 倍**（同一台 CPU：一句 0.45 秒 vs 5.2 秒） |
| 簡繁 | whisper 輸出字形不穩：60 句全簡體；同一段台灣錄音，全長輸出簡體、前 6.5 秒輸出繁體 → 需要 OpenCC 轉繁（只轉字形；「台灣用語」模式會把「對象」轉成「物件」） |
| 插話 | 連續模式下 Jarvis 講話時**麥克風是關的**，直接開口不會停；按空白鍵 0.3 ms 切斷（軟體端） |
| 中文切句 | 原版只認 `. ? !`，中文回覆串流途中**一句都切不出來**，要等 Claude 整段寫完才開始念（英文對照組正常） |
| Kokoro 念中文 | 原版設定用 Kokoro 反向辨識錯字率 32–60%，預設英文聲音 100%（聽不懂）→ 改用美佳 |
| 安裝流程 | 用假 macOS 環境把 `install-mac.sh`（含 `curl \| bash`）、`start.sh`、`test-mac.mjs` 跑完；whisper.cpp v1.9.5 用同樣指令編譯成功；claude-voice 真的管線串起設定檔＋whisper＋美佳橋接 |

雲端驗不到、要在 Mac 上量的：Metal 實際速度、Hugging Face 下載、美佳實際音質、AirPods 麥克風、你的網路到 Claude 的延遲。

## 已知限制（測完決定第二步）

- 中文要等整段寫完才念（切句沒認 `。！？`）
- 只能按空白鍵插話
- whisper 有時輸出簡體
- claude-voice 是用非互動的 `claude --print` 跑，沒有權限設定，執行指令、寫檔這類要授權的工具預計會被擋——「去 Mac 上把事情做完」要在第二步加資料夾白名單權限
- AirPods 麥克風一開，macOS 會把 AirPods 切成通話模式（播放音質變差）；測試報告會列出目前用哪個麥克風
- `claude-voice local` 會顯示 whisper「not installed」，可以忽略（server 在 `~/.jarvis/whisper.cpp` 裡，不在 PATH）

## 檔案

- `install-mac.sh`：一鍵安裝
- `start.sh`：啟動兩個伺服器＋claude-voice，離開時自動關閉
- `say-tts-server.mjs`：美佳語音橋接（自動挑 zh_TW 聲音：Premium > 優化 > 一般；`JARVIS_VOICE` 可指定）
- `test-mac.mjs`：三項測試＋報告

移除：`rm -rf ~/.jarvis ~/.claude-voice`（`~/Jarvis` 裡有錄音和報告，要不要留自己決定）
