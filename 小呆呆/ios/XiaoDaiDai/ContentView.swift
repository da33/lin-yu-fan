import SwiftUI

/// 小呆呆：黑底、米白字、橘紅重點色
struct ContentView: View {
    @StateObject private var listener = WakeListener()
    @State private var hostDraft = ""

    var body: some View {
        ZStack {
            Palette.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    header
                    orb
                    mainButton
                    stats
                    settings
                    recent
                    howTo
                    ShareLink(item: listener.log.url) {
                        Label("分享測試紀錄", systemImage: "square.and.arrow.up")
                            .font(.headline)
                            .foregroundStyle(Palette.accent)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 24)
            }
        }
        .preferredColorScheme(.dark)
        .tint(Palette.accent)
        .onAppear { hostDraft = listener.macHost }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("小呆呆")
                .font(.system(size: 44, weight: .black))
                .foregroundStyle(Palette.text)
            Text("鎖著手機也會聽 · 喊「小呆呆」問一句話")
                .font(.subheadline)
                .foregroundStyle(Palette.muted)
        }
    }

    private var orbColor: Color {
        guard listener.isListening else { return Palette.line }
        switch listener.phase {
        case .listening, .capturing: return Palette.accent
        case .waiting: return Palette.muted
        case .speaking: return Palette.text
        }
    }

    private var orb: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .stroke(Palette.line, lineWidth: 1)
                    .frame(width: 180, height: 180)
                Circle()
                    .fill(orbColor)
                    .frame(width: 92, height: 92)
                    .scaleEffect(listener.isListening ? 1 + CGFloat(listener.level) * 0.9 : 1)
                    .animation(.easeOut(duration: 0.12), value: listener.level)
                if let last = listener.detections.first, Date().timeIntervalSince(last.date) < 2 {
                    Text("叮！")
                        .font(.system(size: 28, weight: .heavy))
                        .foregroundStyle(Palette.background)
                }
            }
            .frame(maxWidth: .infinity)
            Text(listener.status)
                .font(.headline)
                .foregroundStyle(Palette.text)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
    }

    private var mainButton: some View {
        Button {
            Task { await listener.toggle() }
        } label: {
            Text(listener.isListening ? "停止" : "開始聽")
                .font(.title2.weight(.bold))
                .frame(maxWidth: .infinity, minHeight: 60)
                .foregroundStyle(listener.isListening ? Palette.text : Palette.background)
                .background(listener.isListening ? Palette.card : Palette.accent)
                .clipShape(RoundedRectangle(cornerRadius: 16))
        }
    }

    private var stats: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                StatCard(title: "電腦", value: macText)
                StatCard(title: "叫醒／問了", value: "\(listener.detections.count)／\(listener.exchanges.count)")
                StatCard(title: "已經聽了", value: elapsedText(now: context.date))
                StatCard(title: "耗電", value: drainText(now: context.date))
                StatCard(title: "麥克風", value: micText)
            }
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionTitle("設定")
            Picker("靈敏度", selection: $listener.sensitivity) {
                ForEach(WakeWordDetector.Sensitivity.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            Text("叫不醒就調「靈敏」；常常沒叫它卻叮一聲就調「保守」。")
                .font(.footnote)
                .foregroundStyle(Palette.muted)
            Toggle(isOn: $listener.highQualityBluetooth) {
                Text("AirPods 高品質收音")
                    .foregroundStyle(Palette.text)
            }
            Text("iOS 26 加 AirPods Pro 2 才有作用。可以開關比較：聽音樂時音質有沒有變差。")
                .font(.footnote)
                .foregroundStyle(Palette.muted)
            phoneEarsRow
            Text("電腦位址")
                .foregroundStyle(Palette.text)
            TextField("辦公室 Mac 在 Tailscale 裡的名稱", text: $hostDraft)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .submitLabel(.done)
                .onSubmit { listener.macHost = hostDraft }
                .padding(12)
                .background(Palette.card)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .foregroundStyle(Palette.text)
            Text("iPhone 的 Tailscale 要打開，才連得到辦公室的 Mac。")
                .font(.footnote)
                .foregroundStyle(Palette.muted)
        }
    }

    /// iPhone 自己聽懂你講的話：模型沒裝就給一個下載按鈕（從 Apple 下載，按了才下載）
    @ViewBuilder private var phoneEarsRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("聽懂你講話：\(listener.phoneEngine == .speech ? "iPhone（新模型）" : "iPhone（聽寫）")")
                .foregroundStyle(Palette.text)
            switch listener.phoneModel {
            case .needsDownload:
                Button {
                    Task { await listener.downloadPhoneModel() }
                } label: {
                    Text("從 Apple 下載台灣中文辨識模型\(sizeText)")
                        .font(.subheadline.weight(.semibold))
                }
                Text("還沒下載之前，由辦公室的電腦聽。")
                    .font(.footnote)
                    .foregroundStyle(Palette.muted)
            case .downloading(let fraction):
                ProgressView(value: fraction)
            case .unsupported, .failed:
                Text("\(WakeListener.describe(listener.phoneModel))，改由辦公室的電腦聽。")
                    .font(.footnote)
                    .foregroundStyle(Palette.muted)
            case .ready, nil:
                Text("在手機上直接轉成字，不上傳。")
                    .font(.footnote)
                    .foregroundStyle(Palette.muted)
            }
        }
    }

    private var sizeText: String {
        guard let bytes = listener.phoneModelSize else { return "" }
        return "（約 \(max(1, bytes / 1_000_000)) MB）"
    }

    private var recent: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionTitle("最近問答")
            if listener.exchanges.isEmpty {
                Text("還沒有")
                    .foregroundStyle(Palette.muted)
            } else {
                ForEach(listener.exchanges.prefix(10)) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.date, format: .dateTime.hour().minute())
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(Palette.muted)
                        Text(item.question)
                            .font(.headline)
                            .foregroundStyle(Palette.text)
                        Text(item.answer.isEmpty ? "…" : item.answer)
                            .foregroundStyle(Palette.muted)
                    }
                }
            }
        }
    }

    private var howTo: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("怎麼測")
            ForEach(Array(Self.steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .top, spacing: 10) {
                    Text("\(index + 1)")
                        .font(.headline)
                        .foregroundStyle(Palette.accent)
                    Text(step)
                        .foregroundStyle(Palette.text)
                }
            }
        }
    }

    private static let steps = [
        "打開 iPhone 的 Tailscale，戴上 AirPods，按「開始聽」，鎖住手機放進口袋。",
        "喊「小呆呆」，聽到「叮」就直接問，例如「一天有幾小時？」。",
        "講完停一下，聽到「嘟」就是送出了，一般問題幾秒內回答。",
        "要查比較久的，它會先說「收到，我去做」；做好會「叮」一聲再講。",
        "怪怪的就按「分享測試紀錄」傳給 Claude，或回辦公室接上 Mac。",
    ]

    private var macText: String {
        guard listener.isListening else { return "—" }
        return listener.macConnected ? "已連上" : "連不到"
    }

    private var micText: String {
        guard listener.inputSampleRate > 0 else { return "—" }
        return "\(listener.inputName)\n\(Int(listener.inputSampleRate / 1000)) kHz"
    }

    private func elapsedText(now: Date) -> String {
        guard let start = listener.startedAt, listener.isListening else { return "—" }
        let seconds = Int(now.timeIntervalSince(start))
        return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }

    private func drainText(now: Date) -> String {
        guard let start = listener.startedAt, listener.isListening,
              listener.startBattery >= 0, listener.battery >= 0
        else { return "—" }
        let hours = now.timeIntervalSince(start) / 3600
        guard hours >= 1.0 / 6 else { return "10 分鐘後\n開始算" }
        let percent = Double(listener.startBattery - listener.battery) * 100 / hours
        return String(format: "%.1f%%／小時", max(0, percent))
    }
}

private struct StatCard: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.footnote)
                .foregroundStyle(Palette.muted)
            Text(value)
                .font(.title3.weight(.bold).monospacedDigit())
                .foregroundStyle(Palette.text)
                .lineLimit(2)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, minHeight: 78, alignment: .topLeading)
        .padding(14)
        .background(Palette.card)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

private struct SectionTitle: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.headline)
            .foregroundStyle(Palette.muted)
    }
}

enum Palette {
    static let background = Color(red: 0x0a / 255, green: 0x0a / 255, blue: 0x0a / 255)
    static let text = Color(red: 0xf5 / 255, green: 0xf4 / 255, blue: 0xf0 / 255)
    static let accent = Color(red: 0xff / 255, green: 0x3c / 255, blue: 0x00 / 255)
    static let muted = Color(white: 0.6)
    static let card = Color(white: 0.12)
    static let line = Color(white: 0.22)
}
