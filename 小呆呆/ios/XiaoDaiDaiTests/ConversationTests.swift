import AVFoundation
import XCTest
@testable import XiaoDaiDai

/// 叫醒之後的部分：判斷講完了沒、轉成 16 kHz、讀懂 Mac 的訊息、播回答
final class ConversationTests: XCTestCase {
    // MARK: - 判斷講完了沒

    func testFinishesAfterOneSecondOfSilence() {
        var eos = EndOfSpeech(noiseFloor: 0.002)
        XCTAssertEqual(feed(&eos, rms: 0.002, seconds: 0.5), .keepGoing)  // 叮之後還沒開口
        XCTAssertEqual(feed(&eos, rms: 0.05, seconds: 1.5), .keepGoing)   // 在講話
        XCTAssertEqual(feed(&eos, rms: 0.002, seconds: 0.9), .keepGoing)  // 停頓不到 1 秒
        XCTAssertEqual(feed(&eos, rms: 0.002, seconds: 0.2), .finished)
        XCTAssertEqual(eos.spoken, 1.5, accuracy: 0.11)
    }

    func testShortPauseInTheMiddleDoesNotEnd() {
        var eos = EndOfSpeech(noiseFloor: 0.002)
        _ = feed(&eos, rms: 0.05, seconds: 1.0)
        XCTAssertEqual(feed(&eos, rms: 0.002, seconds: 0.6), .keepGoing)
        XCTAssertEqual(feed(&eos, rms: 0.05, seconds: 1.0), .keepGoing)
        XCTAssertEqual(feed(&eos, rms: 0.002, seconds: 1.0), .finished)
    }

    /// 叫醒後最前面一小段是「小呆呆」的尾巴，不能算成你在問問題
    func testWakeWordTailIsIgnored() {
        var eos = EndOfSpeech(noiseFloor: 0.002)
        XCTAssertEqual(feed(&eos, rms: 0.08, seconds: 0.3), .keepGoing)
        XCTAssertFalse(eos.heardSpeech)
        XCTAssertEqual(feed(&eos, rms: 0.002, seconds: 1.5), .keepGoing)  // 只有尾巴，不算講完
    }

    func testGivesUpWhenNothingSaid() {
        var eos = EndOfSpeech(noiseFloor: 0.002)
        XCTAssertEqual(feed(&eos, rms: 0.002, seconds: 5.9), .keepGoing)
        XCTAssertEqual(feed(&eos, rms: 0.002, seconds: 0.2), .nothingSaid)
    }

    func testLongQuestionIsSentAtMaxLength() {
        var eos = EndOfSpeech(noiseFloor: 0.002)
        XCTAssertEqual(feed(&eos, rms: 0.05, seconds: 29.9), .keepGoing)
        XCTAssertEqual(feed(&eos, rms: 0.05, seconds: 0.2), .finished)
    }

    func testThresholdFollowsNoiseWithLimits() {
        XCTAssertEqual(EndOfSpeech(noiseFloor: 0.0001).threshold, 0.006)  // 很安靜：至少要這麼大聲
        XCTAssertEqual(EndOfSpeech(noiseFloor: 0.01).threshold, 0.03, accuracy: 0.0001)
        XCTAssertEqual(EndOfSpeech(noiseFloor: 0.1).threshold, 0.05)      // 很吵：也不會高到聽不到你
    }

    func testNoiseFloorFallsFastRisesSlowly() {
        var floor = NoiseFloor()
        for _ in 0..<20 { floor.update(0.002) }
        XCTAssertEqual(floor.value, 0.002, accuracy: 0.0005)
        for _ in 0..<12 { floor.update(0.05) }  // 喊「小呆呆」約 1 秒
        XCTAssertLessThan(floor.value, 0.006)
    }

    // MARK: - 轉成 16 kHz

    func testResamplesTo16kInChunks() throws {
        let resampler = try XCTUnwrap(Resampler16k(inputRate: 48_000))
        let second = (0..<48_000).map { Float(sin(2 * Double.pi * 440 * Double($0) / 48_000) * 0.5) }
        var total = 0
        for start in stride(from: 0, to: second.count, by: 4096) {
            total += resampler.convert(Array(second[start..<min(start + 4096, second.count)])).count
        }
        XCTAssertEqual(Double(total) / 2, 16_000, accuracy: 300)  // 16-bit：一個樣本 2 bytes
    }

    // MARK: - 讀懂 Mac 的訊息

