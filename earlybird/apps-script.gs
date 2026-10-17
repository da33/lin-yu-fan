/**
 * 萬能早鳥報名 — Google Apps Script 後台
 * 把這個檔案貼到 Google 試算表的「擴充功能 → Apps Script」，
 * 部署為「網頁應用程式」：執行身分「我」、存取權「所有人」。
 * 部署後的網址貼到 index.html 的 CONFIG.endpoint。
 */
const SHEET_NAME = '報名';
const HEADERS = ['收件時間', '受理編號', '姓名', '手機', 'Email', '身分證字號', '就讀學校', '年級', '科別／班級', '有興趣的系', '得知管道', '活動來源', '招生老師', '個資同意', '狀態', '登錄時間', '錯誤訊息', '截圖'];

function doPost(e) {
  const lock = LockService.getScriptLock();
  lock.waitLock(10000);
  try {
    const d = JSON.parse(e.postData.contents || '{}');
    const ss = SpreadsheetApp.getActiveSpreadsheet();
    let sh = ss.getSheetByName(SHEET_NAME);
    if (!sh) { sh = ss.insertSheet(SHEET_NAME); }
    if (sh.getLastRow() === 0) {
      sh.appendRow(HEADERS);
      sh.getRange(1, 1, 1, HEADERS.length).setFontWeight('bold');
      sh.setFrozenRows(1);
    }
    // 同一受理編號只收一次（手機離線補送時可能重複）
    if (d.ref && sh.getLastRow() > 1) {
      const refs = sh.getRange(2, 2, sh.getLastRow() - 1, 1).getValues().flat();
      if (refs.indexOf(d.ref) >= 0) return ok({ ok: true, dup: true });
    }
    // 同手機或同身分證已登記過 → 狀態標「重複？」給人工判斷，不擋
    let status = '待處理';
    if (sh.getLastRow() > 1) {
      const rows = sh.getRange(2, 4, sh.getLastRow() - 1, 3).getValues();
      if (rows.some(r => (d.phone && r[0] == d.phone) || (d.idno && r[2] == d.idno))) status = '重複？';
    }
    sh.appendRow([
      new Date(), d.ref || '', d.name || '', "'" + (d.phone || ''), d.email || '', d.idno || '',
      d.school || '', d.grade || '', d.klass || '', d.depts || '', d.source || '', d.src || '', d.by || '',
      d.consent || '', status, '', '', ''
    ]);
    return ok({ ok: true });
  } catch (err) {
    return ok({ ok: false, error: String(err) });
  } finally {
    lock.releaseLock();
  }
}

function doGet() {
  return ok({ ok: true, service: 'vnu-earlybird' });
}

function ok(obj) {
  return ContentService.createTextOutput(JSON.stringify(obj)).setMimeType(ContentService.MimeType.JSON);
}
