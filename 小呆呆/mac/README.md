# 小呆呆 Mac 服務

手機喊「小呆呆」之後，邊講邊把聲音傳到這台 Mac。這裡負責：
1. 拿到你講的話。平常用 iPhone 自己聽懂的字（Apple 內建的台灣中文辨識）。手機聽不了時，才用這台 Mac 的 Qwen3-ASR，跟語音輸入.app 同一個模型。
2. 問 Claude，用 Rino 的訂閱。
3. 用美佳念回去。
4. 每句的聲音存在 `logs/audio/`，之後用 `compare_asr.py` 比較 iPhone 和 Mac 哪邊聽得準。

Claude 3 秒內還沒寫出第一句，就先回「收到，我去做」，做好再把結果當報告送回手機。手機不在線上時，報告先留著，連回來再補送。

## 第一版的限制

- 只回答問題、上網查資料。
- 不改檔案、不跑指令、不傳訊息。
- 一次問一句，不記得前面聊過什麼。

## 檔案

| 檔案 | 做什麼 |
|---|---|
| `server.py` | 主程式：跟手機連線、一輪對話的流程（跟手機的約定寫在檔案開頭） |
| `ears.py` | Mac 的耳朵：Qwen3-ASR，轉成繁體（手機聽不了時才用） |
| `brain.py` | 大腦：`claude -p`，只開 WebSearch、WebFetch 兩個工具，不載入 MCP |
| `mouth.py` | 嘴巴：`say -v Meijia` 念成 WAV |
| `speech_text.py` | 把 Claude 寫的字切成一句一句、拿掉 Markdown |
| `config.json` | port、模型、聲音、「收到」要等幾秒 |
| `fake_phone.py` | 假裝是手機，在 Mac 上就能測整個流程（走 Mac 聽懂那條路） |
| `compare_asr.py` | 把存下來的聲音用 Qwen3-ASR 再聽一次，跟 iPhone 聽到的並排比較 |
| `install-service.sh` | 設成開機自動啟動（launchd） |

## 常用指令

```bash
./install-service.sh                        # 安裝或改完程式後重新啟動
uv run pytest -q                            # 測試（用假的耳朵、大腦、嘴巴）
uv run python fake_phone.py "一天有幾小時？"  # 實際問一句，--play 會播出來
tail -f logs/server.log                     # 看服務在做什麼
```

每一輪的紀錄在 `logs/turns.jsonl`，包括聽成什麼字、回答什麼，以及每一步花了幾秒：
- `asr_s`：聽懂
- `first_audio_s`：第一句念出來
- `total_s`：整輪

## 只有 Rino 的裝置連得進來

服務在 port 8787 等連線，只接受這台 Mac 自己和 Tailscale 裡的裝置，其他一律擋掉。

## 為什麼平常讓 iPhone 聽（2026-10-24 Rino 選的）

這台 Mac 跑語音模型時，GPU 每幾分鐘就出錯一次。macOS 會封鎖出錯的程式用 GPU，服務 30 分鐘內自己重開了 9 次。

改由 iPhone 聽之後：
- 服務平常完全不碰 GPU，只佔約 20 MB。
- 「每 10 秒碰一下模型」也停了：`config.json` 的 `asr` 設成 `"mac"` 才會開。

試用幾天後，用 `compare_asr.py` 比較兩邊的準確度。iPhone 比較差的話，把 `asr` 改回 `"mac"`。

## 這台 Mac 的特別狀況（Mac 自己聽時）

這台 Mac 記憶體只有 18 GB，平常還用掉二十幾 GB 的 swap。語音模型閒置一下就會被擠到硬碟：閒置 40 秒後，辨識一句要 20 秒。

目前的對策：
- 載入模型前先設好記憶體固定的上限，閒置 40 秒後降到約 3 秒。
- 手機一開始傳聲音，就先叫醒模型，把這段時間藏在你講話的時候。

這兩招只對閒置幾分鐘有效。閒置十幾分鐘後，模型幾乎整個被系統壓縮，第一句還是要約 7 秒。實測每 10 秒碰一下模型（每次約 0.4 秒）可以一直維持 0.3 秒，所以 Mac 自己聽時會每 10 秒碰一下。GPU 出錯時服務會自己結束，由 launchd 重開。

## Tailscale

這台 Mac 用 Homebrew 版 Tailscale，以管理員身分開機自動跑（`sudo brew services start tailscale`）。

- Mac 的位址用 `tailscale ip -4` 查。
- Homebrew 版不會幫 Mac 自己設好 MagicDNS，所以在 Mac 上測試要用 IP。手機用 Mac 的 Tailscale 名稱就可以（`setup-mac.sh` 會自動寫進 App）。
- 要升級 Tailscale 時，Homebrew 會要求先用 `sudo` 刪掉幾個屬於 root 的資料夾。
