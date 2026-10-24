# 林祐凡個人網站（da33.github.io/lin-yu-fan）

## 專案說明
萬能科技大學 時尚造型設計暨表演藝術系 專任講師／招生處多媒體秘書 林祐凡（Rino）的個人形象網站。
單一檔案架構：整站只有 index.html，所有照片以 base64 內嵌，push 即上線（GitHub Pages, main branch）。

## 設計系統
- 風格：黑底極簡 / Swiss-Brutalist，大字排版
- 色彩：黑 #0a0a0a、米白 #f5f4f0、橘紅 accent #ff3c00
- 字體：Inter + Noto Sans TC；基準字級 18px（維持大字，勿縮小）
- 區塊順序：Hero → About → Now(現任) → Experience(過往) → Performance(演出) → Music&DJ → Global(國際/活動) → Courses → Words(推薦) → Tools → Contact

## 內容規則（重要）
- 「現任」與「過往經歷」必須分開呈現：現任掛橘色 tag-now 標籤，過往掛年份 tag-past
- 不得出現「踢踢」兒童街舞培訓中心相關內容（已全數移除）
- 系所名稱一律用全名「時尚造型設計暨表演藝術系」
- 照片依主題放對應區塊：舞蹈照→演出區、DJ照→音樂區、製作/SWIPE→經歷區、舞台活動照→國際區
- AIA 寫全名「台灣人工智慧學校（AIA）」

## 現任頭銜（5）
專任講師、招生處多媒體秘書、中經院產業轉型跨域應用人才培育計畫顧問、台灣人工智慧學校（AIA）種子教師、教育部青年百億海外圓夢基金計畫（TGPI）委員

## 聯絡資訊
rino1133@gmail.com / IG @rinolin1133 / 0953-032-362 / LINE rinolin

## 其他工具（子資料夾）
- `earlybird/`：早鳥報名學生端
- `flight/`：東京搶票作戰室（私人工具，noindex）。只收航空公司官網的原生特價，不放 Trip.com、Kiwi 等第三方。`trip-grab.user.js` 是自動駕駛搶票的 Tampermonkey 腳本，改版記得把 `@version` 和 `VERSION` 加一；`sales.json` 是特價雷達排程（排程任務每天 07:51、20:51 更新，欄位見 flight/README.md）
- `小呆呆/`：小呆呆語音助理（私人工具，原名 Jarvis，舊賈維斯已放棄）。喊「小呆呆」喚醒，iPhone App 聽／傳／播，辦公室 Mac 用 Claude（claude CLI、訂閱）執行。目前在評估階段：新專案先評估討論再動手，最新決定在 Notion Memory「小呆呆語音助理」，評估紀錄見 小呆呆/README.md。資料夾裡的 install-mac.sh 等是第一輪 claude-voice 舊方案，不要叫使用者執行。給使用者動手的步驟要先在雲端驗證
- `idgen/`：身分證字號產生器＋報名表測試資料（加密、白名單通行碼）。repo 裡只有加密檔，改版或增刪白名單用 `node idgen/build.mjs`（見 idgen/README.md）；主密碼向使用者索取，絕不寫入任何檔案或 commit

## 慣例
- 使用者偏好：直接執行、成品導向、少問多做；回覆用繁體中文
- 修改後直接 commit + push 到 main（Pages 自動部署）
