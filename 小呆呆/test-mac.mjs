#!/usr/bin/env node
/**
 * Jarvis 第一步測試：國語辨識準不準、插話會不會停、回應速度
 *
 * 跑完會寫一份報告到 ~/Jarvis/jarvis-test-report.md，整份貼回給 Claude 就好。
 * 你唸的錄音會留在 ~/Jarvis/test-audio/，之後換別的辨識引擎可以拿同一批錄音比較。
 *
 * 用法：node ~/.jarvis/test-mac.mjs                全部（約 8 分鐘）
 *       node ~/.jarvis/test-mac.mjs --only asr      只測辨識（asr / bargein / latency）
 *       node ~/.jarvis/test-mac.mjs --files <資料夾> 不錄音，直接用資料夾裡的 01.wav…10.wav
 * 先決條件：whisper-server（:8081）和中文語音（:8880）在跑——~/.jarvis/start.sh --servers-only
 */
import { spawn, execFileSync } from 'node:child_process';
import { mkdirSync, readFileSync, writeFileSync, existsSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createInterface } from 'node:readline/promises';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const OpenCC = require('opencc-js');
const toCN = OpenCC.Converter({ from: 'tw', to: 'cn' });
const toTW = OpenCC.Converter({ from: 'cn', to: 'tw' }); // 只轉字形，不轉用語（twp 會把「對象」轉成「物件」）

const HOME = homedir();
const WORK = process.env.JARVIS_WORKDIR || join(HOME, 'Jarvis');
const AUDIO_DIR = join(WORK, 'test-audio');
const REPORT = join(WORK, 'jarvis-test-report.md');
const WHISPER_URL = process.env.WHISPER_URL || 'http://127.0.0.1:8081';
const TTS_URL = process.env.TTS_URL || 'http://127.0.0.1:8880/v1';
const CLAUDE_BIN = process.env.CLAUDE_BIN || 'claude';
const REC_BIN = process.env.REC_BIN || 'rec';
const CV_BIN = process.env.CLAUDE_VOICE_BIN || join(dirname(fileURLToPath(import.meta.url)), 'node_modules', '.bin', 'claude-voice');
const args = process.argv.slice(2);
const opt = (name) => {
  const i = args.indexOf(name);
  return i === -1 ? undefined : args[i + 1];
};
const ONLY = opt('--only');
const FILES = opt('--files');
const MODELS = (opt('--models') || process.env.JARVIS_TEST_MODELS || 'sonnet,opus').split(',');

let cvConfig = {};
try {
  cvConfig = JSON.parse(readFileSync(join(HOME, '.claude-voice', 'config.json'), 'utf8'));
} catch {
  // 沒有設定檔就用預設值
}
const SILENCE_MS = cvConfig.silenceTimeoutMs ?? 1500;
const VOICE_PROMPT = cvConfig.voicePrompt || '';

/** 測試句：辦公室指令、中英夾雜、數字、系名、取消類 */
const SENTENCES = [
  '幫我打開下載資料夾，把今天的影片按照日期整理好。',
  '把 Premiere 的專案匯出成 MP4，解析度 1080p。',
  '查一下明天下午三點有沒有招生說明會的會議。',
  '把這個資料夾裡的照片壓縮成一個 zip 檔，寄給系辦。',
  '幫我寫一封 email 給教務處，說期中考成績下週一前會上傳。',
  '時尚造型設計暨表演藝術系的招生影片剪好了嗎？',
  '先不要刪，等一下我確認之後再處理。',
  '把 Instagram 的貼文排程到星期五晚上八點。',
  '用 Claude 幫我摘要這份 PDF，只要三個重點就好。',
  '取消，剛剛那個指令不要執行。',
];

const report = [];
const out = (line = '') => {
  console.log(line);
  report.push(line);
};
const rl = createInterface({ input: process.stdin, output: process.stdout });
const ask = async (q) => {
  try {
    return await rl.question(q);
  } catch {
    return ''; // stdin 已關（例如用管線跑）就當作直接按 Enter
  }
};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const median = (xs) => {
  const s = [...xs].sort((a, b) => a - b);
  return s.length ? s[Math.floor(s.length / 2)] : NaN;
};
const avg = (xs) => xs.reduce((a, b) => a + b, 0) / (xs.length || 1);
const ms = (x) => `${Math.round(x)} ms`;
const sec = (x) => `${(x / 1000).toFixed(1)} 秒`;

