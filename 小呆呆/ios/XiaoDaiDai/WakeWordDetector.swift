import Foundation
import SherpaOnnx

/// 喚醒詞偵測：sherpa-onnx 中文關鍵詞偵測，免訓練、整個在手機上跑、不連網。
/// 關鍵詞寫在 Model/keywords.txt（拼音聲母韻母＋「@小呆呆」）。
/// 不是執行緒安全的：同一個實例只能在同一條佇列上使用。
final class WakeWordDetector {
    enum Sensitivity: String, CaseIterable, Identifiable {
        case sensitive = "靈敏"
        case standard = "標準"
        case strict = "保守"

        var id: String { rawValue }

        // 雲端實測（2026-10-24）：標準＝門檻 0.15、加權 1.5，合成聲音叫一次就醒 91%、10 分鐘真人國語誤醒 0 次
        var threshold: Float {
            switch self {
            case .sensitive: return 0.10
            case .standard: return 0.15
            case .strict: return 0.25
            }
        }

        var score: Float {
            switch self {
            case .sensitive: return 2.0
            case .standard: return 1.5
            case .strict: return 1.0
            }
        }
    }

    static let keyword = "小呆呆"

    private let spotter: SherpaOnnxKeywordSpotterWrapper

    /// 模型資料夾裡要有 encoder/decoder/joiner.int8.onnx、tokens.txt、keywords.txt
    init?(modelDirectory: URL, sensitivity: Sensitivity) {
        let path = { (name: String) in modelDirectory.appendingPathComponent(name).path }
        let required = ["encoder.int8.onnx", "decoder.int8.onnx", "joiner.int8.onnx", "tokens.txt", "keywords.txt"]
        guard required.allSatisfy({ FileManager.default.fileExists(atPath: path($0)) }) else { return nil }

        let transducer = sherpaOnnxOnlineTransducerModelConfig(
            encoder: path("encoder.int8.onnx"),
            decoder: path("decoder.int8.onnx"),
            joiner: path("joiner.int8.onnx")
        )
        let model = sherpaOnnxOnlineModelConfig(tokens: path("tokens.txt"), transducer: transducer, numThreads: 1)
        var config = sherpaOnnxKeywordSpotterConfig(
            featConfig: sherpaOnnxFeatureConfig(sampleRate: 16000, featureDim: 80),
            modelConfig: model,
            keywordsFile: path("keywords.txt"),
            keywordsScore: sensitivity.score,
            keywordsThreshold: sensitivity.threshold
        )
        spotter = SherpaOnnxKeywordSpotterWrapper(config: &config)
        if spotter.spotter == nil || spotter.stream == nil { return nil }
    }

    /// 餵一段單聲道聲音（任何取樣率，內部會轉成 16kHz），回傳這段裡偵測到的關鍵詞
    func process(_ samples: [Float], sampleRate: Int) -> [String] {
        spotter.acceptWaveform(samples: samples, sampleRate: sampleRate)
        var found: [String] = []
        while spotter.isReady() {
            spotter.decode()
            let keyword = spotter.getResult().keyword
            if !keyword.isEmpty {
                found.append(keyword)
                spotter.reset() // 偵測到之後要馬上 reset，才不會重複觸發
            }
        }
        return found
    }

    /// 回答完、回到聽「小呆呆」時重來一次，免得還記著上一段聲音
    func reset() {
        spotter.reset()
    }
}
