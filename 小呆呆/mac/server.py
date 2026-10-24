"""小呆呆的 Mac 服務：手機邊講邊把聲音傳過來，這裡聽懂、問 Claude、用美佳念回去。

跟手機的約定（WebSocket，一支手機一條連線，一直連著）：

手機 → Mac
  {"type": "start", "sampleRate": 16000}   開始講話；接著是一段段 16-bit 單聲道 PCM（二進位）
  {"type": "end", "text": "…", "engine": "…", "phoneSeconds": 0.3}
                                           講完了（手機聽到安靜約 1 秒）。text 是 iPhone 自己聽懂的字，
                                           有就直接用；沒有（手機聽不了）才由這台 Mac 的 Qwen3-ASR 聽
  {"type": "cancel"}                       這句不算
  {"type": "ping"}                         確認連線還在

Mac → 手機
  {"type": "heard", "turn": 1, "text": "…"}                     聽成什麼字
  {"type": "say", "turn": 1, "kind": "…", "text": "…", "question": "…"}
                                                               緊接著一段二進位 WAV，照順序播
      kind：answer 直接回答／ack「收到，我去做」／report 做好了的報告（手機先叮一聲）／error 出錯
  {"type": "done", "turn": 1, "kind": "answer|ack|report"}     這一輪講完了，可以繼續聽「小呆呆」
  {"type": "pong"}

規則：講完 3 秒內 Claude 還沒寫出第一句，就先回「收到，我去做」，做好再把整段答案當報告送回去。
報告送的時候手機沒連著，就先留著，手機連回來馬上補送。
"""

from __future__ import annotations

import asyncio
import contextlib
import ipaddress
import json
import os
import sys
import time
import wave
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path

import numpy as np
from websockets.exceptions import ConnectionClosed

from brain import ClaudeError
from speech_text import SentenceSplitter, for_speech, strip_wake_word

HERE = Path(__file__).parent
ACK = "收到，我去做。"
NOT_HEARD = "沒聽清楚，再說一次。"
TOO_LONG = "做太久了，我先停下來。"
GPU_BROKEN = "電腦的語音辨識出問題，我重新開一下，十秒後再問。"


def is_gpu_error(exc: BaseException) -> bool:
    return "[METAL]" in str(exc)


def restart_soon(reason: str) -> None:
    """GPU 出錯後，macOS 常會直接封鎖這個程式用 GPU，只有重開才會好。
    結束程式，開機自動啟動的設定（launchd KeepAlive）會在約 10 秒後把它重開。"""
    print(f"{reason}：結束程式，等系統重新啟動")
    asyncio.get_running_loop().call_later(1, os._exit, 1)

# 只讓這台 Mac 自己和 Tailscale 裡的裝置（Rino 的手機）連進來
TAILSCALE_NETWORKS = [ipaddress.ip_network("100.64.0.0/10"), ipaddress.ip_network("fd7a:115c:a1e0::/48")]


def is_allowed(host: str) -> bool:
    try:
        ip = ipaddress.ip_address(host.split("%")[0])
    except ValueError:
        return False
    if getattr(ip, "ipv4_mapped", None):
        ip = ip.ipv4_mapped
    return ip.is_loopback or any(ip in net for net in TAILSCALE_NETWORKS if ip.version == net.version)


@dataclass
class Utterance:
    sample_rate: int
    chunks: list[bytes] = field(default_factory=list)
    phone_text: str | None = None  # iPhone 自己聽懂的字
    phone_engine: str = ""
    phone_seconds: float | None = None

    def samples(self) -> np.ndarray:
        pcm = np.frombuffer(b"".join(self.chunks), dtype="<i2")
        return pcm.astype(np.float32) / 32768