// ---------- 工具 ----------

/** 0–99 的阿拉伯數字轉國字，「3點」跟「三點」不算錯 */
const ZH_DIGITS = '零一二三四五六七八九';
function numToZh(n) {
  if (n < 10) return ZH_DIGITS[n];
  const tens = Math.floor(n / 10);
  const ones = n % 10;
  return `${tens === 1 ? '' : ZH_DIGITS[tens]}十${ones ? ZH_DIGITS[ones] : ''}`;
}
const norm = (s) =>
  toCN(s)
    .toLowerCase()
    .replace(/(?<!\d)\d{1,2}(?!\d)/g, (d) => numToZh(Number(d)))
    .replace(/[\s\p{P}\p{S}]+/gu, '');

/** 字元錯誤率（CER）：兩邊都轉簡體、去標點空白後算編輯距離 */
export function cer(ref, hyp) {
  const r = [...norm(ref)];
  const h = [...norm(hyp)];
  const d = Array.from({ length: h.length + 1 }, (_, j) => j);
  for (let i = 1; i <= r.length; i++) {
    let prev = d[0];
    d[0] = i;
    for (let j = 1; j <= h.length; j++) {
      const cur = d[j];
      d[j] = Math.min(d[j] + 1, d[j - 1] + 1, prev + (r[i - 1] === h[j - 1] ? 0 : 1));
      prev = cur;
    }
  }
  return { errors: d[h.length], chars: r.length };
}

/** 判斷辨識結果是簡體還是繁體 */
function script(text) {
  const han = text.replace(/[^一-鿿]/g, '');
  if (!han) return '無中文';
  if (toTW(han) !== han) return '簡體';
  if (toCN(han) !== han) return '繁體';
  return '繁簡同形';
}

/** 跟 claude-voice 打 whisper-server 的方式一模一樣 */
async function transcribe(wavPath) {
  const form = new FormData();
  form.append('file', new Blob([readFileSync(wavPath)], { type: 'audio/wav' }), 'speech.wav');
  form.append('response_format', 'json');
  form.append('temperature', '0');
  form.append('language', cvConfig.language && cvConfig.language !== 'auto' ? cvConfig.language : 'zh');
  const t0 = performance.now();
  const res = await fetch(`${WHISPER_URL}/inference`, { method: 'POST', body: form });
  if (!res.ok) throw new Error(`whisper-server 回 ${res.status}`);
  const body = await res.json();
  return { text: String(body.text ?? '').trim(), latency: performance.now() - t0 };
}

function wavInfo(path) {
  const b = readFileSync(path);
  let off = 12;
  let rate = 16000;
  let channels = 1;
  while (off + 8 <= b.length) {
    const id = b.toString('ascii', off, off + 4);
    const size = b.readUInt32LE(off + 4);
    if (id === 'fmt ') {
      channels = b.readUInt16LE(off + 10);
      rate = b.readUInt32LE(off + 12);
    }
    if (id === 'data') {
      const pcm = b.subarray(off + 8, off + 8 + size);
      let sum = 0;
      const n = Math.floor(pcm.length / 2);
      for (let i = 0; i < n; i++) sum += pcm.readInt16LE(i * 2) ** 2;
      const rms = Math.sqrt(sum / (n || 1));
      return { seconds: n / channels / rate, rmsDb: 20 * Math.log10(rms / 32768 + 1e-9) };
    }
    off += 8 + size + (size % 2);
  }
  return { seconds: 0, rmsDb: -120 };
}

function run(cmd, cmdArgs, { timeoutMs = 30000 } = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(cmd, cmdArgs, { stdio: ['ignore', 'ignore', 'pipe'] });
    let err = '';
    child.stderr.on('data', (d) => (err += d));
    const t = setTimeout(() => child.kill('SIGINT'), timeoutMs);
    child.on('error', reject);
    child.on('close', (code) => {
      clearTimeout(t);
      code === 0 || code === null ? resolve() : reject(new Error(`${cmd} 結束碼 ${code}：${err.trim()}`));
    });
  });
}

