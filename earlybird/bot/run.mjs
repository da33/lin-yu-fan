/**
 * 早鳥報名自動登錄（中介工作流）
 *
 * 試算表「待處理」→ mapping.mjs 對應欄位 → 填學校早鳥系統 → 回寫狀態、訊息、截圖到試算表
 *
 * 環境變數：
 *   EARLYBIRD_API    Apps Script 網頁應用程式網址
 *   EARLYBIRD_TOKEN  Apps Script 的 BOT_TOKEN（執行 setupBotToken() 取得）
 *   BOT_MODE         dry-run（預設：填好、截圖，不按「申請」）或 submit（真的送出）
 *   BOT_LIMIT        一次最多處理幾筆（預設 10）
 *
 * 指令：
 *   node run.mjs           處理待處理資料
 *   node run.mjs --check   只查有幾筆待處理（給 GitHub Actions 決定要不要裝瀏覽器）
 *   node run.mjs --sample  用一筆假資料實際填一次學校表單（不送出），檢查欄位對應
 *
 * repo 是公開的，log 只印受理編號與狀態，不印任何個資。
 */
import fs from 'node:fs';
import { mapRow } from './mapping.mjs';

const API = process.env.EARLYBIRD_API;
const TOKEN = process.env.EARLYBIRD_TOKEN;
const MODE = process.env.BOT_MODE === 'submit' ? 'submit' : 'dry-run';
const LIMIT = Number(process.env.BOT_LIMIT) || 10;
const SAIP = process.env.SAIP_URL || 'https://saip.vnu.edu.tw/RevEnt/';

const TEXT_FIELDS = ['TX_Idno', 'TX_Cname', 'TX_bef_dept_name', 'TX_bef_class_name', 'TX_phone', 'TX_LineID', 'TX_VnuReferee', 'TX_BefReFeree'];
const SELECT_FIELDS = ['LB_GraduYear', 'LB_TestGroup', 'LB_DeptDesire1', 'LB_DeptDesire2', 'LB_DeptDesire3', 'LB_ReqPartTime', 'LB_Domitory', 'LB_InfoFrom'];

const firstLine = e => String((e && e.message) || e).split('\n')[0].slice(0, 200);

/* ---------- 試算表 API ---------- */
async function api(body) {
  const res = await fetch(API, { method: 'POST', headers: { 'Content-Type': 'text/plain;charset=utf-8' }, body: JSON.stringify({ token: TOKEN, ...body }) });
  const data = await res.json().catch(() => ({ ok: false, error: `HTTP ${res.status}` }));
  if (data.error === 'unauthorized') throw new Error('EARLYBIRD_TOKEN 不對，請重新執行 setupBotToken() 並更新 GitHub Secret');
  return data;
}
async function getPending() {
  const url = `${API}?action=pending&mode=${MODE}&limit=${LIMIT}&token=${encodeURIComponent(TOKEN)}`;
  const data = await (await fetch(url)).json();
  if (!data.ok) throw new Error('讀取待處理資料失敗：' + (data.error || '未知錯誤'));
  return data.rows;
}
async function report(r, status, message, screenshot) {
  const res = await api({ action: 'result', row: r.row, ref: r['受理編號'], status, message: message || '', screenshot: screenshot ? screenshot.toString('base64') : '' });
  console.log(`${r['受理編號']} → ${status}${res.ok ? '' : `（回寫失敗：${res.error}）`}`);
}

/* ---------- 填學校表單 ---------- */
// 縣市、學校、同意框會觸發整頁重新載入（ASP.NET postback），要等它載完
async function postback(page, action) {
  await Promise.all([page.waitForNavigation({ waitUntil: 'load', timeout: 30000 }), action()]);
}

async function fill(page, form) {
  await page.goto(SAIP, { waitUntil: 'load', timeout: 60000 });
  await postback(page, () => page.selectOption('#LB_District', { label: form.LB_District }));
  await postback(page, () => page.selectOption('#LB_DistrictSchoolName', { label: form.LB_DistrictSchoolName }));
  for (const k of TEXT_FIELDS) await page.fill('#' + k, form[k] || '');
  for (const k of SELECT_FIELDS) if (form[k]) await page.selectOption('#' + k, form[k]);
  for (const [i, v] of ['1', '2', '3'].entries()) await page.setChecked(`#CBL_SpecSkills_${i}`, form.CBL_SpecSkills.includes(v));
  if (form.CKB_Iagree && !(await page.isChecked('#CKB_Iagree'))) await postback(page, () => page.click('#CKB_Iagree'));

  // 重新載入後再讀一次，確認每一欄都是我們要的值
  const got = await page.evaluate(names => Object.fromEntries(names.map(n => [n, document.getElementById(n)?.value ?? null])),
    ['LB_DistrictSchoolName', 'TX_Bef_school_name', ...TEXT_FIELDS, ...SELECT_FIELDS]);
  const diff = [...TEXT_FIELDS, ...SELECT_FIELDS].filter(k => (form[k] || '') !== (got[k] || ''));
  if (got.LB_DistrictSchoolName !== form.LB_DistrictSchoolName || !got.TX_Bef_school_name) diff.push('高中職校名');
  if (form.CKB_Iagree && !(await page.isChecked('#CKB_Iagree'))) diff.push('個資同意');
  if (diff.length) throw new Error('填完後這些欄位的值不對：' + diff.join('、'));
  if (await page.isDisabled('#Btn_Apply')) throw new Error('「申請」按鈕沒有啟用');
  return got;
}