class Hub:
    def __init__(self, ears, brain, mouth, *, ack_after: float = 3.0, max_task_seconds: float = 300,
                 log_path: Path | None = HERE / "logs" / "turns.jsonl", on_fatal=restart_soon,
                 audio_dir: Path | None = HERE / "logs" / "audio", warm_on_start: bool = True):
        self.on_fatal = on_fatal
        self.warm_on_start = warm_on_start
        self.audio_dir = audio_dir
        self.ears = ears
        self.brain = brain
        self.mouth = mouth
        self.ack_after = ack_after
        self.max_task_seconds = max_task_seconds
        self.log_path = log_path
        self.phones: list = []  # 連著的手機，最新連上的在最後
        self.outbox: list[list[tuple[dict, bytes | None]]] = []  # 手機不在時留著的報告
        self._send_lock = asyncio.Lock()
        self._turns = 0
        self._tasks: set[asyncio.Task] = set()
        self._canned: dict[str, bytes] = {}

    # ---- 連線 ----

    async def handle(self, ws) -> None:
        host = ws.remote_address[0] if ws.remote_address else ""
        if not is_allowed(host):
            print(f"擋掉不認識的連線：{host}")
            await ws.close(code=1008, reason="not allowed")
            return
        # 不踢掉舊連線：手機換網路時新舊會同時在，測試時模擬器和真手機也會同時連；
        # 一輪的回答回給問的那條，報告送最新的那條
        self.phones.append(ws)
        print(f"手機連上了：{host}")
        await self._flush_outbox()
        utterance: Utterance | None = None
        try:
            async for message in ws:
                if isinstance(message, bytes):
                    if utterance is not None:
                        utterance.chunks.append(message)
                    continue
                try:
                    data = json.loads(message)
                except json.JSONDecodeError:
                    continue
                kind = data.get("type")
                if kind == "start":
                    utterance = Utterance(sample_rate=int(data.get("sampleRate", 16000)))
                    if self.warm_on_start:
                        self.ears.warm()  # 趁你還在講，先把模型叫醒
                elif kind == "end" and utterance is not None:
                    if isinstance(data.get("text"), str):
                        utterance.phone_text = data["text"]
                        utterance.phone_engine = str(data.get("engine", ""))
                        utterance.phone_seconds = data.get("phoneSeconds")
                    self._spawn(self.run_turn(utterance, time.monotonic(), ws))
                    utterance = None
                elif kind == "cancel":
                    utterance = None
                elif kind == "ping":
                    await self._send([({"type": "pong"}, None)], to=ws)
        except ConnectionClosed:
            pass
        finally:
            self.phones.remove(ws)
            print("手機斷線了")

    @property
    def phone(self):
        return self.phones[-1] if self.phones else None

    def _spawn(self, coro) -> None:
        task = asyncio.create_task(coro)
        self._tasks.add(task)
        task.add_done_callback(self._tasks.discard)

    async def _send(self, items: list[tuple[dict, bytes | None]], to=None) -> bool:
        """照順序送出（訊息和緊跟的聲音不會被別輪插隊）。

        先送給 to（問問題的那條連線）；它斷了就改送最新連上的手機；都不在就回傳 False。
        """
        async with self._send_lock:
            targets = [phone for phone in (to, self.phone) if phone is not None and phone in self.phones]
            for phone in dict.fromkeys(targets):
                try:
                    for data, audio in items:
                        await phone.send(json.dumps(data, ensure_ascii=False))
                        if audio is not None:
                            await phone.send(audio)
                    return True
                except ConnectionClosed:
                    continue
            return False

    async def _flush_outbox(self) -> None:
        while self.outbox:
            if not await self._send(self.outbox[0]):
                return
            self.outbox.pop(0)

    # ---- 一輪對話 ----

    async def run_turn(self, utterance: Utterance, ended_at: float, ws=None) -> None:
        self._turns += 1
        turn = self._turns
        log: dict = {"time": datetime.now().isoformat(timespec="seconds"), "turn": turn,
                     "audio_seconds": round(len(b"".join(utterance.chunks)) / 2 / utterance.sample_rate, 2)}
        if audio := self._save_audio(utterance, turn):
            log["audio"] = audio
        try:
            if utterance.phone_text is not None and utterance.phone_text.strip():
                text = utterance.phone_text
                log |= {"asr": f"phone:{utterance.phone_engine}", "phone_s": utterance.phone_seconds}
            else:
                log["asr"] = "mac"
                text = await asyncio.wrap_future(self.ears.transcribe(utterance.samples(), utterance.sample_rate))
        except Exception as exc:
            print(f"語音辨識出錯：{exc!r}")
            if is_gpu_error(exc):
                await self._say(turn, "error", GPU_BROKEN, "", to=ws)
                await self._send([({"type": "done", "turn": turn, "kind": "answer"}, None)], to=ws)
                self._write_log(log | {"mode": "gpu_error", "error": str(exc)})
                self.on_fatal("語音辨識時 GPU 出錯")
                return
            text = ""
        log["asr_s"] = round(time.monotonic() - ended_at, 2)
        log["raw"] = text
        text = strip_wake_word(text)
        log["heard"] = text
        await self._send([({"type": "heard", "turn": turn, "text": text}, None)], to=ws)
        if not text:
            await self._say(turn, "answer", NOT_HEARD, text, to=ws)
            await self._send([({"type": "done", "turn": turn, "kind": "answer"}, None)], to=ws)
            self._write_log(log | {"mode": "not_heard"})
            return

        sentences: asyncio.Queue = asyncio.Queue()
        thinking = asyncio.create_task(self._think(text, sentences))
        first_wait = max(0.0, ended_at + self.ack_after - time.monotonic())
        try:
            first = await asyncio.wait_for(sentences.get(), timeout=first_wait)
        except asyncio.TimeoutError:
            first = None
            log["mode"] = "report"
        else:
            log["mode"] = "answer"
            log["first_text_s"] = round(time.monotonic() - ended_at, 2)

        if log["mode"] == "answer":
            spoken = []
            item = first
            while item is not None:
                kind = "error" if isinstance(item, ClaudeError) else "answer"
                sentence = str(item)
                await self._say(turn, kind, sentence, text, to=ws)
                if "first_audio_s" not in log:
                    log["first_audio_s"] = round(time.monotonic() - ended_at, 2)
                spoken.append(sentence)
                item = None if kind == "error" else await sentences.get()
            await self._send([({"type": "done", "turn": turn, "kind": "answer"}, None)], to=ws)
            log["answer"] = "".join(spoken)
        else:
            await self._say(turn, "ack", ACK, text, to=ws)
            await self._send([({"type": "done", "turn": turn, "kind": "ack"}, None)], to=ws)
            parts = []
            while (item := await sentences.get()) is not None:
                parts.append(str(item))
                if isinstance(item, ClaudeError):
                    parts = [f"剛才「{text}」沒做成：{item}。"]
                    break
            log["answer"] = "".join(parts)
            await self._report(turn, parts, text, to=ws)
        await thinking
        log["total_s"] = round(time.monotonic() - ended_at, 2)
        self._write_log(log)

    def _save_audio(self, utterance: Utterance, turn: int) -> str | None:
        """把這句的聲音存起來，之後拿來比較 iPhone 和 Mac 哪邊聽得準（compare_asr.py）。"""
        if self.audio_dir is None or not utterance.chunks:
            return None
        self.audio_dir.mkdir(parents=True, exist_ok=True)
        path = self.audio_dir / f"{datetime.now():%Y%m%d-%H%M%S}-{turn}.wav"
        with wave.open(str(path), "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(utterance.sample_rate)
            w.writeframes(b"".join(utterance.chunks))
        return path.name

    async def _think(self, question: str, sentences: asyncio.Queue) -> None:
        """把 Claude 寫的字切成一句句放進 sentences；最後放 None。出錯就放一個 ClaudeError。"""
        splitter = SentenceSplitter()
        try:
            async with asyncio.timeout(self.max_task_seconds):
                async with contextlib.aclosing(self.brain.stream(question)) as pieces:
                    async for piece in pieces:
                        for sentence in splitter.feed(piece):
                            if spoken := for_speech(sentence):
                                await sentences.put(spoken)
            for sentence in splitter.flush():
                if spoken := for_speech(sentence):
                    await sentences.put(spoken)
        except ClaudeError as exc:
            await sentences.put(exc)
        except TimeoutError:
            await sentences.put(ClaudeError(TOO_LONG.rstrip("。")))
        except Exception as exc:
            print(f"問 Claude 時出錯：{exc!r}")
            await sentences.put(ClaudeError("Claude 出了問題，沒辦法回答"))
        await sentences.put(None)

    async def _say(self, turn: int, kind: str, sentence: str, question: str, to=None) -> None:
        audio = await self._voice(sentence)
        await self._send([({"type": "say", "turn": turn, "kind": kind, "text": sentence, "question": question}, audio)], to=to)

    async def _report(self, turn: int, sentences: list[str], question: str, to=None) -> None:
        items = []
        for sentence in sentences:
            data = {"type": "say", "turn": turn, "kind": "report", "text": sentence, "question": question}
            items.append((data, await self._voice(sentence)))
        items.append(({"type": "done", "turn": turn, "kind": "report"}, None))
        if not await self._send(items, to=to):
            print("手機不在，報告先留著，連回來再送")
            self.outbox.append(items)

    async def _voice(self, sentence: str) -> bytes:
        if sentence in (ACK, NOT_HEARD) and sentence in self._canned:
            return self._canned[sentence]
        audio = await self.mouth.speak(sentence)
        if sentence in (ACK, NOT_HEARD):
            self._canned[sentence] = audio
        return audio

    def _write_log(self, log: dict) -> None:
        print(json.dumps(log, ensure_ascii=False))
        if self.log_path is None:
            return
        self.log_path.parent.mkdir(parents=True, exist_ok=True)
        with self.log_path.open("a", encoding="utf-8") as f:
            f.write(json.dumps(log, ensure_ascii=False) + "\n")


async def main() -> None:
    from websockets.asyncio.server import serve

    from brain import Brain
    from ears import Ears
    from mouth import Mouth

    cfg = json.loads((HERE / "config.json").read_text(encoding="utf-8"))
    ears = Ears(cfg["asr_model"], context=cfg.get("asr_context", ""))
    brain = Brain(claude=cfg.get("claude", ""), model=cfg.get("claude_model", ""), tools=cfg.get("claude_tools"))
    mouth = Mouth(voice=cfg.get("voice", "Meijia"), rate=cfg.get("voice_rate", 0))
    mac_listens = cfg.get("asr", "phone") == "mac"
    hub = Hub(ears, brain, mouth, ack_after=cfg.get("ack_after_seconds", 3),
              max_task_seconds=cfg.get("max_task_seconds", 300), warm_on_start=mac_listens)

    if mac_listens:
        print("載入語音辨識模型…")
        started = time.monotonic()
        await asyncio.wrap_future(ears.load())
        print(f"模型好了（{time.monotonic() - started:.1f} 秒）")
    else:
        # iPhone 自己聽懂；手機聽不了的那幾句才臨時載入模型（這台 Mac 的 GPU 常出錯，平常不碰）
        print("由 iPhone 聽懂你講的話；Mac 只在手機聽不了時才用 Qwen3-ASR")
    for sentence in (ACK, NOT_HEARD):
        await hub._voice(sentence)  # 先念好，要用時不用等

    # 聽所有網路介面，但只放 Tailscale 和本機進來（is_allowed）；Tailscale 晚一點才連上也沒關係
    async with serve(hub.handle, None, cfg["port"], max_size=None, ping_interval=20, ping_timeout=20):
        print(f"小呆呆服務開好了，port {cfg['port']}")
        await keep_warm(ears, cfg.get("keep_warm_seconds", 10) if mac_listens else 0)


async def keep_warm(ears, every: float) -> None:
    """每隔一陣子碰一下語音模型，免得被系統壓縮到硬碟（0 就是不碰）。"""
    if not every:
        await asyncio.Future()
    while True:
        await asyncio.sleep(every)
        try:
            await asyncio.wrap_future(ears.touch())
        except Exception as exc:
            print(f"保持清醒時出錯：{exc!r}")
            if is_gpu_error(exc):
                restart_soon("保持清醒時 GPU 出錯")
                await asyncio.Future()  # 等程式結束


if __name__ == "__main__":
    sys.stdout.reconfigure(line_buffering=True)  # 開機自動跑時，紀錄才會即時寫進 log
    with contextlib.suppress(KeyboardInterrupt):
        asyncio.run(main())
