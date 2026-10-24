import AVFoundation
import Speech

/// iPhone 自己聽懂你講的話：Apple 內建的台灣中文辨識，整個在手機上跑、不上傳。
/// 叫醒後一邊收話一邊轉文字，講完很快就有結果。
/// （2026-10-24 Rino 選的：辦公室 Mac 跑語音模型時 GPU 每幾分鐘出錯一次）
final class PhoneEars: @unchecked Sendable {
    enum Engine: String {
        case speech = "SpeechTranscriber"        // 新模型，比較準；目前不一定支援中文
        case dictation = "DictationTranscriber"  // 跟鍵盤聽寫同一套
    }

    enum ModelState: Equatable {
        case unsupported
        case needsDownload
        case downloading(Double)
        case ready
        case failed(String)
    }

    struct Heard {
        let text: String
        let engine: Engine
        /// 講完之後，多久拿到最後的字
        let seconds: Double
    }

    static let wantedLocale = Locale(identifier: "zh-TW")
    /// 講完後最多等這麼久；等不到就交給 Mac 自己聽
    static let finishTimeout = 3.0

    private let lock = NSLock()
    private var engine: Engine?
    private var locale = PhoneEars.wantedLocale
    private var format: AVAudioFormat?
    private var ready = false
    private var session: Session?

    /// 開始聽之前呼叫：決定用哪一套、模型裝了沒
    func prepare() async -> (Engine?, ModelState) {
        let engine: Engine
        let locale: Locale
        if let found = await SpeechTranscriber.supportedLocale(equivalentTo: Self.wantedLocale) {
            (engine, locale) = (.speech, found)
        } else if let found = await DictationTranscriber.supportedLocale(equivalentTo: Self.wantedLocale) {
            (engine, locale) = (.dictation, found)
        } else {
            return (nil, .unsupported)
        }
        let module = Self.makeModule(engine, locale: locale)
        let status = await AssetInventory.status(forModules: [module])
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module])
        let state: ModelState = switch status {
        case .installed: .ready
        case .unsupported: .unsupported
        default: .needsDownload
        }
        lock.withLock {
            self.engine = engine
            self.locale = locale
            self.format = format
            ready = state == .ready
        }
        return (engine, state)
    }

    /// 模型要下載多大（位元組）；Apple 沒說就是 nil
    func downloadSize() async -> Int64? {
        guard case let (engine, locale)? = currentEngine(),
              let request = try? await AssetInventory.assetInstallationRequest(supporting: [Self.makeModule(engine, locale: locale)])
        else { return nil }
        let total = request.progress.totalUnitCount
        return total > 0 ? total : nil
    }

    /// 從 Apple 下載台灣中文辨識模型（Rino 在 App 裡按了才下載）
    func download(progress: @escaping @Sendable (Double) -> Void) async throws {
        guard case let (engine, locale)? = currentEngine() else { return }
        let module = Self.makeModule(engine, locale: locale)
        _ = try? await AssetInventory.reserve(locale: locale)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            let observation = request.progress.observe(\.fractionCompleted) { value, _ in progress(value.fractionCompleted) }
            defer { observation.invalidate() }
            try await request.downloadAndInstall()
        }
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module])
        lock.withLock {
            self.format = format
            ready = true
        }
    }

    // 下面三個在聲音佇列上呼叫

    /// 叫醒、開始收話
    func begin() {
        let next: Session? = lock.withLock {
            guard ready, let engine, let format else { return nil }
            return Session(engine: engine, locale: locale, format: format)
        }
        let old = lock.withLock {
            defer { session = next }
            return session
        }
        old?.cancel()
    }

    func feed(_ pcm: Data) {
        lock.withLock { session }?.feed(pcm)
    }

    func cancel() {
        let old = lock.withLock {
            defer { session = nil }
            return session
        }
        old?.cancel()
    }

    /// 講完了：拿最後的字。手機沒辦法聽（模型沒裝、出錯、太久）就是 nil，交給 Mac
    func finish() async -> Heard? {
        let current = lock.withLock {
            defer { session = nil }
            return session
        }
        guard let current else { return nil }
        let started = Date()
        guard let text = await current.finish(timeout: Self.finishTimeout) else { return nil }
        return Heard(text: text, engine: current.engine, seconds: Date().timeIntervalSince(started))
    }

    private func currentEngine() -> (Engine, Locale)? {
        lock.withLock { engine.map { ($0, locale) } }
    }

    fileprivate static func makeModule(_ engine: Engine, locale: Locale) -> any SpeechModule {
        switch engine {
        case .speech: speechTranscriber(locale)
        case .dictation: dictationTranscriber(locale)
        }
    }

    // 不用 preset：preset 的名字在 iOS 26、27 之間改過，GitHub 上的 Xcode 26 會找不到。
    // 什麼選項都不開 = 只給最後確定的字
    fileprivate static func speechTranscriber(_ locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
    }

    fileprivate static func dictationTranscriber(_ locale: Locale) -> DictationTranscriber {
        DictationTranscriber(locale: locale, contentHints: [], transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
    }
}

