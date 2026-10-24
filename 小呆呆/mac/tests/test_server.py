"""用假的耳朵、大腦、嘴巴，透過真的 WebSocket 測一輪對話的流程。"""

import asyncio
import json
from concurrent.futures import Future

import numpy as np
from websockets.asyncio.client import connect
from websockets.asyncio.server import serve

from brain import ClaudeError
from server import ACK, GPU_BROKEN, NOT_HEARD, Hub, Utterance, is_allowed


class FakeEars:
    def __init__(self, text):
        self.text = text
        self.warmed = 0
        self.transcribed = 0

    def warm(self):
        self.warmed += 1
        future = Future()
        future.set_result(None)
        return future

    def transcribe(self, audio, sample_rate):
        self.transcribed += 1
        future = Future()
        future.set_result(self.text)
        return future


class FakeBrain:
    def __init__(self, pieces=(), delay=0.0, error=None):
        self.pieces = pieces
        self.delay = delay
        self.error = error

    async def stream(self, question):
        await asyncio.sleep(self.delay)
        if self.error:
            raise ClaudeError(self.error)
        for piece in self.pieces:
            yield piece


class FakeMouth:
    async def speak(self, text):
        return f"WAV:{text}".encode()


def run_with_server(hub, scenario):
    async def main():
        async with serve(hub.handle, "127.0.0.1", 0) as server:
            port = server.sockets[0].getsockname()[1]
            return await asyncio.wait_for(scenario(f"ws://127.0.0.1:{port}"), timeout=5)
    return asyncio.run(main())


async def ask(ws, seconds=0.5, **end):
    await ws.send(json.dumps({"type": "start", "sampleRate": 16000}))
    await ws.send(np.zeros(int(16000 * seconds), dtype="<i2").tobytes())
    await ws.send(json.dumps({"type": "end", **end}))


async def collect(ws, until_done_kinds=("answer", "report")):
    """收訊息到某一輪結束；聲音接在對應的 say 後面。"""
    events = []
    async for message in ws:
        if isinstance(message, bytes):
            events[-1]["audio"] = message
            continue
        data = json.loads(message)
        events.append(data)
        if data["type"] == "done" and data["kind"] in until_done_kinds:
            return events


def summary(events):
    return [(e["type"], e.get("kind"), e.get("text")) for e in events]


def make_hub(ears_text="一天有幾小時", brain=None, **kw):
    kw.setdefault("audio_dir", None)
    return Hub(FakeEars(ears_text), brain or FakeBrain(["一天有二十四小時。"]), FakeMouth(), log_path=None, **kw)


def test_quick_answer_is_spoken_directly():
    hub = make_hub(brain=FakeBrain(["一天有", "二十四小時。"]))

    async def scenario(url):
        async with connect(url) as ws:
            await ask(ws)
            return await collect(ws)

    events = run_with_server(hub, scenario)
    assert summary(events) == [
        ("heard", None, "一天有幾小時"),
        ("say", "answer", "一天有二十四小時。"),
        ("done", "answer", None),
    ]
    assert events[1]["audio"] == "WAV:一天有二十四小時。".encode()
    assert events[1]["question"] == "一天有幾小時"
    assert hub.ears.warmed == 1  # 一開始講話就先叫醒模型


def test_slow_answer_acks_then_reports():
    hub = make_hub(brain=FakeBrain(["查好了，明天會下雨。"], delay=0.3), ack_after=0.1)

    async def scenario(url):
        async with connect(url) as ws:
            await ask(ws)
            return await collect(ws)

    assert summary(run_with_server(hub, scenario)) == [
        ("heard", None, "一天有幾小時"),
        ("say", "ack", ACK),
        ("done", "ack", None),
        ("say", "report", "查好了，明天會下雨。"),
        ("done", "report", None),
    ]


def test_report_waits_until_phone_reconnects():
    hub = make_hub(brain=FakeBrain(["做好了。"], delay=0.3), ack_after=0.1)

    async def scenario(url):
        async with connect(url) as ws:
            await ask(ws)
            await collect(ws, until_done_kinds=("ack",))
        await asyncio.sleep(0.4)  # 手機不在的時候做完了
        assert len(hub.outbox) == 1
        async with connect(url) as ws:
            return await collect(ws)

    assert summary(run_with_server(hub, scenario)) == [("say", "report", "做好了。"), ("done", "report", None)]
    assert hub.outbox == []


def test_nothing_heard():
    hub = make_hub(ears_text="")

    async def scenario(url):
        async with connect(url) as ws:
            await ask(ws)
            return await collect(ws)

    assert summary(run_with_server(hub, scenario)) == [
        ("heard", None, ""),
        ("say", "answer", NOT_HEARD),
        ("done", "answer", None),
    ]


