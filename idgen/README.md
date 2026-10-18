# 身分證字號產生器（白名單）

產生符合規則的假身分證字號，以及招生報名表的逐項測試資料（含故意做錯的欄位），給程式教學和測試報名系統用。

- 線上網址：`https://da33.github.io/lin-yu-fan/idgen/`
- 開啟後要輸入通行碼，只有白名單裡的人能用。

## 白名單怎麼運作

- 頁面內容用 AES-GCM 加密後才放上 GitHub，repo 裡沒有明文原始檔。沒有通行碼的人只看得到解鎖畫面，原始碼裡也讀不到內容。
- 每個人一組通行碼，由「主密碼 + 名字」算出來。只要有主密碼，就能重新列出所有人的通行碼。
- 主密碼只有管理者自己保存，**不能寫進這個 repo 的任何檔案**。
- 移出白名單時會一併換掉內容金鑰，被移出的人原本的通行碼和「記住這台裝置」都會失效。

## 管理指令（在 repo 根目錄執行）

```bash
export IDGEN_MASTER='主密碼'

node idgen/build.mjs list                  # 列出白名單和每個人的通行碼
node idgen/build.mjs add 王老師 陳主任      # 加人
node idgen/build.mjs remove 王老師         # 移除
node idgen/build.mjs export /tmp/src.html  # 解密取回頁面原始檔（要改版時用）
node idgen/build.mjs update /tmp/src.html  # 換成改好的新版，白名單不變
```

每次執行後 commit 並 push `idgen/index.html`，GitHub Pages 就會更新。

加上 `IDGEN_FRAGMENT=輸出路徑` 會另外產生一份給 Claude Artifact 發布用的版本（同一份白名單、同一組通行碼）。

## 限制

- 拿到通行碼的人可以把通行碼轉給別人；發現時把那個人移出白名單即可。
- 已經解鎖的人可以自己存下畫面或內容，這是任何網頁都擋不住的。
