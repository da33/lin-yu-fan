import AVFoundation
import XCTest
@testable import XiaoDaiDai

/// 用錄好的聲音檔驗證喚醒詞偵測（在模擬器跑；真的戴 AirPods 的效果要在手機上測）
final class WakeWordTests: XCTestCase {
    func testWakesOnXiaoDaiDai16k() throws {
        XCTAssertEqual(try detect("wake-16k"), ["小呆呆"])
    }

    /// iPhone 內建麥克風是 48kHz，要確認不是 16kHz 也叫得醒
    func testWakesOnXiaoDaiDai48k() throws {
        XCTAssertEqual(try detect("wake-48k"), ["小呆呆"])
    }

    /// 「發呆」「代代相傳」「帶帶我」這些很像的話不能叫醒
    func testIgnoresOtherSpeech() throws {
        XCTAssertEqual(try detect("other-speech-16k"), [])
    }

    func testChimeIsAudible() {
        let chime = Chime.makeBuffer()
        XCTAssertGreaterThan(chime.frameLength, 10_000)
    }

    // MARK: - 工具

    /// 跟 App 一樣，一次餵 0.1 秒
    private func detect(_ name: String) throws -> [String] {
        let modelDirectory = try XCTUnwrap(Bundle.main.url(forResource: "Model", withExtension: nil), "App 裡找不到 Model 資料夾")
        let detector = try XCTUnwrap(WakeWordDetector(modelDirectory: modelDirectory, sensitivity: .standard), "模型載入失敗")
        let (samples, rate) = try load(name)
        let chunk = rate / 10
        var found: [String] = []
        for start in stride(from: 0, to: samples.count, by: chunk) {
            found += detector.process(Array(samples[start..<min(start + chunk, samples.count)]), sampleRate: rate)
        }
        return found
    }

    private func load(_ name: String) throws -> ([Float], Int) {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "wav"), "找不到測試聲音 \(name).wav")
        let file = try AVAudioFile(forReading: url)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let channel = try XCTUnwrap(buffer.floatChannelData)[0]
        return (Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))), Int(file.processingFormat.sampleRate))
    }
}
