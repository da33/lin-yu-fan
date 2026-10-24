import AVFoundation

/// 在背景佇列上處理麥克風的聲音，不卡住聲音執行緒。
/// 平常找「小呆呆」；一叫醒就改成把你接著講的話轉成 16 kHz 傳給 Mac，聽到你講完就停。
final class AudioPipeline: @unchecked Sendable {
    enum Mode { case wake, capture, paused }

    /// 叫醒前留著的聲音：你一口氣講「小呆呆今天幾點」時，前面幾個字才不會掉
    /// （0.5 秒時「小呆呆台北明天…」的「台北」被吃掉過；多錄到的「小呆呆」Mac 會去掉）
    static let preRollSeconds = 1.0

    private let queue = DispatchQueue(label: "tw.rino.xiaodaidai.audio", qos: .userInitiated)
    private var detector: WakeWordDetector?
    private var mode: Mode = .wake
    private var noise = NoiseFloor()
    private var preRoll: [Float] = []
    private var resampler: Resampler16k?
    private var endOfSpeech: EndOfSpeech?

    // 下面這些都在背景佇列上呼叫，開始聽之前設定一次
    /// 聽到「小呆呆」；這時已經開始收你接下來講的話了
    var onDetect: (@Sendable () -> Void)?
    /// 開始收話（第一段聲音之前）
    var onCaptureStart: (@Sendable () -> Void)?
    /// 一段你講的話：16 kHz、16-bit、單聲道
    var onCaptureAudio: (@Sendable (Data) -> Void)?
    /// 講完了（或一直沒講話）
    var onCaptureEnd: (@Sendable (EndOfSpeech.Result, EndOfSpeech) -> Void)?

    func load(modelDirectory: URL, sensitivity: WakeWordDetector.Sensitivity) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async {
                self.detector = WakeWordDetector(modelDirectory: modelDirectory, sensitivity: sensitivity)
                continuation.resume(returning: self.detector != nil)
            }
        }
    }

    func feed(_ samples: [Float], sampleRate: Int) {
        queue.async { self.process(samples, sampleRate: sampleRate) }
    }

    /// 回到聽「小呆呆」
    func listenForWakeWord() {
        queue.async {
            self.detector?.reset()
            self.preRoll.removeAll()
            self.endOfSpeech = nil
            self.mode = .wake
        }
    }

    /// 暫停：念回答的時候不要聽，免得聽到自己的聲音又醒過來
    func pause() {
        queue.async {
            self.endOfSpeech = nil
            self.mode = .paused
        }
    }

    func unload() {
        queue.async {
            self.detector = nil
            self.endOfSpeech = nil
            self.mode = .wake
        }
    }

    private func process(_ samples: [Float], sampleRate: Int) {
        let rms = Self.rms(samples)
        switch mode {
        case .paused:
            return
        case .wake:
            noise.update(rms)
            keepPreRoll(samples, sampleRate: sampleRate)
            guard let detector, !detector.process(samples, sampleRate: sampleRate).isEmpty else { return }
            startCapture(sampleRate: sampleRate)
            onDetect?()
        case .capture:
            guard var state = endOfSpeech, let resampler else { return }
            let pcm = resampler.convert(samples)
            if !pcm.isEmpty { onCaptureAudio?(pcm) }
            let result = state.feed(rms: rms, seconds: Double(samples.count) / Double(sampleRate))
            endOfSpeech = state
            if result != .keepGoing {
                mode = .paused
                endOfSpeech = nil
                onCaptureEnd?(result, state)
            }
        }
    }

    private func startCapture(sampleRate: Int) {
        mode = .capture
        resampler = Resampler16k(inputRate: Double(sampleRate))
        endOfSpeech = EndOfSpeech(noiseFloor: noise.value)
        onCaptureStart?()
        if let pcm = resampler?.convert(preRoll), !pcm.isEmpty { onCaptureAudio?(pcm) }
        preRoll.removeAll()
    }

    private func keepPreRoll(_ samples: [Float], sampleRate: Int) {
        preRoll += samples
        let keep = Int(Self.preRollSeconds * Double(sampleRate))
        if preRoll.count > keep { preRoll.removeFirst(preRoll.count - keep) }
    }

    static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        return sqrt(sum / Float(samples.count))
    }
}

/// 判斷你講完了沒：叫醒之後聽到你開始講話，接著安靜約 1 秒就算講完
struct EndOfSpeech: Equatable {
    enum Result: Equatable { case keepGoing, finished, nothingSaid }

    /// 安靜多久算講完
    var silenceToFinish = 1.0
    /// 叫醒後這段時間不算，裡面還有「小呆呆」的尾巴
    var graceSeconds = 0.4
    /// 叫醒後這麼久都沒開口，就當作不問了
    var waitForSpeech = 6.0
    /// 一句最長幾秒，到了就直接送出
    var maxSeconds = 30.0
    /// 叫醒前環境有多吵（RMS）
    var noiseFloor: Float

    private(set) var elapsed = 0.0
    private(set) var spoken = 0.0
    private(set) var loudest: Float = 0
    private var silence = 0.0

    init(noiseFloor: Float) {
        self.noiseFloor = noiseFloor
    }

    /// 比環境噪音大 3 倍才算在講話；太安靜或太吵的地方都有上下限
    var threshold: Float { min(max(noiseFloor * 3, 0.006), 0.05) }
    var heardSpeech: Bool { spoken > 0 }

    mutating func feed(rms: Float, seconds: Double) -> Result {
        elapsed += seconds
        if elapsed > graceSeconds {
            loudest = max(loudest, rms)
            if rms > threshold {
                spoken += seconds
                silence = 0
            } else {
                silence += seconds
            }
        }
        let slack = 1e-6  // 一段段加起來的秒數會有小數誤差
        if heardSpeech && silence + slack >= silenceToFinish { return .finished }
        if elapsed + slack >= maxSeconds { return heardSpeech ? .finished : .nothingSaid }
        if !heardSpeech && elapsed + slack >= waitForSpeech { return .nothingSaid }
        return .keepGoing
    }
}

/// 估計環境噪音：變安靜時很快跟上，變吵時慢慢爬（喊「小呆呆」那一下不會把它拉太高）
struct NoiseFloor: Equatable {
    private(set) var value: Float = 0.01

    mutating func update(_ rms: Float) {
        if rms < value {
            value = value * 0.7 + rms * 0.3
        } else {
            value += (rms - value) * 0.005
        }
    }
}

/// 把麥克風的聲音轉成 16 kHz、16-bit 單聲道傳給 Mac：Mac 的辨識模型吃 16 kHz，也比較省流量
final class Resampler16k {
    static let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!

    private let input: AVAudioFormat
    private let converter: AVAudioConverter

    init?(inputRate: Double) {
        guard let input = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inputRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: input, to: Self.format)
        else { return nil }
        self.input = input
        self.converter = converter
    }

    /// 一段一段轉；轉換器會記住上一段的尾巴，接起來不會有雜音
    func convert(_ samples: [Float]) -> Data {
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: AVAudioFrameCount(samples.count)),
              let out = AVAudioPCMBuffer(pcmFormat: Self.format,
                                         frameCapacity: AVAudioFrameCount(Double(samples.count) * 16000 / input.sampleRate) + 64)
        else { return Data() }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        var given = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if given {
                status.pointee = .noDataNow
                return nil
            }
            given = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, out.frameLength > 0, let channel = out.int16ChannelData else { return Data() }
        return Data(bytes: channel[0], count: Int(out.frameLength) * 2)
    }
}
