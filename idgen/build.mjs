#!/usr/bin/env node
/**
 * 身分證字號產生器 — 加密打包與白名單管理
 *
 * 頁面內容用 AES-GCM 加密，只有白名單裡的人用自己的通行碼才解得開。
 * 每個人的通行碼由「主密碼 + 名字」算出來，所以只要記住主密碼，就能重新產生所有人的通行碼。
 * 主密碼只放在環境變數 IDGEN_MASTER，不要寫進任何檔案，也不要 commit。
 *
 * 用法（在 repo 根目錄執行）：
 *   node idgen/build.mjs init <頁面原始檔.html> <名字>...        第一次建立，會產生新的主密碼
 *   IDGEN_MASTER=… node idgen/build.mjs list                     列出白名單與每個人的通行碼
 *   IDGEN_MASTER=… node idgen/build.mjs add <名字>...             加入白名單
 *   IDGEN_MASTER=… node idgen/build.mjs remove <名字>...          移出白名單（同時換掉內容金鑰）
 *   IDGEN_MASTER=… node idgen/build.mjs update <頁面原始檔.html>  換成新版頁面，白名單不變
 *   IDGEN_MASTER=… node idgen/build.mjs export <輸出.html>        解密取回頁面原始檔（要改版時用）
 *
 * 選項：
 *   IDGEN_FRAGMENT=<路徑>  另外輸出一份不含 <html>/<head> 的版本，給 Claude Artifact 發布用
 */
import { webcrypto } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const { subtle } = webcrypto;
const OUT = path.join(path.dirname(fileURLToPath(import.meta.url)), 'index.html');
const ITER = 200000;
const ALPHABET = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789'; // 去掉容易看錯的 I、L、O、0、1

const enc = new TextEncoder();
const dec = new TextDecoder();
const b64 = bytes => Buffer.from(bytes).toString('base64');
const unb64 = s => new Uint8Array(Buffer.from(s, 'base64'));
const norm = s => s.normalize('NFKC').toUpperCase().replace(/[^A-Z0-9]/g, '');
const group = s => s.match(/.{1,4}/g).join('-');
const random = n => webcrypto.getRandomValues(new Uint8Array(n));

