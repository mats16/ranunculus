import Foundation
import CVosk

/// VOSK C API の Swift ラッパー。スレッドセーフではないため、単一のシリアルキューからのみ使用すること。
final class VoskWrapper: @unchecked Sendable {

    /// スタブライブラリかどうかを判定する。
    /// 存在しないパスでモデルロードを試み、成功すればスタブと判断する（本物は NULL を返す）。
    static func isStubLibrary() -> Bool {
        vosk_set_log_level(-1)
        let probePath = "/nonexistent_vosk_probe_\(ProcessInfo.processInfo.globallyUniqueString)"
        if let probe = vosk_model_new(probePath) {
            vosk_model_free(probe)
            return true
        }
        return false
    }
    private let model: OpaquePointer
    private let recognizer: OpaquePointer

    /// VOSK モデルを読み込み、レコグナイザーを初期化する。
    /// - Parameters:
    ///   - modelPath: VOSK モデルディレクトリのパス
    ///   - sampleRate: 音声サンプルレート（デフォルト 16000Hz）
    /// - Returns: 読み込み失敗時は nil
    init?(modelPath: String, sampleRate: Float = 16000.0) {
        vosk_set_log_level(-1)

        guard let m = vosk_model_new(modelPath) else {
            return nil
        }
        self.model = m

        guard let r = vosk_recognizer_new(m, sampleRate) else {
            vosk_model_free(m)
            return nil
        }
        self.recognizer = r

        // ワードタイムスタンプを有効化（将来の拡張用）
        vosk_recognizer_set_words(r, 1)
    }

    /// 音声データを受け入れる。
    /// - Parameter data: 16-bit signed PCM モノラル 16kHz のバイト列
    /// - Returns: 発話の区切り（無音）を検出した場合 true
    func acceptWaveform(data: Data) -> Bool {
        data.withUnsafeBytes { buffer in
            guard let ptr = buffer.baseAddress?.assumingMemoryBound(to: CChar.self) else {
                return false
            }
            let result = vosk_recognizer_accept_waveform(recognizer, ptr, Int32(buffer.count))
            return result != 0
        }
    }

    /// 確定した認識結果を JSON 文字列で取得する。
    /// acceptWaveform が true を返した後に呼び出す。
    func result() -> String {
        String(cString: vosk_recognizer_result(recognizer))
    }

    /// 部分的な認識結果を JSON 文字列で取得する。
    /// acceptWaveform が false を返した後に呼び出す。
    func partialResult() -> String {
        String(cString: vosk_recognizer_partial_result(recognizer))
    }

    /// ストリーム終了時の最終結果を JSON 文字列で取得する。
    func finalResult() -> String {
        String(cString: vosk_recognizer_final_result(recognizer))
    }

    /// レコグナイザーをリセットして新しい発話に備える。
    func reset() {
        vosk_recognizer_reset(recognizer)
    }

    deinit {
        vosk_recognizer_free(recognizer)
        vosk_model_free(model)
    }
}
