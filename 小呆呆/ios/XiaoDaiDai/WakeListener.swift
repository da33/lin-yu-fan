import AVFoundation
import UIKit

/// 一直在背景聽「小呆呆」：手機鎖著、放口袋也照樣聽（靠 Info.plist 的 UIBackgroundModes = audio）。
/// 叫醒後把你講的話邊講邊傳給辦公室的 Mac，再把 Mac 用美佳念的回答播出來。
/// 每次叫醒、問答、電量、被打斷、恢復都寫進測試紀錄。
@MainActor
final class WakeListener: ObservableObject {
    enum Phase: String {
        case listening = "正在聽「小呆呆」"
        case capturing = "你說，我在聽"
        case waiting = "想一下…"
        case speaking = "回答中"
    }

    struct Detection: Identifiable {
        let id = UUID()
        let date: Date
    }

    struct Exchange: Identifiable {
        let id = UUID()
        let date: Date
        var question: String
        var answer: String
    }

    @Published private(set) var isListening = false
    @Published private(set) var phase = Phase.listening
    @Published private(set) var status = "按下「開始聽」"
    @Published private(set) var detections: [Detection] = []
    @Published private(set) var exchanges: [Exchange] = []
    @Published private(set) var macConnected = false
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
    /// iPhone 自己聽懂你講的話用哪一套、模型裝了沒
    @Published private(set) var phoneEngine: PhoneEars.Engine?
    @Published private(set) var phoneModel: PhoneEars.ModelState?
    @Published private(set) var phoneModelSize: Int64?
    /// 辦公室 Mac 在 Tailscale 裡的名稱
    @Published var macHost: String {
        didSet {
            UserDefaults.standard.set(macHost, forKey: "macHost")
            if isListening { link.connect(host: macHost) }
        }
    }

    let log = TestLog()
    private var engine = AVAudioEngine()
    private var player = AVAudioPlayerNode()
    private let pipeline = AudioPipeline()
    private let link = MacLink()
    private let phoneEars = PhoneEars()
    private let chime = Chime.makeBuffer()
    private let beep = Chime.beep()
    private let noMac = SpeechAudio.bundled("no-mac")
    private let noReply = SpeechAudio.bundled("no-reply")
    private var batteryTimer: Timer?
    private var restartTask: Task<Void, Never>?
    private var replyTimeout: Task<Void, Never>?
    private var lastAudioStart = Date.distantPast
    private var observers: [NSObjectProtocol] = []

    // 一輪問答播到哪
    private var queued = 0             // 排進播放器、還沒播完的段數
    private var playGeneration = 0     // 聲音重開時加一，舊的「播完了」通知就不算
    private var turnOpen = false       // Mac 還沒說這一輪結束
    private var reportPlaying = false
    private var held: [MacLink.Event] = []  // 正在問問題或講電話時來的報告，晚點再播
    private var interrupted = false

    /// 沒講話就送出後，最多等 Mac 多久
    static let replyTimeoutSeconds: UInt64 = 20

