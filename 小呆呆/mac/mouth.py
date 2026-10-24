"""嘴巴：用 Mac 內建的美佳把字念成 WAV，傳回手機播。"""

from __future__ import annotations

import asyncio
import tempfile
from pathlib import Path


class Mouth:
    def __init__(self, voice: str = "Meijia", rate: int = 0, sample_rate: int = 22050):
        self.voice = voice
        self.rate = rate  # 每分鐘幾個字；0 就用美佳預設的速度
        self.sample_rate = sample_rate

    async def speak(self, text: str) -> bytes:
        with tempfile.TemporaryDirectory(prefix="xiaodaidai-") as tmp:
            path = Path(tmp) / "say.wav"
            cmd = ["say", "-v", self.voice, "--file-format=WAVE",
                   f"--data-format=LEI16@{self.sample_rate}", "-o", str(path), "-f", "-"]
            if self.rate:
                cmd += ["-r", str(self.rate)]
            # 字從標準輸入給，開頭是「-」的句子才不會被當成參數
            proc = await asyncio.create_subprocess_exec(
                *cmd, stdin=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
            _, err = await proc.communicate(text.encode("utf-8"))
            if proc.returncode != 0 or not path.exists():
                raise RuntimeError(f"美佳念不出來：{err.decode(errors='replace').strip()}")
            return path.read_bytes()
