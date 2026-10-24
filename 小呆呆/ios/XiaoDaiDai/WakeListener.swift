import AVFoundation
import UIKit

/// 一直在背景聽「小呆呆」：手機鎖著、放口袋也照樣聽（靠 Info.plist 的 UIBackgroundModes = audio）。
/// 聽到就「叮」一聲，並把每次叫醒、電量、被打斷、恢復都寫進測試紀錄。
@MainActor
final class WakeListener: ObservableObject {
    struct Detection: Identifiable {
        let id = UUID()
        let date: Date
    }

    @Published private(set) var isListening = false
    @Published private(set) var status = "按下「開始聽」"
    @Published private(set) var detections: [Detection] = []
    @Published private(set) var inputName = "—"
    @Published private(set) var inputSampleRate: Double = 0
    @Published private(set) var level: Float = 0
    @Published private(set) var startedAt: Date?
    @Published private(set) var startBattery: Float = -1
    @Published private(set) var battery: Float = -1
    @Published private(set) var restarts = 0
    @Published var sensitivity: WakeWordDetector.Sensitivity = .standard {
        didSet { if isListening && oldValue != sensitivity { Task { await applySensitivity() } } }
    }
    @Published var highQualityBluetooth = true {
        didSet { if isListening && oldValue != highQualityBluetooth { restart(reason: highQualityBluetooth ? "開高品質收音" : "關高品質收音") } }
    }

    let log = TestLog()
    private var engine = AVAudioEngine()
    private var player = AVAudioPlayerNode()
    private let pipeline = KWSPipeline()
    private let chime = Chime.makeBuffer()
    private var batteryTimer: Timer?
    private var restartTask: Task<Void, Never>?
    private var lastAudioStart = Date.distantPast
    private var observers: [NSObjectProtocol] = []

