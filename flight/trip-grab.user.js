// ==UserScript==
// @name         東京搶票助手 · Trip.com 限時秒殺
// @namespace    https://da33.github.io/lin-yu-fan/flight/
// @version      1.0.0
// @description  伺服器校時倒數；時間到自動盯盤、按下指定方案、沒開就重整；命中響鈴＋桌面通知。登入、驗證、付款由你本人完成。
// @author       Rino
// @match        https://*.trip.com/*
// @run-at       document-idle
// @noframes
// @grant        GM_getValue
// @grant        GM_setValue
// @grant        GM_notification
// @grant        unsafeWindow
// @downloadURL  https://da33.github.io/lin-yu-fan/flight/trip-grab.user.js
// @updateURL    https://da33.github.io/lin-yu-fan/flight/trip-grab.user.js
// ==/UserScript==

(() => {
  'use strict';

  // 三場秒殺（台灣時間）。東京是主戰場，沖繩那場拿來彩排。
  const PRESETS = [
    { id: 'tyo999', label: '10/27（二）12:00 東京 999', at: '2026-10-27 12:00:00', place: '東京|成田|羽田', price: '999' },
    { id: 'oka4999', label: '10/26（一）12:00 日航 沖繩 4,999（彩排）', at: '2026-10-26 12:00:00', place: '沖繩|那霸', price: '4999' },
    { id: 'kix6999', label: '10/29（四）12:00 星宇 大阪 6,999', at: '2026-10-29 12:00:00', place: '大阪|關西', price: '6999' },
  ];
  const DEFAULTS = {
    preset: 'tyo999', at: PRESETS[0].at, place: PRESETS[0].place, price: PRESETS[0].price,
    trip: '去 2027/1/17・回 2027/2/3', autoClick: true, autoReload: true, sameTab: true, pin: null,
  };
  const MAX_RELOADS = 25;
  const RELOAD_GAP = 4000;     // 重整後至少等 4 秒讓頁面載完，也避免被當機器人
  const FIRST_RELOAD = 1200;   // 開搶 1.2 秒還沒變就第一次重整
  const CLICK_DELAY = 150;     // 校時誤差約 ±0.1 秒，開搶後 0.15 秒才按，免得太早被打回
  const GIVE_UP_AFTER = 120000; // 開搶 2 分鐘後還沒進場就收手

  const WAIT_RE = /即將|未開始|尚未開|敬請期待|倒數|開搶提醒|提醒我|設定提醒|預約|準時開搶|coming\s*soon|not\s*started/i;
  const SOLD_RE = /售完|售罄|搶光|搶完|已結束|活動結束|已售|額滿|sold\s*out|ended/i;
  const BUY_RE = /搶購|立即|馬上|預訂|預定|訂購|購買|領取|領券|去搶|搶|去訂|book|buy|grab/i;
  const BLOCK_RE = /安全驗證|拖動滑塊|向右滑動|驗證碼|captcha|are\s*you\s*a\s*robot|請完成驗證/i;
  const BTN_SEL = 'button,a[href],[role="button"],[class*="btn" i],[class*="button" i]';
  const PRICEISH = /NT\$|TWD|\$|元|起|[?？]{2}/;

  // ---------- 儲存 ----------
  const load = (k, d) => { try { const v = GM_getValue(k); return v === undefined ? d : v; } catch (e) { return d; } };
  const save = (k, v) => { try { GM_setValue(k, v); } catch (e) { /* ignore */ } };
  let cfg = Object.assign({}, DEFAULTS, load('cfg', {}));
  let run = load('run', null); // { target, url, page, phase, reloads, clicks, drill }
  let logs = load('logs', []);

  // ---------- 時間 ----------
  const synced = load('sync', null); // { offset, err, at }
  let offset = synced ? synced.offset : 0; // 伺服器時間 − 本機時間（ms）
  let offsetErr = synced ? synced.err : null;
  const now = () => Date.now() + offset;
  const sleep = ms => new Promise(r => setTimeout(r, ms));
  const fmtTW = new Intl.DateTimeFormat('zh-TW', { timeZone: 'Asia/Taipei', hourCycle: 'h23', hour: '2-digit', minute: '2-digit', second: '2-digit' });
  const clock = t => fmtTW.format(t) + '.' + Math.floor((((t % 1000) + 1000) % 1000) / 100);
  function parseTaipei(s) {
    const m = String(s).trim().match(/^(\d{4})[-/](\d{1,2})[-/](\d{1,2})[ T](\d{1,2}):(\d{2})(?::(\d{2}))?$/);
    if (!m) return null;
    return Date.UTC(+m[1], +m[2] - 1, +m[3], +m[4] - 8, +m[5], +(m[6] || 0));
  }
  function countdown(ms) {
    const sign = ms < 0 ? '+' : '';
    ms = Math.abs(ms);
    const h = Math.floor(ms / 3600000), m = Math.floor(ms / 60000) % 60, s = Math.floor(ms / 1000) % 60, d = Math.floor(ms / 100) % 10;
    const pad = n => String(n).padStart(2, '0');
    return `${sign}${h > 99 ? h : pad(h)}:${pad(m)}:${pad(s)}.${d}`;
  }

  // 伺服器的 Date 標頭只到秒，所以每次取樣只知道「誤差落在某個 1 秒區間」；
  // 錯開相位多取幾次、把區間交集起來，就能縮到 0.1 秒左右。
  async function sample() {
    const t0 = Date.now();
    let res;
    try { res = await fetch(location.origin + '/favicon.ico?_ts=' + t0, { method: 'HEAD', cache: 'no-store', credentials: 'omit' }); } catch (e) { res = null; }
    if (!res || !res.headers.get('date')) res = await fetch(location.href, { method: 'HEAD', cache: 'no-store' });
    const t1 = Date.now();
    const S = Date.parse(res.headers.get('date'));
    if (!S) throw new Error('no date header');
    return { lo: S - t1, hi: S + 1000 - t0 };
  }
  let syncing = null;
  function syncClock(n) {
    if (!syncing) syncing = doSync(n).finally(() => { syncing = null; });
    return syncing;
  }
  async function doSync(n) {
    setStatus('⏱ 校時中…');
    let lo = -Infinity, hi = Infinity;
    const mids = [];
    for (let i = 0; i < n; i++) {
      try {
        const s = await sample();
        mids.push((s.lo + s.hi) / 2);
        lo = Math.max(lo, s.lo);
        hi = Math.min(hi, s.hi);
      } catch (e) { /* 單次失敗就跳過 */ }
      if (i < n - 1) await sleep(1137);
    }
    if (!mids.length) { log('校時失敗，先用本機時間'); return false; }
    if (lo <= hi) { offset = Math.round((lo + hi) / 2); offsetErr = Math.round((hi - lo) / 2); }
    else { mids.sort((a, b) => a - b); offset = Math.round(mids[mids.length >> 1]); offsetErr = 500; }
    save('sync', { offset, err: offsetErr, at: Date.now() });
    log(`校時完成：本機${offset >= 0 ? '慢' : '快'} ${(Math.abs(offset) / 1000).toFixed(2)} 秒（±${(offsetErr / 1000).toFixed(2)}）`);
    return true;
  }

  // 背景分頁的 setInterval 會被瀏覽器降速，改用 Worker 計時比較準。
  function startTicker(fn, ms) {
    let stop = null;
    const fallback = () => { const id = setInterval(fn, ms); stop = () => clearInterval(id); };
    try {
      const w = new Worker(URL.createObjectURL(new Blob([`setInterval(()=>postMessage(0),${ms})`], { type: 'text/javascript' })));
      w.onmessage = fn;
      w.onerror = () => { w.terminate(); fallback(); };
      stop = () => w.terminate();
    } catch (e) { fallback(); }
    return () => stop && stop();
  }

  // ---------- 找方案 ----------
  const norm = s => String(s || '').replace(/[\s,，]/g, '');
  const places = () => String(cfg.place || '').split(/[|｜、,，/\s]+/).filter(Boolean);
  function priceRe() {
    const p = String(cfg.price || '').replace(/\D/g, '');
    return p ? new RegExp('(?<![\\d.])' + p + '(?!\\d)') : null;
  }
  function visible(el) {
    if (!el || !el.getBoundingClientRect) return false;
    const r = el.getBoundingClientRect();
    if (r.width < 2 || r.height < 2) return false;
    const cs = getComputedStyle(el);
    return cs.visibility !== 'hidden' && cs.display !== 'none' && +cs.opacity > 0.05;
  }
  function isDisabled(el) {
    return !!el.disabled || el.getAttribute('aria-disabled') === 'true' || /disabl|gray|grey|inactive|forbid/i.test(el.getAttribute('class') || '');
  }
  function findButton(card) {
    const list = [...card.querySelectorAll(BTN_SEL)].filter(visible);
    const txt = e => norm(e.innerText);
    const short = e => { const t = txt(e); return t.length > 0 && t.length <= 24; };
    return list.find(e => short(e) && BUY_RE.test(txt(e)) && !WAIT_RE.test(txt(e)))
      || list.find(e => short(e) && (WAIT_RE.test(txt(e)) || SOLD_RE.test(txt(e)) || BUY_RE.test(txt(e))))
      || (card.matches(BTN_SEL) ? card : null)
      || card.closest('a[href]')
      || list[0] || null;
  }
  function describe(card, btn, via) {
    const pr = priceRe();
    const text = norm(card.innerText);
    const bt = btn ? norm(btn.innerText) : '';
    const kind = !btn ? 'none'
      : bt.length <= 24 && BUY_RE.test(bt) && !WAIT_RE.test(bt) ? 'buy'
      : bt.length <= 24 && (WAIT_RE.test(bt) || SOLD_RE.test(bt)) ? 'state' : 'link';
    return { card, btn, via, text, bt, kind, hasPrice: pr ? pr.test(text) : false };
  }
  // 有價格 > 有搶購／倒數按鈕 > 看起來像價格卡 > 越小越精準（避免選到「東京自由行」這種導覽連結）
  const scoreOf = r => (r.hasPrice ? 1e5 : 0) + (r.kind === 'buy' || r.kind === 'state' ? 1e4 : 0) + (PRICEISH.test(r.text) ? 1e3 : 0) - r.text.length;

  let cached = null;
  function scanFull() {
    if (cfg.pin && cfg.pin.page === location.pathname) {
      const el = document.querySelector(cfg.pin.sel);
      if (el && visible(el)) {
        let card = el, ok = false;
        for (let i = 0; i < 7 && card && card !== document.body; i++) {
          const ct = card.innerText || '';
          if (ct.length > 600) break;
          if (places().some(p => ct.includes(p)) && ct.length > 8) { ok = true; break; }
          card = card.parentElement;
        }
        if (ok) return describe(card, el, 'pin');
      }
    }
    const pr = priceRe(), pl = places();
    if (!pl.length) return null;
    const tw = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
    let n, seen = 0, best = null, bestScore = -Infinity;
    const done = new Set();
    while ((n = tw.nextNode()) && seen < 60) {
      const v = n.nodeValue;
      if (!v || v.length > 300 || !pl.some(p => v.includes(p))) continue;
      const el = n.parentElement;
      if (!el || el.closest('#rino-grab-host') || !visible(el)) continue;
      seen++;
      let a = el, priced = null, withBtn = null;
      for (let depth = 0; a && a !== document.body && depth < 8; depth++, a = a.parentElement) {
        const t = a.innerText || '';
        if (t.length > 600) break;
        if (pr && pr.test(norm(t))) { priced = a; break; }
        if (!withBtn && (a.matches(BTN_SEL) || a.querySelector(BTN_SEL))) withBtn = a;
      }
      const card = priced || withBtn;
      if (!card || done.has(card)) continue;
      done.add(card);
      const r = describe(card, findButton(card), 'auto');
      const score = scoreOf(r);
      if (score > bestScore) { bestScore = score; best = r; }
    }
    return best;
  }
  function scan(full) {
    if (!full && cached && cached.card.isConnected && (!cached.btn || cached.btn.isConnected)) {
      const btn = cached.via === 'pin' ? cached.btn : findButton(cached.card);
      cached = describe(cached.card, btn, cached.via);
    } else {
      cached = scanFull();
    }
    return cached;
  }
  function judge(r) {
    if (!r) return 'notfound';
    const bt = r.bt.slice(0, 40);
    if (SOLD_RE.test(bt)) return 'soldout';
    if (r.btn && (WAIT_RE.test(bt) || isDisabled(r.btn))) return 'waiting';
    if (!r.hasPrice && WAIT_RE.test(r.text)) return 'waiting';
    if (r.hasPrice && SOLD_RE.test(r.text) && r.text.length < 160) return 'soldout';
    return r.hasPrice ? 'ready' : 'maybe';
  }
  const STATE_TEXT = {
    notfound: '❓ 找不到方案（檢查關鍵字，或用 🎯 指定按鈕）',
    waiting: '⏳ 找到方案：還沒開搶',
    maybe: '🟡 找到方案：價格還沒出現',
    ready: '🟢 找到方案：可以搶了',
    soldout: '⛔ 方案已售完',
  };

  let marked = [];
  function mark(r) {
    marked.reverse().forEach(([el, o, oo]) => { el.style.outline = o; el.style.outlineOffset = oo; });
    marked = [];
    if (!r) return;
    [[r.card, '4px solid #ff3c00'], [r.btn, '4px dashed #00c46a']].forEach(([el, style]) => {
      if (!el) return;
      marked.push([el, el.style.outline, el.style.outlineOffset]);
      el.style.outline = style;
      el.style.outlineOffset = '3px';
    });
  }

  // ---------- 點擊 ----------
  let openPatched = false;
  function patchOpen() {
    if (openPatched || !cfg.sameTab) return;
    openPatched = true;
    try {
      const w = typeof unsafeWindow !== 'undefined' ? unsafeWindow : window;
      const orig = w.open;
      // 沒有真人點擊時開新分頁會被擋，開搶前後改成在本頁開
      w.open = function (u, ...rest) {
        if (u && run && run.phase === 'armed') { location.assign(String(u)); return null; }
        return orig.call(this, u, ...rest);
      };
    } catch (e) { /* 有些環境改不了，沒關係 */ }
  }
  function fire(el) {
    const a = el.closest('a[href]');
    if (a && cfg.sameTab && a.target === '_blank' && /^https?:/.test(a.href)) { location.assign(a.href); return; }
    const r = el.getBoundingClientRect();
    const o = { bubbles: true, cancelable: true, composed: true, button: 0, clientX: r.left + r.width / 2, clientY: r.top + r.height / 2 };
    try { el.dispatchEvent(new PointerEvent('pointerdown', o)); } catch (e) { /* ignore */ }
    el.dispatchEvent(new MouseEvent('mousedown', o));
    try { el.dispatchEvent(new PointerEvent('pointerup', o)); } catch (e) { /* ignore */ }
    el.dispatchEvent(new MouseEvent('mouseup', o));
    el.click();
  }

  // ---------- 提醒 ----------
  let actx = null;
  function unlockAudio() {
    try { actx = actx || new (window.AudioContext || window.webkitAudioContext)(); actx.resume(); } catch (e) { /* ignore */ }
  }
  function beep(freqs) {
    if (!actx) return;
    let t = actx.currentTime;
    freqs.forEach(f => {
      if (f) {
        const o = actx.createOscillator(), g = actx.createGain();
        o.type = 'square'; o.frequency.value = f;
        g.gain.setValueAtTime(0.18, t); g.gain.exponentialRampToValueAtTime(0.001, t + 0.22);
        o.connect(g).connect(actx.destination); o.start(t); o.stop(t + 0.24);
      }
      t += 0.26;
    });
  }
  let flashTimer = null;
  function alarm(msg, loud) {
    log(msg);
    beep(loud ? [1320, 0, 1320, 0, 1760, 1760, 0, 1320, 0, 1320, 0, 1760, 1760] : [880, 0, 1320]);
    try { GM_notification({ title: '東京搶票助手', text: msg, timeout: 20000, highlight: true }); } catch (e) { /* ignore */ }
    try { const u = new SpeechSynthesisUtterance(msg.replace(/[^\p{L}\p{N}，。！ ]/gu, '')); u.lang = 'zh-TW'; u.rate = 1.15; speechSynthesis.speak(u); } catch (e) { /* ignore */ }
    clearInterval(flashTimer);
    const orig = document.title;
    let k = 0;
    flashTimer = setInterval(() => { document.title = (k++ % 2) ? orig : '🔥🔥 ' + msg; if (k > 40) { clearInterval(flashTimer); document.title = orig; } }, 600);
  }

  // ---------- 面板 ----------
  const host = document.createElement('div');
  host.id = 'rino-grab-host';
  host.style.cssText = 'position:fixed;right:16px;bottom:16px;z-index:2147483647;';
  const root = host.attachShadow({ mode: 'open' });
  root.innerHTML = `
<style>
  :host{all:initial}
  .p{width:340px;max-width:calc(100vw - 32px);background:#0a0a0a;color:#f5f4f0;border:2px solid #ff3c00;border-radius:14px;
     font:15px/1.45 Inter,"Noto Sans TC","PingFang TC","Microsoft JhengHei",system-ui,sans-serif;box-shadow:0 12px 40px rgba(0,0,0,.45);overflow:auto;max-height:calc(100vh - 32px)}
  .hd{position:sticky;top:0}
  .hd{display:flex;align-items:center;gap:8px;padding:10px 12px;background:#ff3c00;color:#0a0a0a;font-weight:800;letter-spacing:.02em;cursor:pointer}
  .hd b{flex:1}
  .bd{padding:12px}
  .min .bd{display:none}
  .clock{display:flex;justify-content:space-between;color:#b9b7b0;font-size:13px;font-variant-numeric:tabular-nums}
  .cd{font:800 40px/1.1 Inter,system-ui,sans-serif;font-variant-numeric:tabular-nums;letter-spacing:-.02em;margin:6px 0 2px}
  .cd.go{color:#ff3c00}
  .tg{font-size:13px;color:#b9b7b0}
  .st{margin:10px 0;padding:8px 10px;border-radius:10px;background:#1a1a1a;font-weight:600}
  .row{display:flex;flex-wrap:wrap;gap:6px}
  button{font:inherit;font-size:14px;font-weight:700;border:0;border-radius:10px;padding:9px 10px;cursor:pointer;background:#2a2a2a;color:#f5f4f0;flex:1 1 auto;min-height:40px}
  button:hover{background:#3a3a3a}
  button.arm{background:#ff3c00;color:#0a0a0a;flex-basis:100%;font-size:17px;min-height:48px}
  button.arm.on{background:#f5f4f0}
  details{margin-top:10px;border-top:1px solid #2a2a2a;padding-top:8px}
  summary{cursor:pointer;color:#b9b7b0;font-size:13px}
  label{display:block;font-size:12px;color:#b9b7b0;margin-top:8px}
  input[type=text],select{width:100%;box-sizing:border-box;margin-top:3px;padding:7px 8px;border-radius:8px;border:1px solid #333;background:#141414;color:#f5f4f0;font:inherit;font-size:14px}
  .ck{display:flex;gap:8px;align-items:center;color:#f5f4f0;font-size:14px}
  .ck input{width:18px;height:18px;accent-color:#ff3c00}
  .log{margin-top:10px;font:12px/1.5 ui-monospace,Menlo,Consolas,monospace;color:#8f8d87;max-height:96px;overflow:auto;white-space:pre-wrap}
  .pin{font-size:12px;color:#00c46a;margin-top:6px}
</style>
<div class="p">
  <div class="hd" id="hd"><b>✈︎ 東京搶票助手</b><span id="mini"></span><span>—</span></div>
  <div class="bd">
    <div class="clock"><span>伺服器 <b id="srv">--:--:--.-</b></span><span id="off"></span></div>
    <div class="cd" id="cd">--:--:--.-</div>
    <div class="tg" id="tg"></div>
    <div class="st" id="st">尚未武裝</div>
    <div class="row">
      <button class="arm" id="arm">⚔ 武裝（開搶前按一次）</button>
      <button id="test">🔍 測試掃描</button>
      <button id="pick">🎯 指定按鈕</button>
      <button id="drill">⏩ 30 秒演練</button>
      <button id="sync">⏱ 校時</button>
    </div>
    <div class="pin" id="pinInfo"></div>
    <details id="set">
      <summary>設定</summary>
      <label>場次<select id="preset"></select></label>
      <label>開搶時間（台灣時間）<input type="text" id="at" placeholder="2026-10-27 12:00:00"></label>
      <label>地點關鍵字（用 | 隔開）<input type="text" id="place"></label>
      <label>價格數字<input type="text" id="price" inputmode="numeric"></label>
      <label>你的行程（提醒用）<input type="text" id="trip"></label>
      <label class="ck"><input type="checkbox" id="autoClick">時間到自動點擊</label>
      <label class="ck"><input type="checkbox" id="autoReload">沒開搶就自動重整（最多 ${MAX_RELOADS} 次）</label>
      <label class="ck"><input type="checkbox" id="sameTab">新分頁改在本頁開（避免被擋）</label>
      <div class="row" style="margin-top:8px"><button id="unpin">清除指定按鈕</button></div>
    </details>
    <div class="log" id="log"></div>
  </div>
</div>`;
  const $ = id => root.getElementById(id);
  const panel = root.querySelector('.p');
  (document.body || document.documentElement).appendChild(host);
  if (load('min', false)) panel.classList.add('min');
  $('hd').onclick = () => { panel.classList.toggle('min'); save('min', panel.classList.contains('min')); };

  PRESETS.forEach(p => { const o = document.createElement('option'); o.value = p.id; o.textContent = p.label; $('preset').appendChild(o); });
  const o2 = document.createElement('option'); o2.value = 'custom'; o2.textContent = '自訂'; $('preset').appendChild(o2);
  function fillForm() {
    $('preset').value = cfg.preset; $('at').value = cfg.at; $('place').value = cfg.place; $('price').value = cfg.price; $('trip').value = cfg.trip;
    $('autoClick').checked = cfg.autoClick; $('autoReload').checked = cfg.autoReload; $('sameTab').checked = cfg.sameTab;
    $('pinInfo').textContent = cfg.pin ? `🎯 已指定：「${cfg.pin.label || '（無文字）'}」` : '';
  }
  function readForm() {
    cfg.at = $('at').value.trim(); cfg.place = $('place').value.trim(); cfg.price = $('price').value.trim(); cfg.trip = $('trip').value.trim();
    cfg.autoClick = $('autoClick').checked; cfg.autoReload = $('autoReload').checked; cfg.sameTab = $('sameTab').checked;
    save('cfg', cfg); cached = null;
  }
  $('preset').onchange = () => {
    const p = PRESETS.find(x => x.id === $('preset').value);
    cfg.preset = $('preset').value;
    if (p) { cfg.at = p.at; cfg.place = p.place; cfg.price = p.price; }
    if (cfg.pin) { cfg.pin = null; log('換場次，已清除指定按鈕'); }
    save('cfg', cfg); fillForm(); cached = null;
  };
  ['at', 'place', 'price', 'trip', 'autoClick', 'autoReload', 'sameTab'].forEach(id => { $(id).onchange = () => { cfg.preset = id === 'trip' || $(id).type === 'checkbox' ? cfg.preset : 'custom'; readForm(); fillForm(); }; });

  function log(msg) {
    const line = `${clock(now())}  ${msg}`;
    logs = logs.concat(line).slice(-12);
    save('logs', logs);
    const el = $('log');
    if (el) { el.textContent = logs.slice().reverse().join('\n'); }
  }
  function setStatus(t) { $('st').textContent = t; }
  $('log').textContent = logs.slice().reverse().join('\n');
  fillForm();

  // ---------- 武裝與流程 ----------
  const pageLoadedAt = Date.now();
  let lastClickAt = 0, lastFull = 0, resynced = false, blocked = false, origTitle = '';

  function saveRun() { save('run', run); }
  function finish(phase, msg, loud) {
    if (!run) return;
    run.phase = phase; saveRun();
    if (msg) alarm(msg, loud);
    renderArm();
  }
  function renderArm() {
    const on = run && run.phase === 'armed';
    $('arm').classList.toggle('on', !!on);
    $('arm').textContent = on ? (run.drill ? '■ 停止演練' : '■ 解除武裝') : '⚔ 武裝（開搶前按一次）';
  }

  async function arm(drill) {
    unlockAudio();
    if (run && run.phase === 'armed') { run = null; save('run', null); mark(null); setStatus('已解除武裝'); log('已解除武裝'); renderArm(); return; }
    readForm();
    const target = drill ? now() + 30000 : parseTaipei(cfg.at);
    if (!target) { setStatus('⚠️ 開搶時間格式要像 2026-10-27 12:00:00'); return; }
    if (now() - target > 60000) { setStatus('⚠️ 這個時間已經過了，請到「設定」換場次'); return; }
    run = { target, url: location.href, page: location.pathname, phase: 'armed', reloads: 0, clicks: 0, drill: !!drill };
    saveRun(); renderArm(); beep([660, 990]);
    log(drill ? '演練開始：30 秒後模擬開搶（不會點擊）' : `已武裝：${cfg.at} 開搶，盯「${cfg.place}」${cfg.price ? '＋' + cfg.price : ''}`);
    if (!drill && target - now() > 15000) await syncClock(6);
    const r = scan(true); mark(r); setStatus(STATE_TEXT[judge(r)]);
    if (r) r.card.scrollIntoView({ block: 'center', behavior: 'smooth' });
  }
  $('arm').onclick = () => arm(false);
  $('drill').onclick = () => { if (run && run.phase === 'armed') return arm(false); arm(true); };
  $('sync').onclick = () => { unlockAudio(); syncClock(8); };
  $('test').onclick = () => {
    unlockAudio(); readForm();
    const r = scan(true), s = judge(r);
    mark(r); setStatus(STATE_TEXT[s]);
    if (r) {
      r.card.scrollIntoView({ block: 'center', behavior: 'smooth' });
      log(`掃描：${r.via === 'pin' ? '指定' : '自動'}找到「${r.text.slice(0, 26)}…」按鈕「${r.btn ? norm(r.btn.innerText).slice(0, 12) : '無'}」`);
    } else log('掃描：找不到含關鍵字的方案');
  };

  // 🎯 指定按鈕：下一次在頁面上點的東西就是目標
  let picking = false, hoverEl = null, hoverOutline = '';
  const clearHover = () => { if (hoverEl) hoverEl.style.outline = hoverOutline; hoverEl = null; };
  $('pick').onclick = () => {
    unlockAudio();
    picking = !picking;
    setStatus(picking ? '🎯 請在頁面上點「東京 999」那張卡的搶購按鈕（Esc 取消）' : '已取消指定');
  };
  document.addEventListener('mouseover', e => {
    if (!picking || e.composedPath().includes(host)) return;
    clearHover();
    hoverEl = e.target.closest(BTN_SEL) || e.target;
    hoverOutline = hoverEl.style.outline;
    hoverEl.style.outline = '3px dotted #00c46a';
  }, true);
  document.addEventListener('keydown', e => { if (picking && e.key === 'Escape') { picking = false; clearHover(); setStatus('已取消指定'); } }, true);
  document.addEventListener('click', e => {
    if (!picking || e.composedPath().includes(host)) return;
    e.preventDefault(); e.stopImmediatePropagation();
    picking = false; clearHover();
    const el = e.target.closest(BTN_SEL) || e.target;
    cfg.pin = { page: location.pathname, sel: cssPath(el), label: norm(el.innerText).slice(0, 20) };
    save('cfg', cfg); fillForm(); cached = null;
    const r = scan(true); mark(r); setStatus(STATE_TEXT[judge(r)]);
    log(`已指定按鈕：「${cfg.pin.label}」`);
  }, true);
  $('unpin').onclick = () => { cfg.pin = null; save('cfg', cfg); fillForm(); cached = null; log('已清除指定按鈕'); };
  function cssPath(el) {
    const parts = [];
    while (el && el.nodeType === 1 && el !== document.body && el !== document.documentElement) {
      let p = el.tagName.toLowerCase();
      if (el.id && !/\d{3,}/.test(el.id)) { parts.unshift(p + '#' + CSS.escape(el.id)); return parts.join(' > '); }
      const same = el.parentElement ? [...el.parentElement.children].filter(c => c.tagName === el.tagName) : [];
      if (same.length > 1) p += `:nth-of-type(${same.indexOf(el) + 1})`;
      parts.unshift(p);
      el = el.parentElement;
    }
    return 'body > ' + parts.join(' > ');
  }

  // 點下去之後換頁（或開新分頁）＝進入下單流程，交棒給你
  const onEventPage = () => run && location.pathname === run.page;
  if (run && run.phase === 'armed' && now() - run.target > GIVE_UP_AFTER + 60000) { run = null; save('run', null); }
  if (run && run.phase === 'armed' && run.clicks > 0 && !onEventPage() && now() - run.target < 15 * 60000) {
    run.phase = 'handoff'; saveRun();
    setStatus(`✅ 已進入訂購頁！換你：確認日期（${cfg.trip}）→ 旅客 → 付款`);
    setTimeout(() => alarm('已進入訂購頁，換你確認日期和付款', true), 300);
  } else if (run && run.phase === 'armed' && !onEventPage()) {
    setStatus('⚠️ 已武裝，但這頁不是活動頁');
    const b = document.createElement('button'); b.textContent = '↩ 回活動頁'; b.onclick = () => location.assign(run.url);
    $('arm').after(b);
  }
  renderArm();

  function tick() {
    const t = now();
    $('srv').textContent = clock(t);
    $('off').textContent = offsetErr == null ? (offset ? `本機${offset >= 0 ? '慢' : '快'} ${(Math.abs(offset) / 1000).toFixed(2)}s` : '尚未校時') : `本機${offset >= 0 ? '慢' : '快'} ${(Math.abs(offset) / 1000).toFixed(2)}s ±${(offsetErr / 1000).toFixed(2)}`;
    const target = run && run.phase === 'armed' ? run.target : parseTaipei(cfg.at);
    if (!target) return;
    const dt = t - target;
    $('cd').textContent = countdown(-dt);
    $('cd').classList.toggle('go', dt >= 0);
    $('tg').textContent = run && run.drill ? '演練模式（不會點擊、不會重整）' : `${cfg.at} 開搶・${cfg.place.split('|')[0]} ${cfg.price}`;
    $('mini').textContent = panel.classList.contains('min') ? countdown(-dt).slice(0, 8) : '';

    if (!run || run.phase !== 'armed' || !onEventPage()) return;
    if (document.hidden && dt > -60000 && dt < 0) { if (!document.title.startsWith('⚠️')) { origTitle = document.title; document.title = '⚠️ 請切回搶票分頁'; } }
    else if (origTitle && document.title.startsWith('⚠️')) { document.title = origTitle; origTitle = ''; }

    // 開搶前 90 秒再校時一次
    if (!run.drill && !resynced && dt > -95000 && dt < -80000) { resynced = true; syncClock(4); }
    if (dt > -10000) patchOpen();

    if (dt < -3000) {
      if (Date.now() - lastFull > 2000) { lastFull = Date.now(); const r = scan(true); mark(r); setStatus('⚔ 已武裝・' + STATE_TEXT[judge(r)]); }
      return;
    }
    const full = Date.now() - lastFull > (dt > -1500 && dt < 8000 ? 200 : 500);
    if (full) lastFull = Date.now();
    const r = scan(full);
    const s = judge(r);
    if (full) mark(r);
    setStatus((dt < 0 ? '⚔ 倒數中・' : '🔥 開搶中・') + STATE_TEXT[s]);
    if (dt < 0) return;

    if (run.drill) {
      const what = s === 'ready' || s === 'maybe' ? '正式時會立刻點下綠色虛線框' : s === 'waiting' ? '正式時會等它變成可按再點；沒變就自動重整' : s === 'soldout' ? '正式時會停下來通知你' : '正式時會一直重整找它';
      finish('done', `演練完成：${STATE_TEXT[s].replace(/^\S+\s/, '')}，${what}`, false);
      return;
    }
    if (s === 'soldout') { finish('soldout', '方案已售完，改打備案（作戰頁的比價連結）', true); return; }

    if (((s === 'ready' && dt >= CLICK_DELAY) || (s === 'maybe' && dt > 1500 && r.kind === 'buy')) && r.btn) {
      if (!cfg.autoClick) { if (!run.clicks) { run.clicks = -1; saveRun(); alarm('開搶了！快按綠色框', true); } return; }
      if (run.clicks >= 2 || Date.now() - lastClickAt < 2000) return;
      if (run.clicks === 1 && document.querySelector('[role="dialog"],[class*="modal" i],[class*="popup" i],[class*="mask" i]')) return;
      lastClickAt = Date.now();
      run.clicks++; saveRun();
      log(`第 ${run.clicks} 次點擊「${norm(r.btn.innerText).slice(0, 12) || '方案'}」（開搶後 ${(dt / 1000).toFixed(2)} 秒）`);
      fire(r.btn);
      if (run.clicks === 1) alarm(`已幫你按下去了！換你確認日期 ${cfg.trip} 和付款`, true);
      return;
    }

    if (full && dt > 1000 && Date.now() - pageLoadedAt > 1500 && !blocked && BLOCK_RE.test(document.body.innerText.slice(0, 20000))) {
      blocked = true; alarm('出現安全驗證，請你手動完成，腳本會繼續盯', true);
    }
    if (cfg.autoReload && !blocked && dt > FIRST_RELOAD && Date.now() - pageLoadedAt > RELOAD_GAP && document.readyState === 'complete') {
      if (run.reloads >= MAX_RELOADS) { finish('gaveup', `已重整 ${MAX_RELOADS} 次還沒開，先停下來，請手動看看`, true); return; }
      run.reloads++; saveRun();
      log(`還沒開搶，第 ${run.reloads} 次重整`);
      location.reload();
      return;
    }
    if (dt > GIVE_UP_AFTER) finish('gaveup', '開搶 2 分鐘了還沒進場，先停下來', true);
  }
  startTicker(tick, 80);

  // 30 分鐘內沒校時過就先校一次（開搶前後 15 秒內不打擾）
  const stale = !synced || Date.now() - synced.at > 30 * 60000;
  if (stale && !(run && run.phase === 'armed' && Math.abs(run.target - now()) < 15000)) syncClock(5);
})();
