/**
 * 學校早鳥報名系統（saip.vnu.edu.tw/RevEnt）欄位偵察
 *
 * 只打開空白表單、讀出所有欄位與下拉選項（包含「選了 A 之後 B 會變」的連動選單），
 * 不會填寫、也不會送出任何資料。結果寫到 out/saip-form.json，並印在 log 裡。
 */
import { chromium } from 'playwright';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const TARGET = process.env.SAIP_URL || 'https://saip.vnu.edu.tw/RevEnt/';
const OUT = path.join(path.dirname(fileURLToPath(import.meta.url)), 'out');
fs.mkdirSync(OUT, { recursive: true });

const browser = await chromium.launch();
const page = await browser.newPage({ locale: 'zh-TW', viewport: { width: 1280, height: 1000 } });
const dialogs = [];
page.on('dialog', async d => { dialogs.push({ type: d.type(), message: d.message() }); await d.dismiss().catch(() => {}); });
const requests = [];
page.on('request', r => {
  if (['xhr', 'fetch', 'document'].includes(r.resourceType())) {
    requests.push({ method: r.method(), url: r.url(), type: r.resourceType(), post: (r.postData() || '').slice(0, 300) });
  }
});

const out = { url: TARGET, inspectedAt: new Date().toISOString() };
const resp = await page.goto(TARGET, { waitUntil: 'networkidle', timeout: 60000 });
out.status = resp && resp.status();
out.finalUrl = page.url();
out.title = await page.title();
out.frames = page.frames().map(f => f.url());

// 在頁面裡讀出所有欄位
function dumpFields() {
  const text = el => (el && el.innerText || '').replace(/\s+/g, ' ').trim();
  const prevText = el => {
    let n = el.previousSibling, s = '';
    while (n && s.length < 40) { s = (n.textContent || '') + s; n = n.previousSibling; }
    return s.replace(/\s+/g, ' ').trim().slice(-40);
  };
  return {
    forms: [...document.forms].map(f => ({ id: f.id, name: f.name, action: f.action, method: f.method, onsubmit: f.getAttribute('onsubmit') })),
    fields: [...document.querySelectorAll('input, select, textarea, button')].map((el, i) => ({
      i,
      tag: el.tagName.toLowerCase(),
      type: el.type,
      name: el.name,
      id: el.id,
      required: el.required || undefined,
      maxlength: el.maxLength > 0 ? el.maxLength : undefined,
      placeholder: el.placeholder || undefined,
      value: el.type === 'hidden' ? (el.value.length > 80 ? `(${el.value.length} 字)` : el.value)
        : ['checkbox', 'radio', 'submit', 'button'].includes(el.type) || el.tagName === 'BUTTON' ? el.value || text(el) : undefined,
      visible: !!(el.offsetWidth || el.offsetHeight) || undefined,
      disabled: el.disabled || undefined,
      onchange: el.getAttribute('onchange') || undefined,
      onclick: el.getAttribute('onclick') || undefined,
      label: (el.labels && el.labels[0] ? text(el.labels[0]) : '') || undefined,
      before: prevText(el) || undefined,
      row: text(el.closest('tr') || el.parentElement).slice(0, 120),
      options: el.tagName === 'SELECT' ? [...el.options].map(o => [o.value, o.text.trim()]) : undefined,
    })),
    captcha: [...document.images].map(i => i.src).filter(s => /captcha|valid|verify|checkcode|vcode/i.test(s)),
    scripts: [...document.scripts].map(s => s.src ? { src: s.src } : { inline: s.textContent.slice(0, 30000) }),
    text: document.body.innerText.slice(0, 6000),
  };
}

out.page = await page.evaluate(dumpFields);
fs.writeFileSync(path.join(OUT, 'saip-form.html'), await page.content());
await page.screenshot({ path: path.join(OUT, 'saip-form.png'), fullPage: true });

// 連動選單：每個下拉選單逐一選過每個選項，記下其他選單的選項怎麼變
const snapshot = () => page.evaluate(() => Object.fromEntries([...document.querySelectorAll('select')]
  .map((s, i) => [s.name || s.id || 'select#' + i, [...s.options].map(o => [o.value, o.text.trim()])])));
const selects = (out.page.fields.filter(f => f.tag === 'select' && f.visible));
out.cascades = {};
const started = Date.now();
for (const s of selects) {
  const key = s.name || s.id;
  if (!key) continue;
  const selector = s.id ? `[id="${s.id}"]` : `select[name="${s.name}"]`;
  const base = await snapshot();
  const changes = {};
  for (const [value, label] of s.options.slice(0, 60)) {
    if (!value || Date.now() - started > 12 * 60 * 1000) continue;
    try {
      await page.selectOption(selector, value, { timeout: 5000 });
      await page.waitForLoadState('networkidle', { timeout: 8000 }).catch(() => {});
      await page.waitForTimeout(300);
      const now = await snapshot();
      for (const [k, opts] of Object.entries(now)) {
        if (k === key) continue;
        if (JSON.stringify(opts) !== JSON.stringify(base[k])) (changes[k] = changes[k] || {})[label] = opts;
      }
    } catch (e) {
      (changes.__errors = changes.__errors || []).push(`${label}: ${e.message.split('\n')[0]}`);
    }
  }
  if (Object.keys(changes).length) out.cascades[key] = changes;
  // 回到乾淨的表單再測下一個選單
  await page.goto(TARGET, { waitUntil: 'networkidle', timeout: 60000 }).catch(() => {});
}

out.dialogs = dialogs;
out.requests = requests.filter((r, i, a) => a.findIndex(x => x.url === r.url && x.method === r.method) === i).slice(0, 80);
fs.writeFileSync(path.join(OUT, 'saip-form.json'), JSON.stringify(out, null, 1));
console.log('=====SAIP-JSON-BEGIN=====');
console.log(JSON.stringify(out, null, 1));
console.log('=====SAIP-JSON-END=====');
await browser.close();
