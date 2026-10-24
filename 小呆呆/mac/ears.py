"""耳朵：用 Qwen3-ASR 把手機傳來的聲音轉成繁體中文字。

跟語音輸入.app 用同一個模型（已壓縮成 8-bit 的那份），整個在 Mac 上跑、不連網。
"""

from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import numpy as np
from opencc import OpenCC

WIRED_MARGIN = 512 * 1024 * 1024  # 模型以外，再留一點給辨識時的暫存資料


class Ears:
    def __init__(self, model_dir: str, context: str = "", convert: str = "s2tw"):
        self.model_dir = Path(model_dir).expanduser()
        self.context = context
        # 只轉字形（s2tw）：「台灣用語」模式（s2twp）會把「對象」改成「物件」
        self._opencc = OpenCC(convert) if convert else None
        self._session = None
        self._weights = None
        # MLX 的模型要在同一條執行緒載入和使用，所以全部丟給這一條
        self._thread = ThreadPoolExecutor(max_workers=1, thread_name_prefix="ears")

    def load(self):
        """在耳朵自己的執行緒載入模型；回傳 Future。"""
        return self._thread.submit(self._load)

    def transcribe(self, audio: np.ndarray, sample_rate: int):
        """回傳 Future，結果是繁體中文字（聽不到東西就是空字串）。"""
        return self._thread.submit(self._transcribe, audio, sample_rate)

    def warm(self):
        """手機開始傳聲音時先叫醒模型。

        這台 Mac 記憶體很緊，模型閒置一下就會被擠到硬碟，再用要多等幾秒；
        趁 Rino 還在講話時先搬回來，講完就能馬上辨識。
        """
        return self._thread.submit(self._warm)

    def touch(self):
        """碰一下模型（Rino 選的，2026-10-24）。

        只叫醒還不夠：閒置十幾分鐘後模型幾乎整個被系統壓縮，第一句要等約 7 秒。
        每 10 秒把權重全部讀一次（約 0.4 秒），系統就不會挑它壓縮，辨識一直維持 0.3 秒。
        """
        return self._thread.submit(self._touch)

    def _touch(self) -> None:
        if self._session is None:
            return
        import mlx.core as mx
        from mlx.utils import tree_flatten

        if self._weights is None:
            self._weights = [w for _, w in tree_flatten(self._session.model.parameters())]
        mx.eval([w.sum() for w in self._weights])

    def _load(self) -> None:
        if self._session is not None:
            return
        if not self.model_dir.exists():
            raise FileNotFoundError(f"找不到語音辨識模型 {self.model_dir}：先打開語音輸入.app 一次，它會準備好")
        import mlx.core as mx
        from mlx_qwen3_asr import Session
        from mlx_qwen3_asr.load_models import load_model

        # 先設好上限再載入，模型才會被固定在記憶體（實測閒置 40 秒後：20 秒變 3 秒）
        size = sum(f.stat().st_size for f in self.model_dir.glob("*.safetensors"))
        try:
            mx.set_wired_limit(size + WIRED_MARGIN)
        except Exception as exc:
            print(f"⚠️  沒辦法把模型固定在記憶體：{exc!r}")
        model, _ = load_model(str(self.model_dir))
        session = Session(model=model, tokenizer_model=str(self.model_dir))
        session.transcribe(np.zeros(16000, dtype=np.float32))  # 預熱
        self._session = session

    def _warm(self) -> None:
        self._load()
        self._session.transcribe(np.zeros(8000, dtype=np.float32))

    def _transcribe(self, audio: np.ndarray, sample_rate: int) -> str:
        self._load()
        if audio.size < sample_rate // 5:  # 不到 0.2 秒，當作沒講話
            return ""
        try:
            result = self._session.transcribe((audio, sample_rate), context=self.context)
        except RuntimeError as exc:
            # 別的程式讓 GPU 重置時，這一次的計算會被丟掉；再做一次就好
            if "Command buffer execution failed" not in str(exc):
                raise
            print(f"GPU 出錯，重新辨識一次：{exc}")
            result = self._session.transcribe((audio, sample_rate), context=self.context)
        text = result.text.strip()
        if self._opencc:
            # s2tw 會把「台」寫成「臺」；平常大家寫「台」
            text = self._opencc.convert(text).replace("臺", "台")
        return text