    init() {
        macHost = UserDefaults.standard.string(forKey: "macHost") ?? Self.defaultHost
        UIDevice.current.isBatteryMonitoringEnabled = true
        battery = UIDevice.current.batteryLevel
        let link = link
        let ears = phoneEars
        pipeline.onDetect = { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.didDetect() } }
        }
        // 你講的話直接從聲音佇列送出去，不繞主執行緒，順序才不會亂。
        // 同一份聲音也給 iPhone 自己聽；Mac 先把聲音存起來，之後拿來比較哪邊聽得準
        pipeline.onCaptureStart = {
            link.send(["type": "start", "sampleRate": 16000])
            ears.begin()
        }
        pipeline.onCaptureAudio = {
            link.send($0)
            ears.feed($0)
        }
        pipeline.onCaptureEnd = { [weak self] result, speech in
            if result == .finished {
                Task {
                    let heard = await ears.finish()
                    var end: [String: Any] = ["type": "end"]
                    if let heard {
                        end["text"] = heard.text
                        end["engine"] = heard.engine.rawValue
                        end["phoneSeconds"] = (heard.seconds * 100).rounded() / 100
                    }
                    link.send(end)  // 手機沒聽到字就不帶 text，Mac 會自己聽
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.didHearOnPhone(heard) } }
                }
            } else {
                ears.cancel()
                link.send(["type": "cancel"])
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.didFinishSpeaking(result, speech) } }
        }
        link.onEvent = { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
        observeSession()
        Task { await preparePhoneEars() }
    }

    /// 預設的 Mac 名稱：setup-mac.sh 從這台 Mac 的 Tailscale 抓，寫在 Local.xcconfig（不放上 GitHub）
    static var defaultHost: String {
        (Bundle.main.object(forInfoDictionaryKey: "XDDMacHost") as? String) ?? ""
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
        resetTurn()
        backToListening()
        link.connect(host: macHost)
        log.add("開始", battery: battery, "麥克風：\(inputName)，\(Int(inputSampleRate)) Hz，靈敏度：\(sensitivity.rawValue)，高品質收音：\(highQualityBluetooth ? "開" : "關")，電腦：\(macHost)")
        batteryTimer?.invalidate()
        batteryTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sampleBattery() }
        }
    }

    func stop(reason: String) {
        restartTask?.cancel()
        batteryTimer?.invalidate()
        batteryTimer = nil
        link.disconnect()
        stopAudio()
        resetTurn()
        held.removeAll()
        pipeline.unload()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        if isListening {
            log.add("停止", battery: UIDevice.current.batteryLevel, "\(reason)；共叫醒 \(detections.count) 次，自動恢復 \(restarts) 次")
        }
        isListening = false
        level = 0
        phase = .listening
        status = "已停止"
    }

    /// 換靈敏度只要重載偵測器，麥克風不用重開
    private func applySensitivity() async {
        guard let modelDirectory = Bundle.main.url(forResource: "Model", withExtension: nil) else { return }
        let ok = await pipeline.load(modelDirectory: modelDirectory, sensitivity: sensitivity)
        log.add(ok ? "設定" : "錯誤", battery: UIDevice.current.batteryLevel,
                ok ? "靈敏度改成：\(sensitivity.rawValue)" : "換靈敏度時模型載入失敗")
    }

    // MARK: - iPhone 自己聽

    private func preparePhoneEars() async {
        let (engine, state) = await phoneEars.prepare()
        phoneEngine = engine
        phoneModel = state
        if state == .needsDownload { phoneModelSize = await phoneEars.downloadSize() }
        log.add("iPhone 辨識", battery: UIDevice.current.batteryLevel,
                "\(engine?.rawValue ?? "這支手機不支援台灣中文")，模型：\(Self.describe(state))")
    }

    /// 從 Apple 下載台灣中文辨識模型；畫面上按了才下載
    func downloadPhoneModel() async {
        phoneModel = .downloading(0)
        do {
            try await phoneEars.download { [weak self] fraction in
                Task { @MainActor in
                    if case .downloading = self?.phoneModel { self?.phoneModel = .downloading(fraction) }
                }
            }
            phoneModel = .ready
            log.add("iPhone 辨識", battery: UIDevice.current.batteryLevel, "模型下載好了")
        } catch {
            phoneModel = .failed(error.localizedDescription)
            log.add("錯誤", battery: UIDevice.current.batteryLevel, "下載辨識模型失敗：\(error.localizedDescription)")
        }
    }

    private func didHearOnPhone(_ heard: PhoneEars.Heard?) {
        if let heard {
            log.add("iPhone 聽成", battery: UIDevice.current.batteryLevel,
                    String(format: "%@（%@，講完後 %.2f 秒）", heard.text, heard.engine.rawValue, heard.seconds))
        } else {
            log.add("iPhone 沒聽到", battery: UIDevice.current.batteryLevel, "交給電腦聽")
        }
    }

    static func describe(_ state: PhoneEars.ModelState?) -> String {
        switch state {
        case nil: "檢查中"
        case .unsupported: "不支援"
        case .needsDownload: "還沒下載"
        case .downloading(let fraction): "下載中 \(Int(fraction * 100))%"
        case .ready: "好了"
        case .failed(let reason): "失敗：\(reason)"
        }
    }

    // MARK: - 一輪問答

    private func didDetect() {
        guard isListening else { return }
        detections.insert(Detection(date: Date()), at: 0)
        log.add("叫醒", battery: UIDevice.current.batteryLevel, "第 \(detections.count) 次")
        guard link.isConnected else {
            pipeline.pause()
            say(noMac, status: "連不到電腦：確認 iPhone 的 Tailscale 有打開")
            log.add("連不到電腦", battery: UIDevice.current.batteryLevel, "叫醒時沒連上 \(macHost)")
            return
        }
        phase = .capturing
        status = Phase.capturing.rawValue
        sound(chime)
    }

    private func didFinishSpeaking(_ result: EndOfSpeech.Result, _ speech: EndOfSpeech) {
        guard isListening, phase == .capturing else { return }
        let detail = String(format: "講了 %.1f 秒，最大聲 %.3f，門檻 %.3f", speech.spoken, speech.loudest, speech.threshold)
        guard result == .finished else {
            log.add("沒講話", battery: UIDevice.current.batteryLevel, detail)
            backToListening()
            return
        }
        guard link.isConnected else {
            say(noMac, status: "連不到電腦：確認 iPhone 的 Tailscale 有打開")
            log.add("連不到電腦", battery: UIDevice.current.batteryLevel, "講完時沒連上；\(detail)")
            return
        }
        phase = .waiting
        status = Phase.waiting.rawValue
        turnOpen = true
        sound(beep)
        exchanges.insert(Exchange(date: Date(), question: "…", answer: ""), at: 0)
        if exchanges.count > 30 { exchanges.removeLast() }
        log.add("問", battery: UIDevice.current.batteryLevel, detail)
        replyTimeout?.cancel()
        replyTimeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.replyTimeoutSeconds * 1_000_000_000)
            guard let self, !Task.isCancelled, self.phase == .waiting else { return }
            self.log.add("沒回應", battery: UIDevice.current.batteryLevel, "等了 \(Self.replyTimeoutSeconds) 秒")
            self.turnOpen = false
            self.say(self.noReply, status: "電腦沒有回應")
        }
    }

    private func handle(_ event: MacLink.Event) {
        switch event {
        case .connected:
            macConnected = true
            log.add("連上電腦", battery: UIDevice.current.batteryLevel, macHost)
        case .disconnected:
            macConnected = false
            log.add("跟電腦斷線", battery: UIDevice.current.batteryLevel, macHost)
            if phase == .waiting {
                replyTimeout?.cancel()
                turnOpen = false
                say(noMac, status: "連不到電腦")
            } else if turnOpen && !reportPlaying {
                turnOpen = false
                if queued == 0 { finishTurn() }
            }
        case .heard(let text):
            replyTimeout?.cancel()
            if phase == .waiting, !exchanges.isEmpty {
                exchanges[0].question = text.isEmpty ? "（沒聽清楚）" : text
            }
            log.add("聽成", battery: UIDevice.current.batteryLevel, text)
        case .say(let speech) where speech.kind == "report":
            handleReport(event)
        case .say(let speech):
            guard phase == .waiting || phase == .speaking, !reportPlaying else { return }  // 不是這一輪的
            phase = .speaking
            status = Phase.speaking.rawValue
            if !exchanges.isEmpty { exchanges[0].answer += speech.text }
            log.add(speech.kind == "ack" ? "收到" : "回答", battery: UIDevice.current.batteryLevel, speech.text)
            enqueue(SpeechAudio.decode(speech.audio))
        case .done(kind: "report"):
            handleReport(event)
        case .done:
            guard !reportPlaying else { return }
            turnOpen = false
            if queued == 0 { finishTurn() }
        }
    }

    /// 「做好了」的報告：先叮一聲再講；你正在問問題、講電話，或還在播別的，就等一下再播
    private func handleReport(_ event: MacLink.Event) {
        let busy = phase != .listening || interrupted
        if !held.isEmpty || (busy && !reportPlaying) {
            held.append(event)
            return
        }
        switch event {
        case .say(let speech):
            if !reportPlaying {
                reportPlaying = true
                turnOpen = true
                pipeline.pause()
                phase = .speaking
                status = "報告：\(speech.question)"
                sound(chime)
                if let index = exchanges.firstIndex(where: { $0.question == speech.question }) {
                    exchanges[index].answer = ""
                } else {
                    exchanges.insert(Exchange(date: Date(), question: speech.question, answer: ""), at: 0)
                }
            }
            if let index = exchanges.firstIndex(where: { $0.question == speech.question }) {
                exchanges[index].answer += speech.text
            }
            log.add("報告", battery: UIDevice.current.batteryLevel, speech.text)
            enqueue(SpeechAudio.decode(speech.audio))
        case .done:
            turnOpen = false
            if queued == 0 { finishTurn() }
        default:
            break
        }
    }

    /// 手機自己念一句（連不到電腦這類），念完回去聽
    private func say(_ buffer: AVAudioPCMBuffer?, status text: String) {
        pipeline.pause()
        phase = .speaking
        status = text
        turnOpen = false
        enqueue(buffer)
    }

    private func finishTurn() {
        replyTimeout?.cancel()
        reportPlaying = false
        turnOpen = false
        backToListening()
        if !held.isEmpty && !interrupted {
            let events = held
            held = []
            events.forEach(handleReport)
        }
    }

    private func backToListening() {
        guard isListening else { return }
        phase = .listening
        status = Phase.listening.rawValue
        pipeline.listenForWakeWord()
    }

    private func resetTurn() {
        replyTimeout?.cancel()
        queued = 0
        turnOpen = false
        reportPlaying = false
    }

    // MARK: - 播放

    /// 提示音，不算在回答裡
    private func sound(_ buffer: AVAudioPCMBuffer) {
        if !player.isPlaying { player.play() }
        player.scheduleBuffer(buffer, at: nil, options: [])
    }

    /// 回答的一段聲音；全部播完、Mac 也說結束了，就回去聽「小呆呆」
    private func enqueue(_ buffer: AVAudioPCMBuffer?) {
        guard let buffer else {
            if queued == 0 && !turnOpen { finishTurn() }
            return
        }
        queued += 1
        let generation = playGeneration
        if !player.isPlaying { player.play() }
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.played(generation) } }
        }
    }

    private func played(_ generation: Int) {
        guard generation == playGeneration, queued > 0 else { return }
        queued -= 1
        if queued == 0 && !turnOpen { finishTurn() }
    }

    // MARK: - 聲音

    private func startAudio() throws {
        let session = AVAudioSession.sharedInstance()
        // mixWithOthers：小呆呆在聽的時候，你照樣可以用別的 App 聽音樂
        var options: AVAudioSession.CategoryOptions = [.mixWithOthers, .allowBluetooth, .allowBluetoothA2DP]
        #if compiler(>=6.2)
        if highQualityBluetooth {
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
        engine.connect(player, to: engine.mainMixerNode, format: Chime.format)
        engine.prepare()
        try engine.start()
        lastAudioStart = Date()
        updateRoute()
    }

    private func stopAudio() {
        playGeneration += 1  // 還沒播完的就不等了
        queued = 0
        engine.inputNode.removeTap(onBus: 0)
        player.stop()
        engine.stop()
    }

    /// 聲音執行緒上跑的部分：不能碰主執行緒的東西，只把聲音丟給背景佇列
    nonisolated private static func makeTap(pipeline: AudioPipeline, sampleRate: Int,
                                            onLevel: @escaping @Sendable (Float) -> Void) -> AVAudioNodeTapBlock {
        return { buffer, _ in
            guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
            let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            pipeline.feed(samples, sampleRate: sampleRate)
            onLevel(min(1, AudioPipeline.rms(samples) * 10))
        }
    }

    private func restart(reason: String) {
        if phase == .capturing { link.send(["type": "cancel"]) }  // 講到一半換了麥克風，這句不算
        stopAudio()
        do {
            try startAudio()
            restarts += 1
            log.add("恢復", battery: UIDevice.current.batteryLevel, "\(reason)；麥克風：\(inputName)，\(Int(inputSampleRate)) Hz")
            resetTurn()
            finishTurn()  // 回去聽，順便播講電話時留著的報告
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
            interrupted = true
            status = "被打斷（例如來電），結束後會自己恢復"
            log.add("打斷", battery: UIDevice.current.batteryLevel, "例如來電、Siri、別的 App 獨占麥克風")
        } else {
            interrupted = false
            scheduleRestart(reason: "打斷結束")
        }
    }

    private static func requestMicrophone() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }
}

enum ListenerError: LocalizedError {
    case noMicrophone

    var errorDescription: String? { "找不到可以用的麥克風" }
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
        let line = "\(formatter.string(from: Date())),\(event),\(percent),\(detail.replacingOccurrences(of: ",", with: "，").replacingOccurrences(of: "\n", with: " "))\n"
        guard let data = line.data(using: .utf8), let handle = try? FileHandle(forWritingTo: url) else { return }
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.close()
    }
}