def test_claude_error_is_spoken():
    hub = make_hub(brain=FakeBrain(error="電腦上的 Claude 要重新登入"))

    async def scenario(url):
        async with connect(url) as ws:
            await ask(ws)
            return await collect(ws)

    assert summary(run_with_server(hub, scenario))[1:] == [
        ("say", "error", "電腦上的 Claude 要重新登入"),
        ("done", "answer", None),
    ]


def test_claude_error_after_ack_becomes_report():
    hub = make_hub(brain=FakeBrain(error="Claude 出了問題，沒辦法回答", delay=0.3), ack_after=0.1)

    async def scenario(url):
        async with connect(url) as ws:
            await ask(ws)
            return await collect(ws)

    assert summary(run_with_server(hub, scenario))[-2:] == [
        ("say", "report", "剛才「一天有幾小時」沒做成：Claude 出了問題，沒辦法回答。"),
        ("done", "report", None),
    ]


def test_gpu_error_tells_phone_and_restarts():
    fatal = []
    ears = FakeEars("")
    ears.transcribe = lambda audio, rate: failed_future(RuntimeError("[METAL] Command buffer execution failed: Ignored"))
    hub = Hub(ears, FakeBrain(), FakeMouth(), log_path=None, on_fatal=fatal.append, audio_dir=None)

    async def scenario(url):
        async with connect(url) as ws:
            await ask(ws)
            return await collect(ws)

    assert summary(run_with_server(hub, scenario)) == [("say", "error", GPU_BROKEN), ("done", "answer", None)]
    assert len(fatal) == 1


def failed_future(exc):
    future = Future()
    future.set_exception(exc)
    return future


def test_answer_goes_back_to_the_phone_that_asked():
    """兩條連線同時在（換網路時、或模擬器和真手機）：誰問的就回給誰，另一條不受影響。"""
    hub = make_hub()

    async def scenario(url):
        async with connect(url) as first, connect(url) as second:
            await asyncio.sleep(0.1)
            assert len(hub.phones) == 2
            await ask(first)
            events = await collect(first)
            await second.send(json.dumps({"type": "ping"}))
            assert json.loads(await second.recv()) == {"type": "pong"}  # 第二條沒被踢掉，也沒收到別人的回答
            return events

    assert summary(run_with_server(hub, scenario))[-1] == ("done", "answer", None)


def test_report_goes_to_newest_phone_if_asker_left():
    hub = make_hub(brain=FakeBrain(["做好了。"], delay=0.3), ack_after=0.1)

    async def scenario(url):
        async with connect(url) as other:
            async with connect(url) as asker:
                await ask(asker)
                await collect(asker, until_done_kinds=("ack",))
            return await collect(other)

    assert summary(run_with_server(hub, scenario)) == [("say", "report", "做好了。"), ("done", "report", None)]


def test_only_local_and_tailscale_allowed():
    assert is_allowed("127.0.0.1")
    assert is_allowed("::1")
    assert is_allowed("100.101.102.103")
    assert is_allowed("::ffff:100.64.0.1")
    assert is_allowed("fd7a:115c:a1e0::1")
    assert not is_allowed("192.168.1.5")
    assert not is_allowed("8.8.8.8")
    assert not is_allowed("not-an-ip")


def test_pcm_converted_to_float():
    u = Utterance(16000, [np.array([0, 16384, -32768], dtype="<i2").tobytes()])
    assert np.allclose(u.samples(), [0.0, 0.5, -1.0])


def test_uses_what_the_phone_heard():
    hub = make_hub(ears_text="Mac 聽的")

    async def scenario(url):
        async with connect(url) as ws:
            await ask(ws, text="小呆呆，一天有幾小時？", engine="DictationTranscriber", phoneSeconds=0.3)
            return await collect(ws)

    assert summary(run_with_server(hub, scenario))[0] == ("heard", None, "一天有幾小時？")
    assert hub.ears.transcribed == 0  # 手機聽到了，Mac 就不用 GPU


def test_mac_listens_when_phone_heard_nothing():
    hub = make_hub(ears_text="一天有幾小時")

    async def scenario(url):
        async with connect(url) as ws:
            await ask(ws, text="  ")
            return await collect(ws)

    assert summary(run_with_server(hub, scenario))[0] == ("heard", None, "一天有幾小時")
    assert hub.ears.transcribed == 1


def test_saves_each_question_audio(tmp_path):
    hub = make_hub(audio_dir=tmp_path)

    async def scenario(url):
        async with connect(url) as ws:
            await ask(ws, seconds=1.0, text="一天有幾小時")
            return await collect(ws)

    run_with_server(hub, scenario)
    files = list(tmp_path.glob("*.wav"))
    assert len(files) == 1
    import wave
    with wave.open(str(files[0])) as w:
        assert (w.getframerate(), w.getnframes()) == (16000, 16000)
