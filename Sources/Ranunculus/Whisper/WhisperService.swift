import Foundation

/// kotoba-whisper による高精度文字起こしサービス。
/// バックグラウンドで WhisperQueue からジョブを取得し、WAV ファイルを再認識する。
final class WhisperService: @unchecked Sendable {
    private var wrapper: WhisperWrapper?
    private let queue: WhisperQueue
    private let store: TranscriptStore
    private var processingTask: Task<Void, Never>?

    /// Whisper 推論をスキップする最小セグメント長（秒）
    private static let minimumDuration: TimeInterval = 1.0

    /// 日本語用の初期プロンプト
    private static let initialPrompt = "これは日本語の音声です。適切な句読点を用いて正確に書き起こしてください。"

    init(queue: WhisperQueue, store: TranscriptStore) {
        self.queue = queue
        self.store = store
    }

    /// モデルを読み込む。
    /// - Parameter modelPath: GGML モデルファイルのパス
    /// - Returns: 読み込み成功なら true
    func loadModel(at modelPath: String) -> Bool {
        guard FileManager.default.fileExists(atPath: modelPath) else { return false }
        wrapper = WhisperWrapper(modelPath: modelPath)
        return wrapper != nil
    }

    /// モデルが読み込まれているか。
    var isModelLoaded: Bool {
        wrapper != nil
    }

    /// 処理ループを開始する。
    func start() {
        guard wrapper != nil else { return }

        processingTask = Task.detached { [weak self] in
            guard let self else { return }
            let stream = await self.queue.makeStream()

            for await segmentID in stream {
                guard !Task.isCancelled else { break }
                await self.processSegment(id: segmentID)
            }
        }
    }

    /// 処理ループを停止する。
    func stop() {
        processingTask?.cancel()
        processingTask = nil
    }

    // MARK: - Private

    private func processSegment(id: UUID) async {
        // ストアからセグメント情報を取得
        let segment = await MainActor.run { store.segments.first { $0.id == id } }
        guard let segment, let wavPath = segment.wavFilePath else {
            await MainActor.run { store.updateWithWhisperResult(id: id, text: nil) }
            return
        }

        // ステータスを processing に更新
        await MainActor.run { store.updateStatus(id: id, status: .processing) }

        // WAV を読み込み
        let audioFrames: [Float]
        do {
            audioFrames = try WAVFileReader.readAsFloat(path: wavPath)
        } catch {
            print("[WhisperService] WAV 読み込みエラー: \(error)")
            await MainActor.run { store.updateWithWhisperResult(id: id, text: nil) }
            return
        }

        // 1秒未満はスキップ
        let durationSeconds = Double(audioFrames.count) / 16000.0
        if durationSeconds < Self.minimumDuration {
            print("[WhisperService] セグメントが短すぎます (\(String(format: "%.1f", durationSeconds))s)、スキップ")
            await MainActor.run { store.updateWithWhisperResult(id: id, text: nil) }
            return
        }

        // Whisper 推論（CPU 集約的処理）
        guard let wrapper else {
            await MainActor.run { store.updateWithWhisperResult(id: id, text: nil) }
            return
        }

        let segments = wrapper.transcribe(
            audioFrames: audioFrames,
            language: "ja",
            initialPrompt: Self.initialPrompt,
            beamSize: 2
        )

        let fullText = segments.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined()

        await MainActor.run {
            store.updateWithWhisperResult(id: id, text: fullText.isEmpty ? nil : fullText)
        }

        if !fullText.isEmpty {
            print("[WhisperService] 完了: \(fullText.prefix(80))...")
        }

        // 一時 WAV ファイルを削除
        try? FileManager.default.removeItem(atPath: wavPath)
    }
}
