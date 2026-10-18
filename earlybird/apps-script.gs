/**
 * 萬能早鳥報名 — Google Apps Script 後台
 * 把這個檔案貼到 Google 試算表的「擴充功能 → Apps Script」，
 * 部署為「網頁應用程式」：執行身分「我」、存取權「所有人」。
 * 部署後的網址貼到 index.html 的 CONFIG.endpoint。
 *
 * 兩種呼叫者：
 *  1. 學生端（index.html）POST 報名資料 → 新增一列，狀態「待處理」
 *  2. 自動登錄程式（bot/run.mjs）帶 BOT_TOKEN 取待處理資料、回寫登錄結果與截圖
 *     第一次使用前，在 Apps Script 編輯器執行一次 setupBotToken()，把記錄裡的 token 設成 GitHub Secret。
 */
const SHEET_NAME = '報名';
const HEADERS = ['收件時間', '受理編號', '姓名', '手機', 'LineID', 'Email', '身分證字號', '就讀學校', '科別', '班級', '年級', '統測群類', '有興趣的系', '工讀住宿', '特殊表現', '得知管道', '活動來源', '招生老師', '班導師', '個資同意', '狀態', '登錄時間', '錯誤訊息', '截圖'];
// 學生端送來的欄位 → 試算表欄名
const FIELD_OF = {
  ref: '受理編號', name: '姓名', phone: '手機', line: 'LineID', email: 'Email', idno: '身分證字號', school: '就讀學校',
  major: '科別', klass: '班級', grade: '年級', group: '統測群類', depts: '有興趣的系', needs: '工讀住宿', skills: '特殊表現',
  source: '得知管道', src: '活動來源', by: '招生老師', consent: '個資同意'
};
const SHOT_FOLDER = '早鳥登錄截圖';
const STALE_MINUTES = 30; // 「登錄中」超過這麼久沒回報，視為中斷，可以重來

function doPost(e) {
  const lock = LockService.getScriptLock();
  lock.waitLock(20000);
  try {
    const d = JSON.parse((e.postData && e.postData.contents) || '{}');
    if (d.action === 'claim' || d.action === 'result') {
      if (!tokenOk(d.token)) return out({ ok: false, error: 'unauthorized' });
      return out(d.action === 'claim' ? claim(d) : saveResult(d));
    }
    return out(addApplication(d));
  } catch (err) {
    return out({ ok: false, error: String(err) });
  } finally {
    lock.releaseLock();
  }
}

function doGet(e) {
  const p = (e && e.parameter) || {};
  if (p.action === 'pending') {
    if (!tokenOk(p.token)) return out({ ok: false, error: 'unauthorized' });
    return out(pending(p.mode === 'submit', Number(p.limit) || 10));
  }
  return out({ ok: true, service: 'vnu-earlybird' });
}

/* ---------- 學生報名 ---------- */
function addApplication(d) {
  const { sh, col } = sheet();
  // 同一受理編號只收一次（手機離線補送時可能重複）
  const last = sh.getLastRow();
  if (d.ref && last > 1) {
    const refs = sh.getRange(2, col['受理編號'], last - 1, 1).getValues().flat();
    if (refs.indexOf(d.ref) >= 0) return { ok: true, dup: true };
  }
  // 同手機或同身分證已登記過 → 狀態標「重複？」給人工判斷，不擋，也不自動登錄
  let status = '待處理';
  if (last > 1) {
    const phones = sh.getRange(2, col['手機'], last - 1, 1).getValues().flat().map(String);
    const ids = sh.getRange(2, col['身分證字號'], last - 1, 1).getValues().flat().map(String);
    if ((d.phone && phones.indexOf(String(d.phone)) >= 0) || (d.idno && ids.indexOf(String(d.idno)) >= 0)) status = '重複？';
  }
  const row = new Array(sh.getLastColumn()).fill('');
  row[col['收件時間'] - 1] = new Date();
  Object.keys(FIELD_OF).forEach(k => {
    if (d[k] == null) return;
    const v = String(d[k]);
    row[col[FIELD_OF[k]] - 1] = k === 'phone' ? "'" + v : v; // 手機保留開頭的 0
  });
  row[col['狀態'] - 1] = status;
  sh.appendRow(row);
  return { ok: true };
}