/** 錄一句：聽到聲音才開始，安靜 1.5 秒自動結束，最長 20 秒 */
const recordUtterance = (path) =>
  run(REC_BIN, ['-q', '-c', '1', '-r', '16000', '-b', '16', path, 'silence', '1', '0.1', '1.5%', '1', '1.5', '1.5%', 'trim', '0', '20'], {
    timeoutMs: 25000,
  });
const recordFixed = (path, seconds) =>
  run(REC_BIN, ['-q', '-c', '1', '-r', '16000', '-b', '16', path, 'trim', '0', String(seconds)], {
    timeoutMs: (seconds + 5) * 1000,
  });

function beep() {
  if (process.platform === 'darwin') spawn('afplay', ['/System/Library/Sounds/Tink.aiff']).on('error', () => {});
  else process.stdout.write('\x07');
}

async function tts(text) {
  const t0 = performance.now();
  const res = await fetch(`${TTS_URL}/audio/speech`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ model: 'kokoro', input: text, voice: cvConfig.voice || 'zf_xiaoxiao', response_format: 'pcm', speed: 1, lang: 'cmn' }),
  });
  if (!res.ok) throw new Error(`中文語音回 ${res.status}：${await res.text()}`);
  const pcm = Buffer.from(await res.arrayBuffer());
  return { pcm, latency: performance.now() - t0, seconds: pcm.length / 2 / 24000 };
}

function pcmToWav(pcm, rate = 24000) {
  const h = Buffer.alloc(44);
  h.write('RIFF', 0);
  h.writeUInt32LE(36 + pcm.length, 4);
  h.write('WAVEfmt ', 8);
  h.writeUInt32LE(16, 16);
  h.writeUInt16LE(1, 20);
  h.writeUInt16LE(1, 22);
  h.writeUInt32LE(rate, 24);
  h.writeUInt32LE(rate * 2, 28);
  h.writeUInt16LE(2, 32);
  h.writeUInt16LE(16, 34);
  h.write('data', 36);
  h.writeUInt32LE(pcm.length, 40);
  return Buffer.concat([h, pcm]);
}

/** 目前 Mac 用的麥克風／喇叭（盡力而為，讀不到就算了） */
function audioDevices() {
  if (process.platform !== 'darwin') return null;
  try {
    const j = JSON.parse(execFileSync('system_profiler', ['SPAudioDataType', '-json'], { encoding: 'utf8', timeout: 15000 }));
    const items = (j.SPAudioDataType || []).flatMap((x) => x._items || []);
    const input = items.find((d) => d.coreaudio_default_audio_input_device === 'spaudio_yes')?._name;
    const output = items.find((d) => d.coreaudio_default_audio_output_device === 'spaudio_yes')?._name;
    return { input: input || '讀不到', output: output || '讀不到' };
  } catch {
    return null;
  }
}

// ---------- 測試 1：國語辨識 ----------

