"""比較 iPhone 和 Mac 誰聽得準：把存下來的每句聲音用 Mac 的 Qwen3-ASR 再聽一次，跟 iPhone 當時聽到的字並排。

用法：
  uv run python compare_asr.py          只跑還沒比過的
  uv run python compare_asr.py --all    全部重跑
結果存在 logs/compare.jsonl，同時印成表格。
"""

from __future__ import annotations

import argparse
import json
import re
import wave
from pathlib import Path

import numpy as np

from ears import Ears
from speech_text import strip_wake_word

HERE = Path(__file__).parent
LOGS = HERE / "logs"
RESULTS = LOGS / "compare.jsonl"


def same_words(a: str, b: str) -> bool:
    """只比字，不管標點和空白"""
    return re.sub(r"[\W_]+", "", a) == re.sub(r"[\W_]+", "", b)


def read_jsonl(path: Path) -> list[dict]:
    if not path.exists():
        return []
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]


def read_wav(path: Path) -> tuple[np.ndarray, int]:
    with wave.open(str(path)) as w:
        pcm = np.frombuffer(w.readframes(w.getnframes()), dtype="<i2")
        return pcm.astype(np.float32) / 32768, w.getframerate()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--all", action="store_true", help="全部重跑")
    args = parser.parse_args()

    # phone:test 是自動測試送的假結果，不算
    turns = [t for t in read_jsonl(LOGS / "turns.jsonl")
             if t.get("audio") and str(t.get("asr", "")).startswith("phone") and t["asr"] != "phone:test"]
    done = {} if args.all else {row["audio"]: row for row in read_jsonl(RESULTS)}
    todo = [t for t in turns if t["audio"] not in done and (LOGS / "audio" / t["audio"]).exists()]

    if todo:
        cfg = json.loads((HERE / "config.json").read_text(encoding="utf-8"))
        ears = Ears(cfg["asr_model"], context=cfg.get("asr_context", ""))
        print(f"用 Mac 的 Qwen3-ASR 重聽 {len(todo)} 句…")
        ears.load().result()
        for turn in todo:
            audio, rate = read_wav(LOGS / "audio" / turn["audio"])
            mac = strip_wake_word(ears.transcribe(audio, rate).result())
            done[turn["audio"]] = {"audio": turn["audio"], "time": turn["time"],
                                   "engine": turn["asr"].removeprefix("phone:"), "phone": turn["heard"], "mac": mac}
        RESULTS.write_text("".join(json.dumps(row, ensure_ascii=False) + "\n" for row in done.values()),
                           encoding="utf-8")

    rows = sorted((row for row in done.values() if row["engine"] != "test"), key=lambda row: row["time"])
    if not rows:
        print("還沒有可以比的句子：手機用 iPhone 聽懂的那幾句才會存下來比較。")
        return
    same = sum(same_words(row["phone"], row["mac"]) for row in rows)
    print(f"\n共 {len(rows)} 句，兩邊一樣 {same} 句\n")
    for row in rows:
        mark = "＝" if same_words(row["phone"], row["mac"]) else "≠"
        print(f"{row['time'][5:16].replace('T', ' ')}  {mark}  iPhone：{row['phone']}")
        print(f"{'':13}     Mac   ：{row['mac']}")


if __name__ == "__main__":
    main()
