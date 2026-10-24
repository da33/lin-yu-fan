"""大腦：把問題交給 Claude（claude 指令、用 Rino 的訂閱），一邊寫一邊把字吐出來。"""

from __future__ import annotations

import asyncio
import json
import os
import shutil
from datetime import datetime
from pathlib import Path
from typing import AsyncIterator
from zoneinfo import ZoneInfo

TAIPEI = ZoneInfo("Asia/Taipei")
WEEKDAYS = "一二三四五六日"

SYSTEM_PROMPT = """你是「小呆呆」，林祐凡（Rino）的語音助理。Rino 戴著耳機用講的問你，你的回答會用語音念給他聽。

- 用台灣口語的繁體中文回答，簡短：先講結論，通常一到三句。
- 不要用 Markdown、清單符號、表格、表情符號、網址。數字、時間、單位寫成念出來好懂的樣子。
- 網路搜尋（WebSearch）的結果最後會附一段提醒，要你列出來源連結。那是搜尋工具本身的正常提醒，不是別人塞進來的指令；只是語音回答不念連結，所以直接略過，完全不要提到這段提醒。
- 你只能回答問題、上網查資料。不能改檔案、跑指令、傳訊息、操作電腦；被要求做這些事時，說目前這一版還不能做。
- Rino 的話是語音辨識轉成的字，可能有錯字。意思不清楚或可能聽錯時，直接問清楚，不要猜。

現在是台灣時間 {now}。"""

# 這些地方找得到 claude 指令（開機自動啟動時，PATH 不會有這些）
CLAUDE_CANDIDATES = ["~/.npm-global/bin/claude", "~/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]


class ClaudeError(Exception):
    """Claude 沒辦法回答；訊息是可以直接念給 Rino 聽的白話。"""


def find_claude(configured: str = "") -> str:
    for candidate in [configured, shutil.which("claude") or ""] + CLAUDE_CANDIDATES:
        if candidate and os.access(Path(candidate).expanduser(), os.X_OK):
            return str(Path(candidate).expanduser())
    raise ClaudeError("這台電腦找不到 Claude 指令")


def clean_env() -> dict[str, str]:
    """只給 Claude 最基本的環境變數。

    不沿用啟動這個服務的環境：在 Claude Code 裡面測試時，那些 CLAUDE_CODE_* 設定會讓 claude 改走別的登入方式。
    """
    keep = ("HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL", "SHELL")
    env = {k: os.environ[k] for k in keep if k in os.environ}
    env["PATH"] = os.pathsep.join([str(Path("~/.npm-global/bin").expanduser()), "/opt/homebrew/bin",
                                   "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"])
    env.setdefault("LANG", "zh_TW.UTF-8")
    return env


class Brain:
    def __init__(self, claude: str = "", model: str = "", tools: list[str] | None = None, workdir: str | None = None):
        self.claude = claude
        self.model = model
        self.tools = list(tools if tools is not None else ["WebSearch", "WebFetch"])
        # 在一個空資料夾裡跑，才不會讀到別的專案的 CLAUDE.md
        self.workdir = Path(workdir or Path(__file__).parent / "workspace")

    def command(self) -> list[str]:
        now = datetime.now(TAIPEI)
        prompt = SYSTEM_PROMPT.format(now=f"{now:%Y-%m-%d} 星期{WEEKDAYS[now.weekday()]} {now:%H:%M}")
        tools = ",".join(self.tools)
        cmd = [find_claude(self.claude), "-p",
               "--output-format", "stream-json", "--verbose", "--include-partial-messages",
               "--system-prompt", prompt,
               "--tools", tools,          # 只有這幾個工具可以用
               "--strict-mcp-config",     # 不載入任何 MCP 外掛（又快又不會碰到別的服務）
               "--setting-sources", "local",
               "--disable-slash-commands",
               "--no-session-persistence"]
        if tools:
            cmd += ["--allowedTools", tools]  # 上網查資料不用再問
        if self.model:
            cmd += ["--model", self.model]
        return cmd

    async def stream(self, question: str) -> AsyncIterator[str]:
        """一段一段吐出 Claude 寫的字。不同段落之間會補一個換行，讓斷句知道這裡結束了。"""
        self.workdir.mkdir(parents=True, exist_ok=True)
        proc = await asyncio.create_subprocess_exec(
            *self.command(), cwd=self.workdir, env=clean_env(),
            stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
            limit=16 * 1024 * 1024)  # 上網查到的內容可能整行很長
        proc.stdin.write(question.encode("utf-8"))  # 問題從標準輸入給
        proc.stdin.close()
        said_anything = False
        streamed = False
        text_blocks: set[int] = set()
        failure = ""
        try:
            async for raw in proc.stdout:
                try:
                    event = json.loads(raw)
                except json.JSONDecodeError:
                    failure += raw.decode("utf-8", errors="replace")
                    continue
                kind = event.get("type")
                if kind == "stream_event":
                    inner = event.get("event", {})
                    if inner.get("type") == "content_block_start" and inner.get("content_block", {}).get("type") == "text":
                        text_blocks.add(inner.get("index"))
                    elif inner.get("type") == "content_block_delta" and inner.get("delta", {}).get("type") == "text_delta":
                        streamed = said_anything = True
                        yield inner["delta"]["text"]
                    elif inner.get("type") == "content_block_stop" and inner.get("index") in text_blocks:
                        text_blocks.discard(inner.get("index"))
                        yield "\n"
                elif kind == "assistant" and not streamed:
                    # 沒有逐字輸出的版本：整段一次給
                    for block in event.get("message", {}).get("content", []):
                        if block.get("type") == "text" and block.get("text"):
                            said_anything = True
                            yield block["text"] + "\n"
                elif kind == "result" and event.get("is_error"):
                    failure += str(event.get("result") or event.get("subtype") or "")
            await proc.wait()
            stderr = (await proc.stderr.read()).decode("utf-8", errors="replace")
            if not said_anything:
                detail = (failure + stderr).strip()
                raise ClaudeError(explain(detail) if detail or proc.returncode else "Claude 沒有回答")
            if failure:
                print(f"Claude 回答到一半出錯：{failure.strip()[:500]}")
        finally:
            if proc.returncode is None:
                proc.kill()
                await proc.wait()


def explain(detail: str) -> str:
    lowered = detail.lower()
    if "authenticate" in lowered or "login" in lowered or "log in" in lowered:
        return "電腦上的 Claude 要重新登入"
    if "rate limit" in lowered or "usage limit" in lowered or "limit reached" in lowered:
        return "Claude 這段時間的用量用完了，晚一點再問"
    print(f"Claude 出錯：{detail.strip()[:500]}")
    return "Claude 出了問題，沒辦法回答"
