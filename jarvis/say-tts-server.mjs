#!/usr/bin/env node
/**
 * Jarvis 中文語音橋接
 *
 * 把 macOS 內建的台灣國語語音（美佳 Meijia）包成 claude-voice 認得的 Kokoro / OpenAI TTS 介面，
 * claude-voice 不用改任何程式碼：它照樣打 POST /v1/audio/speech，拿回 24kHz 16-bit 單聲道 PCM。
 * （claude-voice 原本的 Kokoro 念中文幾乎聽不懂，所以換掉。）
 *
 * 用法：node say-tts-server.mjs                  只綁 127.0.0.1:8880
 *   JARVIS_VOICE="Meijia (Enhanced)"  指定聲音（預設自動挑 zh_TW：Premium > Enhanced > 一般）
 *   JARVIS_TTS_PORT=8880              換 port
 *   JARVIS_SAY_BIN=say                測試時可換成假的 say
 */
import http from 'node:http';
import { spawn, execFileSync } from 'node:child_process';
import { readFile, rm } from 'node:fs/promises';
import { realpathSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';

const PORT = Number(process.env.JARVIS_TTS_PORT || 8880);
const SAY = process.env.JARVIS_SAY_BIN || 'say';
const RATE = 24000; // claude-voice 的 Kokoro 介面固定吃 24kHz
const BASE_WPM = 190; // say 的正常語速（speed=1 時不帶 -r，用系統預設）

/** 從 `say -v ?` 挑台灣國語聲音 */
export function pickVoice(listing) {
  const voices = [];
  for (const line of listing.split('\n')) {
    const m = line.match(/^(.+?)\s+([a-z]{2,3}_[A-Z]{2})\s+#/);
    if (m && m[2] === 'zh_TW') voices.push(m[1].trim());
  }
  const rank = (v) => (/premium|高品質/i.test(v) ? 0 : /enhanced|優化|增強/i.test(v) ? 1 : 2);
  voices.sort((a, b) => rank(a) - rank(b));
  return voices[0];
}

function resolveVoice() {
  if (process.env.JARVIS_VOICE) return process.env.JARVIS_VOICE;
  try {
    const v = pickVoice(execFileSync(SAY, ['-v', '?'], { encoding: 'utf8' }));
    if (v) return v;
  } catch {
    // 交給下面的預設值
  }
  return 'Meijia';
}

/** 取出 WAV 的 PCM（macOS 寫的 WAV 常帶 FLLR 之類的額外 chunk，不能假設 44 bytes 檔頭） */
export function wavToPcm(buf) {
  if (buf.toString('ascii', 0, 4) !== 'RIFF' || buf.toString('ascii', 8, 12) !== 'WAVE') {
    throw new Error('不是 WAV 檔');
  }
  let fmt = null;
  for (let off = 12; off + 8 <= buf.length; ) {
    const id = buf.toString('ascii', off, off + 4);
    const size = buf.readUInt32LE(off + 4);
    const body = off + 8;
    if (id === 'fmt ') {
      fmt = {
        format: buf.readUInt16LE(body),
        channels: buf.readUInt16LE(body + 2),
        sampleRate: buf.readUInt32LE(body + 4),
        bits: buf.readUInt16LE(body + 14),
      };
    } else if (id === 'data') {
      if (!fmt) throw new Error('WAV 缺少 fmt chunk');
      const pcmOk = fmt.format === 1 || fmt.format === 0xfffe;
      if (!pcmOk || fmt.bits !== 16 || fmt.channels !== 1 || fmt.sampleRate !== RATE) {
        throw new Error(`WAV 格式不對：${JSON.stringify(fmt)}`);
      }
      return buf.subarray(body, Math.min(body + size, buf.length));
    }
    off = body + size + (size % 2);
  }
  throw new Error('WAV 缺少 data chunk');
}

function run(cmd, args, input) {
  return new Promise((resolve, reject) => {
    const child = spawn(cmd, args, { stdio: ['pipe', 'ignore', 'pipe'] });
    let err = '';
    child.stderr.on('data', (d) => (err += d));
    child.on('error', reject);
    child.on('close', (code) => (code === 0 ? resolve() : reject(new Error(`${cmd} 結束碼 ${code}：${err.trim()}`))));
    child.stdin.end(input);
  });
}

async function synthesize(text, speed, voice) {
  const out = join(tmpdir(), `jarvis-tts-${randomUUID()}.wav`);
  const args = ['-v', voice, '-o', out, '--file-format=WAVE', `--data-format=LEI16@${RATE}`];
  if (speed && Math.abs(speed - 1) > 0.01) args.push('-r', String(Math.round(BASE_WPM * speed)));
  try {
    await run(SAY, args, text); // 文字走 stdin，避免開頭是「-」被當成參數
    return wavToPcm(await readFile(out));
  } finally {
    await rm(out, { force: true });
  }
}

export function createServer(voice = resolveVoice()) {
  const server = http.createServer(async (req, res) => {
    if (req.method !== 'POST') {
      res.writeHead(200, { 'content-type': 'text/plain' });
      res.end(`ok ${voice}`);
      return;
    }
    if (!req.url.includes('/audio/speech')) {
      res.writeHead(404).end();
      return;
    }
    try {
      const chunks = [];
      for await (const c of req) chunks.push(c);
      const body = JSON.parse(Buffer.concat(chunks).toString('utf8') || '{}');
      const text = String(body.input ?? '').trim();
      const speed = Math.min(3, Math.max(0.5, Number(body.speed) || 1));
      const t0 = performance.now();
      const pcm = text ? await synthesize(text, speed, voice) : Buffer.alloc(0);
      res.writeHead(200, {
        'content-type': 'audio/pcm',
        'content-length': pcm.length,
        'x-synth-ms': Math.round(performance.now() - t0),
      });
      res.end(pcm);
    } catch (e) {
      const msg = Buffer.from(String(e.message || e));
      res.writeHead(500, { 'content-type': 'text/plain; charset=utf-8', 'content-length': msg.length });
      res.end(msg);
    }
  });
  return server;
}

if (process.argv[1] && import.meta.url === pathToFileURL(realpathSync(process.argv[1])).href) {
  const voice = resolveVoice();
  createServer(voice).listen(PORT, '127.0.0.1', () => {
    console.error(`Jarvis 中文語音（${voice}）在 127.0.0.1:${PORT}`);
  });
}