const asrResults = [];
async function testAsr() {
  out('## 1. 國語辨識（whisper.cpp 多語言模型）');
  out();
  const files = [];
  if (FILES) {
    for (let i = 0; i < SENTENCES.length; i++) {
      const p = join(FILES, `${String(i + 1).padStart(2, '0')}.wav`);
      if (existsSync(p)) files.push({ i, path: p });
    }
  } else {
    mkdirSync(AUDIO_DIR, { recursive: true });
    console.log('\n接下來畫面會出現 10 句話，用你平常跟 Jarvis 講話的語氣唸。');
    console.log('按 Enter → 聽到「叮」再開始唸 → 唸完停 1.5 秒會自動結束。\n');
    for (let i = 0; i < SENTENCES.length; i++) {
      const p = join(AUDIO_DIR, `${String(i + 1).padStart(2, '0')}.wav`);
      for (let attempt = 0; attempt < 3; attempt++) {
        await ask(`(${i + 1}/10) ${SENTENCES[i]}\n   [Enter 開始] `);
        beep();
        await sleep(250);
        await recordUtterance(p);
        if (wavInfo(p).seconds >= 0.5) break;
        console.log('   ⚠ 沒錄到聲音。確認「系統設定 → 隱私權與安全性 → 麥克風」有允許終端機，靠近麥克風再唸一次。');
      }
      files.push({ i, path: p });
    }
  }
  if (!files.length) throw new Error('沒有錄到任何音檔');

  await transcribe(files[0].path); // 暖機（第一次要載入 Metal）
  let errs = 0;
  let chars = 0;
  out('| # | 你唸的 | whisper 聽到的（原樣） | 錯字率 | 辨識耗時 | 句長 |');
  out('|---|---|---|---|---|---|');
  for (const { i, path } of files) {
    const { text, latency } = await transcribe(path);
    const c = cer(SENTENCES[i], text);
    const info = wavInfo(path);
    errs += c.errors;
    chars += c.chars;
    asrResults.push({ i, text, latency, seconds: info.seconds, rmsDb: info.rmsDb, cer: c.errors / c.chars, script: script(text) });
    out(`| ${i + 1} | ${SENTENCES[i]} | ${text || '（空白）'} | ${((c.errors / c.chars) * 100).toFixed(0)}% | ${ms(latency)} | ${info.seconds.toFixed(1)}s |`);
  }
  const scripts = asrResults.reduce((m, r) => ((m[r.script] = (m[r.script] || 0) + 1), m), {});
  out();
  out(`- **整體錯字率（CER）：${((errs / chars) * 100).toFixed(1)}%**（正確率約 ${(100 - (errs / chars) * 100).toFixed(1)}%；比對時繁簡視為相同、不計標點）`);
  out(`- 輸出字形：${Object.entries(scripts).map(([k, v]) => `${k} ${v} 句`).join('、')}`);
  out(`- 辨識耗時：中位數 ${ms(median(asrResults.map((r) => r.latency)))}，平均句長 ${avg(asrResults.map((r) => r.seconds)).toFixed(1)} 秒`);
  out(`- 錄音音量：平均 ${avg(asrResults.map((r) => r.rmsDb)).toFixed(1)} dBFS`);
  out();
}

// ---------- 測試 2：插話 ----------

async function testBargeIn() {
  out('## 2. 插話');
  out();
  out('程式碼層面（Claude 已在雲端驗證 claude-voice v0.1.5）：連續模式下 Jarvis 講話時麥克風是關的，');
  out('所以「直接開口」不會打斷它；只有按「空白鍵」會立刻切斷（軟體端 <1 ms）。下面量的是之後要做「用講的插話」需要的數據。');
  out();
  const dev = audioDevices();
  if (dev) out(`- 目前麥克風：**${dev.input}**；目前喇叭：**${dev.output}**`);

  if (!FILES) {
    const noise = join(AUDIO_DIR, 'room-noise.wav');
    await ask('\n[插話 1/2] 量環境噪音：按 Enter 後保持安靜 3 秒 ');
    await recordFixed(noise, 3);
    const noiseDb = wavInfo(noise).rmsDb;

    const sample = await tts('這是回音測試。我現在一邊講話，一邊用麥克風錄音，看看我自己的聲音會不會被麥克風收進去。');
    const wavPath = join(AUDIO_DIR, 'echo-tts.wav');
    writeFileSync(wavPath, pcmToWav(sample.pcm));
    const echo = join(AUDIO_DIR, 'echo-mic.wav');
    await ask('[插話 2/2] 量回音：按 Enter 後 Jarvis 會講一段話，這段期間你不要出聲 ');
    const rec = recordFixed(echo, Math.ceil(sample.seconds) + 1);
    await sleep(200);
    await run(process.platform === 'darwin' ? 'afplay' : 'aplay', [wavPath], { timeoutMs: 20000 }).catch(() => {});
    await rec;
    const echoDb = wavInfo(echo).rmsDb;
    const speechDb = asrResults.length ? avg(asrResults.map((r) => r.rmsDb)) : NaN;
    out(`- 環境噪音 ${noiseDb.toFixed(1)} dBFS；Jarvis 自己的聲音被麥克風收到 ${echoDb.toFixed(1)} dBFS；你講話 ${Number.isNaN(speechDb) ? '（沒測）' : `${speechDb.toFixed(1)} dBFS`}`);
    if (!Number.isNaN(speechDb)) {
      const margin = speechDb - echoDb;
      out(`- **你的聲音比 Jarvis 回音大 ${margin.toFixed(1)} dB** → ${margin >= 15 ? '夠大，之後「開口就打斷」可以直接用音量偵測做' : margin >= 8 ? '勉強，要加回音消除或調門檻' : '太小，要回音消除（或換麥克風）才能做開口打斷'}`);
    }
  }

  const a1 = (await ask('\n（選做）再開一個終端機視窗執行 ~/.jarvis/start.sh，問 Jarvis「用五句話介紹萬能科技大學」。\nJarvis 講話時你直接開口，它有停嗎？ [y/n/Enter 跳過] ')).trim();
  const a2 = (await ask('按空白鍵，它有停嗎？ [y/n/Enter 跳過] ')).trim();
  if (a1) out(`- 實測「直接開口」：${a1 === 'y' ? '有停' : '沒停'}`);
  if (a2) out(`- 實測「按空白鍵」：${a2 === 'y' ? '有停' : '沒停'}`);
  out();
}