    func testParsesHeardSayAndDone() {
        var parser = MacMessageParser()
        XCTAssertEqual(parser.text(#"{"type":"heard","turn":1,"text":"一天有幾小時？"}"#), .heard("一天有幾小時？"))
        XCTAssertNil(parser.text(#"{"type":"say","turn":1,"kind":"answer","text":"二十四小時。","question":"一天有幾小時？"}"#))
        XCTAssertEqual(parser.binary(Data([1, 2, 3])),
                       .say(MacLink.Speech(kind: "answer", text: "二十四小時。", question: "一天有幾小時？", audio: Data([1, 2, 3]))))
        XCTAssertEqual(parser.text(#"{"type":"done","turn":1,"kind":"report"}"#), .done(kind: "report"))
    }

    func testIgnoresAudioWithoutSayAndUnknownMessages() {
        var parser = MacMessageParser()
        XCTAssertNil(parser.binary(Data([1])))
        XCTAssertNil(parser.text(#"{"type":"pong"}"#))
        XCTAssertNil(parser.text("不是 JSON"))
    }

    // MARK: - 播回答

    func testDecodesWavForPlayer() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "question-16k", withExtension: "wav"))
        let buffer = try XCTUnwrap(SpeechAudio.decode(try Data(contentsOf: url)))
        XCTAssertEqual(buffer.format, Chime.format)
        let seconds = Double(buffer.frameLength) / Chime.format.sampleRate
        XCTAssertEqual(seconds, 1.2, accuracy: 0.6)
    }

    func testBundledOfflineNoticesExist() {
        XCTAssertNotNil(SpeechAudio.bundled("no-mac"))
        XCTAssertNotNil(SpeechAudio.bundled("no-reply"))
        XCTAssertGreaterThan(Chime.beep().frameLength, 1000)
    }

    // MARK: - 真的連到這台 Mac 上的小呆呆服務

    /// Mac 服務沒開就跳過。會真的問 Claude 一次。
    func testAsksTheRealMacService() throws {
        let link = MacLink()
        var events: [MacLink.Event] = []
        let connected = expectation(description: "連上")
        connected.assertForOverFulfill = false  // 中途重連會再收到一次「連上」
        let finished = expectation(description: "這一輪結束")
        link.onEvent = { event in
            events.append(event)
            if event == .connected { connected.fulfill() }
            if case .done(let kind) = event, kind == "answer" || kind == "report" { finished.fulfill() }
        }
        link.connect(host: "127.0.0.1")
        if XCTWaiter.wait(for: [connected], timeout: 3) != .completed {
            link.disconnect()
            throw XCTSkip("這台 Mac 的小呆呆服務沒開（ws://127.0.0.1:8787）")
        }

        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "question-16k", withExtension: "wav"))
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let pcm = Data(bytes: try XCTUnwrap(buffer.int16ChannelData)[0], count: Int(buffer.frameLength) * 2)
        link.send(["type": "start", "sampleRate": 16000])
        link.send(pcm)
        // 跟手機一樣：講完時帶上 iPhone 自己聽到的字（開頭的「小呆呆」Mac 會去掉）
        link.send(["type": "end", "text": "小呆呆，一天有幾小時？", "engine": "test", "phoneSeconds": 0.2])

        wait(for: [finished], timeout: 90)
        link.disconnect()
        let heard = events.compactMap { if case .heard(let text) = $0 { return text } else { return nil } }
        XCTAssertEqual(heard, ["一天有幾小時？"])
        let said = events.compactMap { if case .say(let speech) = $0 { return speech } else { return nil } }
        XCTAssertFalse(said.isEmpty)
        let answer = said.map(\.text).joined()
        XCTAssertTrue(answer.contains("二十四") || answer.contains("24"), "回答：\(answer)")
        XCTAssertTrue(said.allSatisfy { SpeechAudio.decode($0.audio) != nil }, "Mac 傳來的聲音要播得出來")
    }

    // MARK: - iPhone 自己聽

    func testPhoneEarsFindsTaiwanChinese() async throws {
        let ears = PhoneEars()
        let (engine, state) = await ears.prepare()
        // GitHub 雲端的模擬器不一定裝了語言資料；Rino 的手機（iOS 27）有 SpeechTranscriber
        guard engine != nil else { throw XCTSkip("這台模擬器沒有台灣中文辨識") }
        XCTAssertNotEqual(state, .unsupported)
    }

    /// 模型還沒裝（或沒叫醒）時，講完要回 nil，交給 Mac 聽
    func testPhoneEarsWithoutSessionHandsOverToMac() async {
        let ears = PhoneEars()
        ears.feed(Data(count: 3200))
        let heard = await ears.finish()
        XCTAssertNil(heard)
    }

    // MARK: - 工具

    /// 跟 App 一樣，每 0.1 秒餵一次
    private func feed(_ eos: inout EndOfSpeech, rms: Float, seconds: Double) -> EndOfSpeech.Result {
        var result = EndOfSpeech.Result.keepGoing
        for _ in 0..<Int((seconds / 0.1).rounded()) {
            result = eos.feed(rms: rms, seconds: 0.1)
            if result != .keepGoing { break }
        }
        return result
    }
}
