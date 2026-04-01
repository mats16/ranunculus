import Foundation
import whisper

/// whisper.cpp C API の Swift ラッパー。
/// スレッドセーフではないため、呼び出し側で排他制御すること。
final class WhisperWrapper {
    private let context: OpaquePointer

    /// モデルファイルからコンテキストを作成する。
    /// - Parameter modelPath: GGML モデルファイルのパス
    /// - Returns: 読み込み失敗時は nil
    init?(modelPath: String) {
        var cparams = whisper_context_default_params()
        cparams.use_gpu = true
        cparams.flash_attn = true

        guard let ctx = whisper_init_from_file_with_params(modelPath, cparams) else {
            return nil
        }
        self.context = ctx
    }

    deinit {
        whisper_free(context)
    }

    /// 文字起こし結果のセグメント。
    struct Segment {
        let startTimeMs: Int
        let endTimeMs: Int
        let text: String
    }

    /// 音声データを文字起こしする。
    /// - Parameters:
    ///   - audioFrames: 16kHz モノラル f32 PCM サンプル配列
    ///   - language: 言語コード（"ja", "en", "auto" など）
    ///   - initialPrompt: デコーダーへの初期プロンプト
    ///   - beamSize: ビームサーチのビーム数
    /// - Returns: セグメント配列
    func transcribe(
        audioFrames: [Float],
        language: String = "ja",
        initialPrompt: String? = nil,
        beamSize: Int32 = 2
    ) -> [Segment] {
        guard !audioFrames.isEmpty else { return [] }

        var params = whisper_full_default_params(WHISPER_SAMPLING_BEAM_SEARCH)
        params.n_threads = Int32(min(8, ProcessInfo.processInfo.processorCount))
        params.beam_search.beam_size = beamSize
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = false
        params.print_special = false
        params.no_timestamps = false
        params.single_segment = false
        params.suppress_blank = true
        params.suppress_nst = true

        // 言語設定
        let langCStr = strdup(language)
        params.language = UnsafePointer(langCStr)

        // 初期プロンプト設定
        var promptCStr: UnsafeMutablePointer<CChar>?
        if let prompt = initialPrompt {
            promptCStr = strdup(prompt)
            params.initial_prompt = UnsafePointer(promptCStr)
        }

        // 推論実行
        let result = audioFrames.withUnsafeBufferPointer { buffer in
            whisper_full(context, params, buffer.baseAddress, Int32(audioFrames.count))
        }

        // メモリ解放
        free(langCStr)
        free(promptCStr)

        guard result == 0 else {
            print("[WhisperWrapper] whisper_full failed with code: \(result)")
            return []
        }

        // セグメントを取得
        let segmentCount = whisper_full_n_segments(context)
        var segments: [Segment] = []
        segments.reserveCapacity(Int(segmentCount))

        for i in 0..<segmentCount {
            guard let textPtr = whisper_full_get_segment_text(context, i) else { continue }
            let t0 = whisper_full_get_segment_t0(context, i)
            let t1 = whisper_full_get_segment_t1(context, i)

            segments.append(Segment(
                startTimeMs: Int(t0) * 10,  // whisper.cpp は ms/10 単位
                endTimeMs: Int(t1) * 10,
                text: String(cString: textPtr)
            ))
        }

        return segments
    }
}