// ---------- 測試 3：回應速度 ----------

/** 跟 claude-voice 一樣常駐一個 claude 程序（stream-json），量冷啟動與每輪首字時間 */
async function claudeLatency(model) {
  const cliArgs = ['--print', '--input-format', 'stream-json', '--output-format', 'stream-json', '--verbose', '--include-partial-messages', '--model', model, '--no-session-persistence'];
  if (VOICE_PROMPT) cliArgs.push('--append-system-prompt', VOICE_PROMPT);
  cliArgs.push('--tools', ''); // 測速不需要工具，也避免測試時動到任何檔案
  mkdirSync(WORK, { recursive: true });
  const t0 = performance.now();
  const child = spawn(CLAUDE_BIN, cliArgs, { cwd: WORK, stdio: ['pipe', 'pipe', 'pipe'] });
  let buf = '';
  let stderr = '';
  let listener = null;
  let initAt = 0;
  child.stdout.setEncoding('utf8');
  child.stdout.on('data', (d) => {
    buf += d;
    let nl;
    while ((nl = buf.indexOf('\n')) !== -1) {
      const line = buf.slice(0, nl);
      buf = buf.slice(nl + 1);
      let ev;
      try {
        ev = JSON.parse(line);
      } catch {
        continue;
      }
      if (ev.type === 'system' && ev.subtype === 'init' && !initAt) initAt = performance.now();
      listener?.(ev);
    }
  });
  child.stderr.on('data', (d) => (stderr += d));
  const exited = new Promise((r) => child.on('close', r));

  const turn = (prompt) =>
    new Promise((resolve, reject) => {
      const start = performance.now();
      let first = 0;
      let firstSentence = 0;
      let text = '';
      const timer = setTimeout(() => reject(new Error(`claude 120 秒沒回應：${stderr.slice(-300)}`)), 120000);
      listener = (ev) => {
        const delta = ev.type === 'stream_event' && ev.event?.type === 'content_block_delta' && ev.event.delta?.type === 'text_delta' ? ev.event.delta.text : '';
        if (delta) {
          if (!first) first = performance.now();
          text += delta;
          if (!firstSentence && /[。！？!?]/.test(text)) firstSentence = performance.now();
        }
        if (ev.type === 'result') {
          clearTimeout(timer);
          const end = performance.now();
          resolve({ ttft: first - start, firstSentence: (firstSentence || end) - start, total: end - start, chars: text.length, text, error: ev.is_error });
        }
      };
      child.stdin.write(`${JSON.stringify({ type: 'user', message: { role: 'user', content: [{ type: 'text', text: prompt }] } })}\n`);
    });

  try {
    const r1 = await turn('用三句話告訴我，你可以怎麼幫一位大學老師處理日常行政工作。');
    const r2 = await turn('那第一件事你建議從哪裡開始？用兩句話回答。');
    return { model, cold: (initAt || t0) - t0, turns: [r1, r2] };
  } finally {
    child.stdin.end();
    child.kill();
    await exited;
  }
}

