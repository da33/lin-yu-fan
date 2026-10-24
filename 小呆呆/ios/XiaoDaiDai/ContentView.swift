import SwiftUI

/// 小呆呆喚醒詞測試畫面：黑底、米白字、橘紅重點色
struct ContentView: View {
    @StateObject private var listener = WakeListener()

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
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("小呆呆")
                .font(.system(size: 44, weight: .black))
                .foregroundStyle(Palette.text)
            Text("喚醒詞測試 · 鎖著手機也會聽")
                .font(.subheadline)
                .foregroundStyle(Palette.muted)
        }
    }

    private var orb: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .stroke(Palette.line, lineWidth: 1)
                    .frame(width: 180, height: 180)
                Circle()
                    .fill(listener.isListening ? Palette.accent : Palette.line)
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
                StatCard(title: "叫醒次數", value: "\(listener.detections.count)")
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
        }
    }

    private var recent: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("最近叫醒")
            if listener.detections.isEmpty {
                Text("還沒有")
                    .foregroundStyle(Palette.muted)
            } else {
                ForEach(listener.detections.prefix(20)) { item in
                    Text(item.date, format: .dateTime.hour().minute().second())
                        .font(.body.monospacedDigit())
                        .foregroundStyle(Palette.text)
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
        "戴上 AirPods，按「開始聽」，然後鎖住手機放進口袋。",
        "喊 10 次「小呆呆」，每次隔幾秒，數一數叮了幾次。",
        "不要管它，照平常一樣過 1 小時（可以聽音樂、講話）。沒叫它卻叮一聲，就是誤醒。",
        "回來看「叫醒次數」和「耗電」，再按「分享測試紀錄」傳給 Claude。",
    ]

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
