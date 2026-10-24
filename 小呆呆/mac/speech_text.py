"""把 Claude 一邊寫出來的字切成一句一句，並整理成適合念出來的樣子。"""

from __future__ import annotations

import re

SENTENCE_ENDS = "。！？!?；;\n"
COMMAS = "，、,："

_URL = re.compile(r"https?://\S+")
_MARKDOWN_LINK = re.compile(r"\[([^\]]*)\]\([^)]*\)")
_LINE_PREFIX = re.compile(r"^\s*(?:#{1,6}\s+|>\s*|[-*•]\s+|\d+[.)]\s+)", re.MULTILINE)
_SYMBOLS = re.compile(r"[*_`#|~]+")
_SPACES = re.compile(r"\s+")
_SPEAKABLE = re.compile(r"[0-9A-Za-z㐀-鿿]")
# 手機叫醒後會連喚醒詞的尾巴一起錄進來，例如「呆，今天幾點」
_WAKE_WORD = re.compile(r"^[\s，,。.、！!？?]*(?:小?呆呆|呆)[\s，,。.、！!？?]*")


def strip_wake_word(text: str) -> str:
    return _WAKE_WORD.sub("", text, count=1).strip()


class SentenceSplitter:
    """一段一段餵字進來，湊滿一句就吐出來。

    第一句特別早切（遇到逗號、夠長就切），讓手機越早開始念越好。
    """

    def __init__(self, first_min_chars: int = 6, soft_limit: int = 50):
        self.first_min_chars = first_min_chars
        self.soft_limit = soft_limit
        self._buffer = ""
        self._emitted = 0

    def feed(self, piece: str) -> list[str]:
        self._buffer += piece
        sentences = []
        while True:
            cut = self._find_cut()
            if cut is None:
                break
            sentence, self._buffer = self._buffer[:cut], self._buffer[cut:]
            if sentence.strip():
                sentences.append(sentence.strip())
                self._emitted += 1
        return sentences

    def flush(self) -> list[str]:
        rest, self._buffer = self._buffer.strip(), ""
        return [rest] if rest else []

    def _find_cut(self) -> int | None:
        for i, ch in enumerate(self._buffer):
            if ch in SENTENCE_ENDS:
                return i + 1
        if self._emitted == 0:
            # 第一句：夠長之後遇到第一個逗號就先念，不等整句
            for i, ch in enumerate(self._buffer):
                if ch in COMMAS and i + 1 >= self.first_min_chars:
                    return i + 1
        elif len(self._buffer) >= self.soft_limit:
            # 很長都沒有句號：從最後一個逗號切
            last = max(self._buffer.rfind(c) for c in COMMAS)
            if last > 0:
                return last + 1
        return None


def for_speech(text: str) -> str:
    """拿掉念出來會很怪的東西：Markdown 符號、網址、清單編號。沒有可以念的字就回傳空字串。"""
    text = _MARKDOWN_LINK.sub(r"\1", text)
    text = _URL.sub("", text)
    text = _LINE_PREFIX.sub("", text)
    text = _SYMBOLS.sub("", text)
    text = _SPACES.sub(" ", text).strip()
    return text if _SPEAKABLE.search(text) else ""