async function submit(page) {
  const dialogs = [];
  page.on('dialog', d => { dialogs.push(d.message()); d.accept().catch(() => {}); });
  await postback(page, () => page.click('#Btn_Apply')).catch(() => {}); // 有些系統只跳訊息框不換頁
  await page.waitForLoadState('networkidle', { timeout: 10000 }).catch(() => {});
  const text = await page.evaluate(() => document.body.innerText);
  const message = [...dialogs, ...text.split('\n').map(s => s.trim()).filter(s => /成功|完成|已報名|重複|錯誤|請|失敗|謝謝|感謝/.test(s))]
    .filter((s, i, a) => s && a.indexOf(s) === i).join(' / ').slice(0, 300);
  if (/已報名|重複|已存在|已申請/.test(message)) return { status: '已登錄過', message };
  if (/成功|完成|已收到|謝謝|感謝/.test(message) && !/錯誤|失敗/.test(message)) return { status: '已登錄', message };
  return { status: '需人工確認', message: message || '送出後沒有看到成功訊息，請看截圖確認' };
}

/* ---------- 主流程 ---------- */
async function launch() {
  const { chromium } = await import('playwright');
  return chromium.launch();
}

async function processRow(browser, r) {
  const claim = await api({ action: 'claim', row: r.row, ref: r['受理編號'] });
  if (!claim.ok) { console.log(`${r['受理編號']} → 略過（${claim.error}）`); return; }
  const { form, problems, notEligible } = mapRow(r);
  if (problems.length) return report(r, notEligible ? '不適用' : '需人工確認', problems.join('；'));

  const page = await browser.newPage({ locale: 'zh-TW', viewport: { width: 1100, height: 1400 } });
  try {
    await fill(page, form);
    if (MODE !== 'submit') {
      return report(r, '預演完成', '已填好但沒有按「申請」（預演模式），請看截圖確認', await page.screenshot({ fullPage: true }));
    }
    await api({ action: 'result', row: r.row, ref: r['受理編號'], status: '送出中', message: '已按「申請」，等待學校系統回應' });
    const result = await submit(page);
    await report(r, result.status, result.message, await page.screenshot({ fullPage: true }));
  } catch (e) {
    await report(r, '登錄失敗', '自動登錄出錯：' + firstLine(e), await page.screenshot({ fullPage: true }).catch(() => null));
  } finally {
    await page.close();
  }
}

const arg = process.argv[2];
if (arg === '--sample') {
  // 假資料，只填不送，用來確認欄位對應在真的學校表單上沒問題
  const sample = {
    受理編號: 'SAMPLE', 身分證字號: 'H223456788', 姓名: '測試王小明', 就讀學校: '中壢高中', 年級: '高三',
    科別: '美容科', 班級: '三年忠班', 手機: '0900000000', LineID: '', 統測群類: '13 家政群生活應用類',
    有興趣的系: '時尚造型設計暨表演藝術系 時尚造型組、化妝品應用與管理系', 工讀住宿: '需要住宿', 特殊表現: '乙級證照',
    招生老師: '林祐凡', 個資同意: '同意',
  };
  const { form, problems } = mapRow(sample);
  if (problems.length) { console.error('假資料對應失敗：' + problems.join('；')); process.exit(1); }
  const browser = await launch();
  const page = await browser.newPage({ locale: 'zh-TW', viewport: { width: 1100, height: 1400 } });
  const got = await fill(page, form);
  fs.mkdirSync('out', { recursive: true });
  await page.screenshot({ path: 'out/sample.png', fullPage: true });
  console.log('假資料填寫成功（沒有送出）。學校表單上的值：');
  console.log(JSON.stringify(got, null, 1));
  await browser.close();
} else {
  if (!API || !TOKEN) { console.error('缺少 EARLYBIRD_API 或 EARLYBIRD_TOKEN'); process.exit(1); }
  const rows = await getPending();
  if (arg === '--check') {
    console.log(`待處理 ${rows.length} 筆`);
    if (process.env.GITHUB_OUTPUT) fs.appendFileSync(process.env.GITHUB_OUTPUT, `pending=${rows.length}\n`);
  } else {
    console.log(`模式：${MODE === 'submit' ? '正式送出' : '預演（不送出）'}，待處理 ${rows.length} 筆`);
    if (rows.length) {
      const browser = await launch();
      for (const r of rows) await processRow(browser, r);
      await browser.close();
    }
  }
}
