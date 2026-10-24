import AVFoundation

/// 提示音：叮（叫醒、有報告）、嘟（講完、送出了）
enum Chime {
    static let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!

    /// 「叮」：兩個短音
    static func makeBuffer() -> AVAudioPCMBuffer {
        tones([(880, 0.11), (1318.5, 0.2)])
    }

    /// 「嘟」：一個低一點的短音，表示收到你講的話了
    static func beep() -> AVAudioPCMBuffer {
        tones([(587.3, 0.14)])
    }

    private static func tones(_ notes: [(frequency: Double, seconds: Double)]) -> AVAudioPCMBuffer {
        let rate = format.sampleRate
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

/// 把 WAV（Mac 用美佳念的、或 App 裡錄好的）轉成可以直接排進播放器的格式
enum SpeechAudio {
    static func decode(_ wav: Data, to format: AVAudioFormat = Chime.format) -> AVAudioPCMBuffer? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        guard (try? wav.write(to: url)) != nil else { return nil }
        return load(url, to: format)
    }

    /// App 裡錄好的句子，例如「連不到電腦」
    static func bundled(_ name: String, to format: AVAudioFormat = Chime.format) -> AVAudioPCMBuffer? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "wav") else { return nil }
        return load(url, to: format)
    }

    private static func load(_ url: URL, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let file = try? AVAudioFile(forReading: url),
              let source = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: source)) != nil
        else { return nil }
        if source.format == format { return source }
        guard let converter = AVAudioConverter(from: source.format, to: format),
              let out = AVAudioPCMBuffer(pcmFormat: format,
                                         frameCapacity: AVAudioFrameCount(Double(source.frameLength) * format.sampleRate / source.format.sampleRate) + 1024)
        else { return nil }
        var given = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if given {
                status.pointee = .endOfStream
                return nil
            }
            given = true
            status.pointee = .haveData
            return source
        }
        return error == nil && out.frameLength > 0 ? out : nil
    }
}
