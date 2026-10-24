"""假裝是手機：把一句話的聲音照真實速度傳給小呆呆服務，收回答、存成 WAV、算時間。

用法：
  uv run python fake_phone.py "一天有幾小時？"        用美佳念這句話當成你講的
  uv run python fake_phone.py --wav 問題.wav          用錄好的聲音（16 kHz 單聲道 WAV）
  加 --play 會把回答播出來
"""

from __future__ import annotations

import argparse
import asyncio
import json
import subprocess
import sys
import tempfile
import time
import wave
from pathlib import Path

from websockets.asyncio.client import connect

HERE = Path(__file__).parent
SAMPLE_RATE = 16000
CHUNK_SECONDS = 0.1


def question_audio(text: str) -> bytes:
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "q.wav"
        subprocess.run(["say", "-v", "Meijia", "--file-format=WAVE", f"--data-format=LEI16@{SAMPLE_RATE}",
                        "-o", str(path), text], check=True)
        return read_pcm(path)


def read_pcm(path: Path) -> bytes:
    with wave.open(str(path)) as w:
        if w.getframerate() != SAMPLE_RATE or w.getnchannels() != 1 or w.getsampwidth() != 2:
            sys.exit(f"{path} 要是 16 kHz、單聲道、16-bit 的 WAV")
        return w.readframes(w.getnframes())


async def run(pcm: bytes, url: str, play: bool) -> None:
    out = HERE / "logs" / "fake_phone"
    out.mkdir(parents=True, exist_ok=True)
    async with connect(url, max_size=None) as ws:
        await ws.send(json.dumps({"type": "start", "sampleRate": SAMPLE_RATE}))
        step = int(SAMPLE_RATE * CHUNK_SECONDS) * 2
        for i in range(0, len(pcm), step):  # 跟真的講話一樣，一邊講一邊傳
            await ws.send(pcm[i:i + step])
            await asyncio.sleep(CHUNK_SECONDS)
        ended = time.monotonic()
        await ws.send(json.dumps({"type": "end"}))
        print(f"講完了（{len(pcm) / 2 / SAMPLE_RATE:.1f} 秒的話）")

        pending = None
        count = 0
        async for message in ws:
            elapsed = time.monotonic() - ended
            if isinstance(message, bytes):
                count += 1
                path = out / f"{count:02d}-{pending['kind']}.wav"
                path.write_bytes(message)
                if play:
                    subprocess.run(["afplay", str(path)])
                continue
            data = json.loads(message)
            if data["type"] == "heard":
                print(f"{elapsed:5.2f}s 聽成：{data['text']}")
            elif data["type"] == "say":
                pending = data
                print(f"{elapsed:5.2f}s [{data['kind']}] {data['text']}")
            elif data["type"] == "done":
                print(f"{elapsed:5.2f}s 這輪結束（{data['kind']}）")
                if data["kind"] in ("answer", "report"):
                    break
    print(f"回答的聲音存在 {out}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("question", nargs="?", help="要問的話（用美佳念出來當成你講的）")
    parser.add_argument("--wav", type=Path, help="改用錄好的聲音")
    parser.add_argument("--url", default="ws://127.0.0.1:8787")
    parser.add_argument("--play", action="store_true", help="把回答播出來")
    args = parser.parse_args()
    if not args.question and not args.wav:
        parser.error("給一句話，或用 --wav 給聲音檔")
    pcm = read_pcm(args.wav) if args.wav else question_audio(args.question)
    asyncio.run(run(pcm, args.url, args.play))


if __name__ == "__main__":
    main()