async function testLatency() {
  out('## 3. 回應速度');
  out();
  const lines = [];

  // STT
  let stt = asrResults.length ? median(asrResults.map((r) => r.latency)) : NaN;
  if (Number.isNaN(stt)) {
    const p = join(AUDIO_DIR, '01.wav');
    if (existsSync(p)) stt = (await transcribe(p)).latency;
  }
  lines.push(`- 語音辨識（whisper-server，一句 ${asrResults.length ? avg(asrResults.map((r) => r.seconds)).toFixed(1) : '?'} 秒）：中位數 **${Number.isNaN(stt) ? '沒測' : ms(stt)}**`);

  // TTS
  const ttsRuns = [];
  for (const s of ['好的，馬上處理。', '我已經把下載資料夾整理完了，總共有十二支影片。', '要我現在上傳嗎？']) ttsRuns.push(await tts(s));
  const ttsMs = median(ttsRuns.map((r) => r.latency));
  lines.push(`- 中文語音合成（美佳，一句）：中位數 **${ms(ttsMs)}**`);

  // Claude
  const results = [];
  for (const m of MODELS) {
    console.log(`\n正在量 Claude（${m}）…`);
    try {
      results.push(await claudeLatency(m.trim()));
    } catch (e) {
      lines.push(`- Claude ${m}：失敗（${e.message}）`);
    }
  }
  for (const r of results) {
    const [a, b] = r.turns;
    lines.push(`- Claude **${r.model}**：第 1 輪（含程序啟動 ${ms(r.cold)}）首字 ${ms(a.ttft)}、第一句完 ${ms(a.firstSentence)}、全部 ${sec(a.total)}（${a.chars} 字）｜第 2 輪 首字 ${ms(b.ttft)}、第一句完 ${ms(b.firstSentence)}、全部 ${sec(b.total)}（${b.chars} 字）`);
  }
  lines.forEach((l) => out(l));
  out();

  // 端到端估算：你講完 → 聽到 Jarvis 第一個字
  if (results.length && !Number.isNaN(stt)) {
    out('**你講完話 → 聽到 Jarvis 第一個字（第 2 輪，估算）**');
    out();
    out('| 模型 | 原版 claude-voice（中文要等整段寫完才念） | 修正中文切句後（第一句寫完就念） |');
    out('|---|---|---|');
    for (const r of results) {
      const t = r.turns[1];
      const orig = SILENCE_MS + stt + t.total + ttsMs * Math.max(1, t.chars / 20);
      const fixed = SILENCE_MS + stt + t.firstSentence + ttsMs;
      out(`| ${r.model} | ${sec(orig)} | ${sec(fixed)} |`);
    }
    out();
    out(`（含講完後等待 ${SILENCE_MS} ms 判定「說完了」；原版那欄的語音合成按整段字數估）`);
    out();
    out('Claude 第 2 輪回覆範例：');
    out();
    out(`> ${results[0].turns[1].text.replace(/\n+/g, ' ')}`);
    out();
  }
}

// ---------- 主程式 ----------

async function main() {
  mkdirSync(WORK, { recursive: true });
  out('# Jarvis 第一步測試報告');
  out();
  const ver = (cmd, a) => {
    try {
      return execFileSync(cmd, a, { encoding: 'utf8', timeout: 15000 }).trim().split('\n')[0];
    } catch {
      return '未安裝';
    }
  };
  out(`- 時間：${new Date().toLocaleString('zh-TW', { hour12: false })}`);
  out(`- 機器：${process.platform === 'darwin' ? ver('sysctl', ['-n', 'machdep.cpu.brand_string']) : process.platform}｜macOS ${ver('sw_vers', ['-productVersion'])}`);
  out(`- claude CLI：${ver(CLAUDE_BIN, ['--version'])}｜${ver(CV_BIN, ['version'])}`);
  out(`- whisper 模型：${cvConfig.providers?.whispercpp?.model || '?'}｜語言：${cvConfig.language || '?'}｜Claude 模型設定：${cvConfig.model || '?'}`);
  out();
  for (const [name, fn] of [
    ['whisper-server', () => fetch(WHISPER_URL)],
    ['中文語音', () => fetch(TTS_URL)],
  ]) {
    try {
      await fn();
    } catch {
      console.error(`✖ ${name} 沒在跑，先執行：~/.jarvis/start.sh --servers-only`);
      process.exit(1);
    }
  }
  const steps = { asr: testAsr, bargein: testBargeIn, latency: testLatency };
  for (const [k, fn] of Object.entries(steps)) {
    if (ONLY && ONLY !== k) continue;
    try {
      await fn();
    } catch (e) {
      out(`> ✖ ${k} 測試出錯：${e.message}`);
      out();
    }
  }
  writeFileSync(REPORT, report.join('\n') + '\n');
  console.log(`\n✔ 報告存在 ${REPORT}\n  把整份內容貼回給 Claude（或執行：pbcopy < "${REPORT}" 複製）`);
  rl.close();
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