/// 一句話的辨識：聲音一段段丟進去，講完收最後的結果
private final class Session: @unchecked Sendable {
    let engine: PhoneEars.Engine
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private let analyzer: SpeechAnalyzer
    private let started: Task<Void, Error>
    private let collected: Task<String, Error>
    private let format: AVAudioFormat
    private let converter: AVAudioConverter?

    init(engine: PhoneEars.Engine, locale: Locale, format: AVAudioFormat) {
        self.engine = engine
        self.format = format
        converter = format == Resampler16k.format ? nil : AVAudioConverter(from: Resampler16k.format, to: format)
        let (stream, input) = AsyncStream<AnalyzerInput>.makeStream()
        self.input = input
        let analyzer: SpeechAnalyzer
        switch engine {
        case .speech:
            let transcriber = PhoneEars.speechTranscriber(locale)
            analyzer = SpeechAnalyzer(modules: [transcriber])
            collected = Task {
                var text = ""
                for try await result in transcriber.results where result.isFinal { text += String(result.text.characters) }
                return text
            }
        case .dictation:
            let transcriber = PhoneEars.dictationTranscriber(locale)
            analyzer = SpeechAnalyzer(modules: [transcriber])
            collected = Task {
                var text = ""
                for try await result in transcriber.results where result.isFinal { text += String(result.text.characters) }
                return text
            }
        }
        self.analyzer = analyzer
        // 開始之前丟進來的聲音會先排在 stream 裡，不會掉
        started = Task { try await analyzer.start(inputSequence: stream) }
    }

    /// 16 kHz、16-bit 單聲道（跟傳給 Mac 的同一份）
    func feed(_ pcm: Data) {
        let frames = pcm.count / 2
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: Resampler16k.format, frameCapacity: AVAudioFrameCount(frames))
        else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        pcm.withUnsafeBytes { raw in
            buffer.int16ChannelData![0].update(from: raw.bindMemory(to: Int16.self).baseAddress!, count: frames)
        }
        guard let converter else {
            input.yield(AnalyzerInput(buffer: buffer))
            return
        }
        let capacity = AVAudioFrameCount(Double(frames) * format.sampleRate / 16000) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
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
        if error == nil, out.frameLength > 0 { input.yield(AnalyzerInput(buffer: out)) }
    }

    /// 回傳 nil：太久或出錯
    func finish(timeout: Double) async -> String? {
        input.finish()
        let analyzer = analyzer
        let started = started
        let collected = collected
        let work = Task { () -> String? in
            do {
                try await started.value
                try await analyzer.finalizeAndFinishThroughEndOfInput()
                return try await collected.value
            } catch {
                return nil
            }
        }
        let result = await withTaskGroup(of: String??.self) { group in
            group.addTask { .some(await work.value) }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                return .none
            }
            let first = await group.next() ?? .none
            group.cancelAll()
            return first
        }
        guard let finished = result else {
            await analyzer.cancelAndFinishNow()  // 太久了
            return nil
        }
        return finished
    }

    func cancel() {
        input.finish()
        let analyzer = analyzer
        Task { await analyzer.cancelAndFinishNow() }
    }
}