    init() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        battery = UIDevice.current.batteryLevel
        pipeline.onDetect = { [weak self] in
            Task { @MainActor in self?.didDetect() }
        }
        observeSession()
    }

    func toggle() async {
        if isListening {
            stop(reason: "手動停止")
        } else {
            await start()
        }
    }

    func start() async {
        guard await Self.requestMicrophone() else {
            status = "沒有麥克風權限：到「設定 › 小呆呆」打開麥克風"
            return
        }
        guard let modelDirectory = Bundle.main.url(forResource: "Model", withExtension: nil),
              await pipeline.load(modelDirectory: modelDirectory, sensitivity: sensitivity)
        else {
            status = "喚醒詞模型載入失敗"
            log.add("錯誤", battery: battery, "模型載入失敗")
            return
        }
        do {
            try startAudio()
        } catch {
            status = "麥克風開不起來：\(error.localizedDescription)"
            log.add("錯誤", battery: battery, "開始失敗：\(error.localizedDescription)")
            return
        }
        isListening = true
        startedAt = Date()
        battery = UIDevice.current.batteryLevel
        startBattery = battery
        detections = []
        restarts = 0
        status = "正在聽「小呆呆」"
        log.add("開始", battery: battery, "麥克風：\(inputName)，\(Int(inputSampleRate)) Hz，靈敏度：\(sensitivity.rawValue)，高品質收音：\(highQualityBluetooth ? "開" : "關")")
        batteryTimer?.invalidate()
        batteryTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sampleBattery() }
        }
    }

    func stop(reason: String) {
        restartTask?.cancel()
        batteryTimer?.invalidate()
        batteryTimer = nil
        stopAudio()
        pipeline.unload()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        if isListening {
            log.add("停止", battery: UIDevice.current.batteryLevel, "\(reason)；共叫醒 \(detections.count) 次，自動恢復 \(restarts) 次")
        }
        isListening = false
        level = 0
        status = "已停止"
    }

    /// 換靈敏度只要重載偵測器，麥克風不用重開
    private func applySensitivity() async {
        guard let modelDirectory = Bundle.main.url(forResource: "Model", withExtension: nil) else { return }
        let ok = await pipeline.load(modelDirectory: modelDirectory, sensitivity: sensitivity)
        log.add(ok ? "設定" : "錯誤", battery: UIDevice.current.batteryLevel,
                ok ? "靈敏度改成：\(sensitivity.rawValue)" : "換靈敏度時模型載入失敗")
    }

    // MARK: - 聲音

    private func startAudio() throws {
        let session = AVAudioSession.sharedInstance()
        // mixWithOthers：小呆呆在聽的時候，你照樣可以用別的 App 聽音樂
        var options: AVAudioSession.CategoryOptions = [.mixWithOthers, .allowBluetooth, .allowBluetoothA2DP]
        #if compiler(>=6.2)
        if #available(iOS 26.0, *), highQualityBluetooth {
            options.insert(.bluetoothHighQualityRecording) // iOS 26 + AirPods Pro 2：AirPods 高品質收音
        }
        #endif
        try session.setCategory(.playAndRecord, mode: .default, options: options)
        try session.setActive(true)
        // 有 AirPods 就用 AirPods 的麥克風（離嘴巴近，放口袋也聽得到）
        if let airPods = session.availableInputs?.first(where: { $0.portType == .bluetoothHFP }) {
            try? session.setPreferredInput(airPods)
        }

        engine = AVAudioEngine()
        player = AVAudioPlayerNode()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw ListenerError.noMicrophone }

        let onLevel: @Sendable (Float) -> Void = { [weak self] value in
            Task { @MainActor in self?.level = value }
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: format,
                         block: Self.makeTap(pipeline: pipeline, sampleRate: Int(format.sampleRate), onLevel: onLevel))
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: chime.format)
        engine.prepare()
        try engine.start()
        lastAudioStart = Date()
        updateRoute()
    }

    private func stopAudio() {
        engine.inputNode.removeTap(onBus: 0)
        player.stop()
        engine.stop()
    }

    /// 聲音執行緒上跑的部分：不能碰主執行緒的東西，只把聲音丟給背景佇列
    nonisolated private static func makeTap(pipeline: KWSPipeline, sampleRate: Int,
                                            onLevel: @escaping @Sendable (Float) -> Void) -> AVAudioNodeTapBlock {
        return { buffer, _ in
            guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
            let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            pipeline.feed(samples, sampleRate: sampleRate)
            var sum: Float = 0
            for sample in samples { sum += sample * sample }
            onLevel(min(1, sqrt(sum / Float(samples.count)) * 10))
        }
    }

    private func didDetect() {
        guard isListening else { return }
        detections.insert(Detection(date: Date()), at: 0)
        if !player.isPlaying { player.play() }
        player.scheduleBuffer(chime, at: nil, options: .interrupts)
        log.add("叫醒", battery: UIDevice.current.batteryLevel, "第 \(detections.count) 次")
    }

    private func restart(reason: String) {
        stopAudio()
        do {
            try startAudio()
            restarts += 1
            status = "正在聽「小呆呆」"
            log.add("恢復", battery: UIDevice.current.batteryLevel, "\(reason)；麥克風：\(inputName)，\(Int(inputSampleRate)) Hz")
        } catch {
            status = "恢復失敗，5 秒後再試：\(error.localizedDescription)"
            log.add("錯誤", battery: UIDevice.current.batteryLevel, "\(reason)後恢復失敗：\(error.localizedDescription)")
            scheduleRestart(reason: "重試", after: 5)
        }
    }

    /// 打斷、換耳機這類事件常常連續來好幾個，等一下再一次重啟
    private func scheduleRestart(reason: String, after seconds: Double = 0.8) {
        guard isListening else { return }
        restartTask?.cancel()
        restartTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let self, !Task.isCancelled, self.isListening else { return }
            self.restart(reason: reason)
        }
    }

    private func updateRoute() {
        let session = AVAudioSession.sharedInstance()
        inputName = session.currentRoute.inputs.first?.portName ?? "—"
        inputSampleRate = engine.inputNode.outputFormat(forBus: 0).sampleRate
    }

    private func sampleBattery() {
        battery = UIDevice.current.batteryLevel
        log.add("電量", battery: battery, "麥克風：\(inputName)")
    }

    // MARK: - 被打斷、換耳機

    private func observeSession() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let began = raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:)) == .began
            Task { @MainActor in self?.handleInterruption(began: began) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            let reason = raw.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
            guard reason == .newDeviceAvailable || reason == .oldDeviceUnavailable else { return }
            let text = reason == .newDeviceAvailable ? "接上新的耳機或麥克風" : "耳機或麥克風拔掉了"
            Task { @MainActor in self?.scheduleRestart(reason: text) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.scheduleRestart(reason: "系統聲音服務重置") }
        })
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                // 自己剛啟動時也會收到一次，3 秒內的忽略，避免重啟迴圈
                guard let self, Date().timeIntervalSince(self.lastAudioStart) > 3 else { return }
                self.scheduleRestart(reason: "聲音裝置設定改變")
            }
        })
    }

    private func handleInterruption(began: Bool) {
        guard isListening else { return }
        if began {
            status = "被打斷（例如來電），結束後會自己恢復"
            log.add("打斷", battery: UIDevice.current.batteryLevel, "例如來電、Siri、別的 App 獨占麥克風")
        } else {
            scheduleRestart(reason: "打斷結束")
        }
    }

    private static func requestMicrophone() async -> Bool {
        if #available(iOS 17.0, *) {
            return await AVAudioApplication.requestRecordPermission()
        }
        return await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { continuation.resume(returning: $0) }
        }
    }
}