function randomCode(len) {
  return group(Array.from(random(len), b => ALPHABET[b % ALPHABET.length]).join(''));
}
async function userCode(master, name) {
  const key = await subtle.importKey('raw', enc.encode(norm(master)), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const mac = new Uint8Array(await subtle.sign('HMAC', key, enc.encode('idgen-user:' + name)));
  return group(Array.from(mac.slice(0, 12), b => ALPHABET[b % ALPHABET.length]).join(''));
}
async function kek(secret, salt) {
  const base = await subtle.importKey('raw', enc.encode(norm(secret)), 'PBKDF2', false, ['deriveKey']);
  return subtle.deriveKey({ name: 'PBKDF2', salt, iterations: ITER, hash: 'SHA-256' }, base,
    { name: 'AES-GCM', length: 256 }, false, ['encrypt', 'decrypt']);
}
async function seal(key, text) {
  const iv = random(12);
  const ct = new Uint8Array(await subtle.encrypt({ name: 'AES-GCM', iv }, key, enc.encode(text)));
  return b64(Buffer.concat([iv, ct]));
}
async function open(key, s) {
  const b = unb64(s);
  return dec.decode(await subtle.decrypt({ name: 'AES-GCM', iv: b.slice(0, 12) }, key, b.slice(12)));
}
const aesKey = raw => subtle.importKey('raw', raw, 'AES-GCM', false, ['encrypt', 'decrypt']);

function requireMaster() {
  const m = process.env.IDGEN_MASTER;
  if (!m) { console.error('請先設定主密碼：IDGEN_MASTER=XXXX-… node idgen/build.mjs …'); process.exit(1); }
  return m;
}

// 讀出目前的白名單與頁面原始檔
async function load(master) {
  const html = fs.readFileSync(OUT, 'utf8');
  const m = html.match(/\/\*DATA\*\/(.*?)\/\*END\*\//s);
  if (!m) throw new Error(`${OUT} 裡找不到加密資料`);
  const data = JSON.parse(m[1]);
  let admin;
  try {
    admin = JSON.parse(await open(await kek(master, unb64(data.salt)), data.admin));
  } catch {
    console.error('主密碼不正確。');
    process.exit(1);
  }
  const src = await open(await aesKey(unb64(admin.k)), data.app);
  return { names: admin.names, src };
}

// 重新打包：每次都換新的 salt 和內容金鑰，被移出的人舊的金鑰就失效
async function build(master, names, src) {
  const salt = random(16);
  const raw = random(32);
  const k = b64(raw);
  const contentKey = await aesKey(raw);
  const keys = [];
  for (const n of names) keys.push(await seal(await kek(await userCode(master, n), salt), JSON.stringify({ k, n })));
  keys.sort(); // 打亂順序，看不出誰是第幾個
  const data = {
    v: 1,
    id: Buffer.from(random(4)).toString('hex'),
    salt: b64(salt),
    iter: ITER,
    keys,
    app: await seal(contentKey, src),
    admin: await seal(await kek(master, salt), JSON.stringify({ k, names })),
  };
  const fragment = gate(data);
  fs.writeFileSync(OUT,
    '<!doctype html>\n<html lang="zh-Hant-TW">\n<head>\n<meta charset="utf-8">\n' +
    '<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">\n' +
    '<meta name="robots" content="noindex, nofollow">\n</head>\n<body>\n' + fragment + '\n</body>\n</html>\n');
  if (process.env.IDGEN_FRAGMENT) fs.writeFileSync(process.env.IDGEN_FRAGMENT, fragment + '\n');
}

async function printCodes(master, names) {
  console.log('\n白名單（共 ' + names.length + ' 人）：');
  for (const n of names) console.log(`  ${n}\t${await userCode(master, n)}`);
  console.log('');
}

const [cmd, ...args] = process.argv.slice(2);
if (cmd === 'init') {
  const [srcPath, ...names] = args;
  if (!srcPath || !names.length) { console.error('用法：node idgen/build.mjs init <頁面原始檔.html> <名字>...'); process.exit(1); }
  const master = randomCode(20);
  await build(master, names, fs.readFileSync(srcPath, 'utf8'));
  console.log('新的主密碼（請自己保存，不要放進 GitHub）：\n  ' + master);
  await printCodes(master, names);
} else if (cmd === 'list') {
  const master = requireMaster();
  const { names } = await load(master);
  await printCodes(master, names);
} else if (cmd === 'add' || cmd === 'remove') {
  const master = requireMaster();
  const { names, src } = await load(master);
  const next = cmd === 'add'
    ? [...names, ...args.filter(n => !names.includes(n))]
    : names.filter(n => !args.includes(n));
  await build(master, next, src);
  await printCodes(master, next);
} else if (cmd === 'update') {
  const master = requireMaster();
  const { names } = await load(master);
  await build(master, names, fs.readFileSync(args[0], 'utf8'));
  console.log('已換成新版頁面，白名單不變。');
} else if (cmd === 'export') {
  const master = requireMaster();
  const { src } = await load(master);
  fs.writeFileSync(args[0], src);
  console.log('已解密到 ' + args[0]);
} else {
  console.log(fs.readFileSync(fileURLToPath(import.meta.url), 'utf8').match(/\/\*\*([\s\S]*?)\*\//)[1].replace(/^ \* ?/gm, ''));
}

// ── 解鎖頁（瀏覽器端）──
function gate(data) {
  return `<title>身分證字號產生器</title>
<meta name="claude:viewport-fit-sides" content="cover">
<style id="gate-style">
:root {
  --paper: #e6eeeb; --sheet: #f7faf9; --ink: #0f2f2b; --muted: #4c6762; --rule: #bccfc9;
  --teal: #0b6a5f; --on-teal: #ffffff; --seal: #c23b2a; --bad: #ad2a1d; --bad-soft: #f8dfdb;
}
@media (prefers-color-scheme: dark) {
  :root:not([data-theme="light"]) {
    --paper: #0b1614; --sheet: #12201d; --ink: #e1eeea; --muted: #93aca6; --rule: #2a443e;
    --teal: #5ccdbd; --on-teal: #04211c; --seal: #ff7d6b; --bad: #ff8a7c; --bad-soft: #3d1b17;
    color-scheme: dark;
  }
}
:root[data-theme="dark"] {
  --paper: #0b1614; --sheet: #12201d; --ink: #e1eeea; --muted: #93aca6; --rule: #2a443e;
  --teal: #5ccdbd; --on-teal: #04211c; --seal: #ff7d6b; --bad: #ff8a7c; --bad-soft: #3d1b17;
  color-scheme: dark;
}
[hidden] { display: none !important; }
body { margin: 0; background: var(--paper); color: var(--ink); font: 18px/1.7 "Noto Sans TC", "PingFang TC", "Microsoft JhengHei", system-ui, sans-serif; }
.gate {
  position: relative; box-sizing: border-box; max-width: 440px; margin: clamp(32px, 12vh, 120px) auto 40px;
  margin-left: max(16px, env(safe-area-inset-left, 0px)); margin-right: max(16px, env(safe-area-inset-right, 0px));
  padding: 36px clamp(18px, 5vw, 32px) 28px; display: grid; gap: 14px;
  background: var(--sheet); border: 1.5px solid var(--rule); border-radius: 14px;
}
@media (min-width: 480px) { .gate { margin-left: auto; margin-right: auto; } }
.gate h1 { margin: 0; font-size: 1.6rem; line-height: 1.3; }
.gate p { margin: 0; color: var(--muted); }
.gate label { font-size: .85rem; font-weight: 700; color: var(--muted); }
.gate input[type=text] {
  font: 700 1.25rem/1.3 ui-monospace, Menlo, Consolas, monospace; letter-spacing: .08em;
  width: 100%; box-sizing: border-box; padding: .6rem .8rem; margin-top: 4px;
  border: 1.5px solid var(--rule); border-radius: 10px; background: var(--paper); color: var(--ink);
}
.gate .check { display: flex; align-items: center; gap: .45rem; font-size: .92rem; cursor: pointer; }
.gate button {
  font: inherit; font-weight: 700; padding: .8rem 1.2rem; cursor: pointer;
  border: 0; border-radius: 10px; background: var(--teal); color: var(--on-teal);
}
.gate button:disabled { opacity: .6; cursor: default; }
.gate :is(input, button):focus-visible { outline: 3px solid var(--seal); outline-offset: 2px; }
.gate .msg { padding: .5rem .8rem; border-radius: 8px; background: var(--bad-soft); color: var(--bad); font-weight: 700; }
.gate .note { font-size: .8rem; }
.gate .seal {
  position: absolute; top: -16px; right: 20px; width: 56px; height: 56px; display: grid; place-content: center;
  border: 3px solid var(--seal); outline: 1px solid var(--seal); outline-offset: 3px; border-radius: 6px;
  background: var(--sheet); color: var(--seal); font-weight: 700; font-size: .85rem; line-height: 1.1; text-align: center;
  transform: rotate(-9deg);
}
</style>
<main class="gate" id="gate">
  <div class="seal" aria-hidden="true">測試<br>專用</div>
  <h1>身分證字號產生器</h1>
  <p>這個工具只開放給白名單裡的人使用，請輸入你拿到的通行碼。</p>
  <form id="gate-form" autocomplete="off">
    <label for="gate-code">通行碼</label>
    <input type="text" id="gate-code" autocapitalize="characters" spellcheck="false" placeholder="例如 ABCD-EFGH-JKMN" required>
    <label class="check" for="gate-remember" style="margin-top:12px"><input type="checkbox" id="gate-remember" checked> 記住這台裝置</label>
    <button type="submit" id="gate-btn" style="width:100%;margin-top:14px">解鎖</button>
  </form>
  <p class="msg" id="gate-msg" role="alert" hidden></p>
  <p class="note">頁面內容已加密，沒有通行碼的人看不到也無法使用。通行碼不要轉給別人；被移出白名單後就會失效。</p>
</main>
<script>
(() => {
  const DATA = /*DATA*/${JSON.stringify(data)}/*END*/;
  const KEY = 'idgen-unlock:' + DATA.id;
  const $ = id => document.getElementById(id);
  const unb64 = s => Uint8Array.from(atob(s), c => c.charCodeAt(0));
  const norm = s => s.normalize('NFKC').toUpperCase().replace(/[^A-Z0-9]/g, '');
  const store = {
    get() { try { return JSON.parse(localStorage.getItem(KEY) || 'null'); } catch (e) { return null; } },
    set(v) { try { localStorage.setItem(KEY, JSON.stringify(v)); } catch (e) { /* 無痕模式存不了 */ } },
    clear() { try { Object.keys(localStorage).filter(k => k.startsWith('idgen-unlock:')).forEach(k => localStorage.removeItem(k)); } catch (e) { /* 略過 */ } },
  };
  async function decrypt(key, s) {
    const b = unb64(s);
    return new Uint8Array(await crypto.subtle.decrypt({ name: 'AES-GCM', iv: b.slice(0, 12) }, key, b.slice(12)));
  }
  async function unlockWithCode(code) {
    const base = await crypto.subtle.importKey('raw', new TextEncoder().encode(norm(code)), 'PBKDF2', false, ['deriveKey']);
    const kek = await crypto.subtle.deriveKey({ name: 'PBKDF2', salt: unb64(DATA.salt), iterations: DATA.iter, hash: 'SHA-256' },
      base, { name: 'AES-GCM', length: 256 }, false, ['decrypt']);
    for (const entry of DATA.keys) {
      try { return JSON.parse(new TextDecoder().decode(await decrypt(kek, entry))); } catch (e) { /* 不是這一組，試下一組 */ }
    }
    return null;
  }
  async function mount(k, name) {
    const key = await crypto.subtle.importKey('raw', unb64(k), 'AES-GCM', false, ['decrypt']);
    const html = new TextDecoder().decode(await decrypt(key, DATA.app));
    $('gate').remove();
    $('gate-style').remove();
    const holder = document.createElement('div');
    holder.innerHTML = html;
    const scripts = [...holder.querySelectorAll('script')];
    while (holder.firstChild) document.body.appendChild(holder.firstChild);
    // innerHTML 放進來的 script 不會執行，要換成新的 script 元素
    for (const old of scripts) {
      if (old.type && old.type !== 'text/javascript') continue;
      const s = document.createElement('script');
      s.textContent = old.textContent;
      old.replaceWith(s);
    }
    document.title = '身分證字號產生器';
    const who = document.createElement('p');
    who.style.cssText = 'text-align:center;font-size:.85rem;color:var(--muted);margin:0 0 40px';
    who.textContent = '使用者：' + name + '　';
    const out = document.createElement('button');
    out.type = 'button';
    out.className = 'btn small';
    out.textContent = '登出';
    out.addEventListener('click', () => { store.clear(); location.reload(); });
    who.appendChild(out);
    document.body.appendChild(who);
  }

  $('gate-form').addEventListener('submit', async e => {
    e.preventDefault();
    const btn = $('gate-btn'), msg = $('gate-msg');
    btn.disabled = true;
    btn.textContent = '解鎖中…';
    msg.hidden = true;
    try {
      const hit = await unlockWithCode($('gate-code').value);
      if (!hit) throw new Error('wrong');
      if ($('gate-remember').checked) store.set(hit);
      await mount(hit.k, hit.n);
    } catch (err) {
      msg.textContent = err.message === 'wrong'
        ? '通行碼不正確，或已經被移出白名單。請向發通行碼給你的人確認。'
        : '這個瀏覽器無法解鎖，請改用最新版的 Chrome、Safari 或 Edge。';
      msg.hidden = false;
      btn.disabled = false;
      btn.textContent = '解鎖';
    }
  });

  const saved = store.get();
  if (saved) mount(saved.k, saved.n).catch(() => store.clear());
})();
</script>`;
}