/* ---------- 自動登錄程式用 ---------- */
function pending(submitMode, limit) {
  const { sh, col } = sheet();
  const last = sh.getLastRow();
  if (last < 2) return { ok: true, rows: [] };
  const values = sh.getRange(2, 1, last - 1, sh.getLastColumn()).getValues();
  const names = Object.keys(col);
  const wanted = submitMode ? ['待處理', '預演完成'] : ['待處理'];
  const now = Date.now();
  const rows = [];
  values.forEach((v, i) => {
    const status = v[col['狀態'] - 1];
    const at = v[col['登錄時間'] - 1];
    const stale = status === '登錄中' && at instanceof Date && now - at.getTime() > STALE_MINUTES * 60000;
    if (wanted.indexOf(status) < 0 && !stale) return;
    if (rows.length >= limit) return;
    const obj = { row: i + 2 };
    names.forEach(n => { const x = v[col[n] - 1]; obj[n] = x instanceof Date ? x.toISOString() : String(x); });
    rows.push(obj);
  });
  return { ok: true, rows };
}

// 開始登錄前先把這一列標成「登錄中」，避免兩個程式同時處理同一個人
function claim(d) {
  const { sh, col } = sheet();
  const ref = sh.getRange(d.row, col['受理編號']).getValue();
  if (ref !== d.ref) return { ok: false, error: 'row_moved' };
  const status = sh.getRange(d.row, col['狀態']).getValue();
  const at = sh.getRange(d.row, col['登錄時間']).getValue();
  const stale = status === '登錄中' && at instanceof Date && Date.now() - at.getTime() > STALE_MINUTES * 60000;
  if (['待處理', '預演完成'].indexOf(status) < 0 && !stale) return { ok: false, error: 'not_pending', status };
  sh.getRange(d.row, col['狀態']).setValue('登錄中');
  sh.getRange(d.row, col['登錄時間']).setValue(new Date());
  return { ok: true };
}

function saveResult(d) {
  const { sh, col } = sheet();
  const ref = sh.getRange(d.row, col['受理編號']).getValue();
  if (ref !== d.ref) return { ok: false, error: 'row_moved' };
  sh.getRange(d.row, col['狀態']).setValue(d.status || '登錄失敗');
  sh.getRange(d.row, col['登錄時間']).setValue(new Date());
  sh.getRange(d.row, col['錯誤訊息']).setValue(d.message || '');
  if (d.screenshot) {
    const folders = DriveApp.getFoldersByName(SHOT_FOLDER);
    const folder = folders.hasNext() ? folders.next() : DriveApp.createFolder(SHOT_FOLDER);
    const blob = Utilities.newBlob(Utilities.base64Decode(d.screenshot), 'image/png', `${d.ref}-${d.status || 'result'}.png`);
    sh.getRange(d.row, col['截圖']).setValue(folder.createFile(blob).getUrl());
  }
  return { ok: true };
}

/* ---------- 共用 ---------- */
function sheet() {
  const ss = SpreadsheetApp.getActiveSpreadsheet();
  let sh = ss.getSheetByName(SHEET_NAME);
  if (!sh) sh = ss.insertSheet(SHEET_NAME);
  if (sh.getLastRow() === 0) {
    sh.appendRow(HEADERS);
    sh.getRange(1, 1, 1, HEADERS.length).setFontWeight('bold');
    sh.setFrozenRows(1);
  }
  // 舊版試算表缺的欄位補在最後面
  let head = sh.getRange(1, 1, 1, sh.getLastColumn()).getValues()[0];
  HEADERS.filter(h => head.indexOf(h) < 0).forEach(h => {
    sh.getRange(1, sh.getLastColumn() + 1).setValue(h).setFontWeight('bold');
  });
  head = sh.getRange(1, 1, 1, sh.getLastColumn()).getValues()[0];
  const col = {};
  head.forEach((h, i) => { if (h) col[h] = i + 1; });
  return { sh, col };
}

function tokenOk(t) {
  const real = PropertiesService.getScriptProperties().getProperty('BOT_TOKEN');
  return !!real && t === real;
}

// 在 Apps Script 編輯器手動執行一次，到「執行記錄」複製 token
function setupBotToken() {
  const token = Utilities.getUuid().replace(/-/g, '') + Utilities.getUuid().replace(/-/g, '');
  PropertiesService.getScriptProperties().setProperty('BOT_TOKEN', token);
  Logger.log('BOT_TOKEN = ' + token);
}

function out(obj) {
  return ContentService.createTextOutput(JSON.stringify(obj)).setMimeType(ContentService.MimeType.JSON);
}