enum ListenerError: LocalizedError {
    case noMicrophone

    var errorDescription: String? { "找不到可以用的麥克風" }
}

/// 在背景佇列上跑喚醒詞偵測，不卡住聲音執行緒
final class KWSPipeline: @unchecked Sendable {
    private let queue = DispatchQueue(label: "tw.rino.xiaodaidai.kws", qos: .userInitiated)
    private var detector: WakeWordDetector?
    /// 開始聽之前設定一次；聽到「小呆呆」時在背景佇列呼叫
    var onDetect: (@Sendable () -> Void)?

    func load(modelDirectory: URL, sensitivity: WakeWordDetector.Sensitivity) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async {
                self.detector = WakeWordDetector(modelDirectory: modelDirectory, sensitivity: sensitivity)
                continuation.resume(returning: self.detector != nil)
            }
        }
    }

    func feed(_ samples: [Float], sampleRate: Int) {
        queue.async {
            guard let detector = self.detector else { return }
            if !detector.process(samples, sampleRate: sampleRate).isEmpty {
                self.onDetect?()
            }
        }
    }

    func unload() {
        queue.async { self.detector = nil }
    }
}

/// 「叮」：兩個短音，聽到小呆呆時播
enum Chime {
    static func makeBuffer() -> AVAudioPCMBuffer {
        let rate = 44_100.0
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let notes: [(frequency: Double, seconds: Double)] = [(880, 0.11), (1318.5, 0.2)]
        let total = notes.reduce(0) { $0 + Int($1.seconds * rate) }
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(total))!
        buffer.frameLength = AVAudioFrameCount(total)
        let out = buffer.floatChannelData![0]
        var index = 0
        for note in notes {
            let count = Int(note.seconds * rate)
            for i in 0..<count {
                let t = Double(i) / rate
                let envelope = min(1, t / 0.005) * exp(-t * 9) // 快速起音、自然衰減
                out[index] = Float(sin(2 * .pi * note.frequency * t) * envelope * 0.5)
                index += 1
            }
        }
        return buffer
    }
}

/// 測試紀錄：CSV，可以在 App 裡按「分享測試紀錄」，或在「檔案 › 我的 iPhone › 小呆呆」找到
final class TestLog {
    let url: URL
    private let formatter: DateFormatter

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        url = documents.appendingPathComponent("小呆呆測試紀錄.csv")
        formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_TW")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        if !FileManager.default.fileExists(atPath: url.path) {
            try? "時間,事件,電量%,說明\n".write(to: url, atomically: true, encoding: .utf8)
        }
    }

    func add(_ event: String, battery: Float, _ detail: String = "") {
        let percent = battery < 0 ? "" : String(Int((battery * 100).rounded()))
        let line = "\(formatter.string(from: Date())),\(event),\(percent),\(detail.replacingOccurrences(of: ",", with: "，"))\n"
        guard let data = line.data(using: .utf8), let handle = try? FileHandle(forWritingTo: url) else { return }
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.close()
    }
}
