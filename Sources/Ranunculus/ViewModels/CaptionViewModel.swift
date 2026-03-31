import SwiftUI
import Combine

/// processingQueue 上で VOSK にオーディオを供給し、結果をメインスレッドに送る。
/// @MainActor の外で動作するため @unchecked Sendable。
/// 内部状態は processingQueue のシリアル実行で保護される。
private final class AudioProcessor: @unchecked Sendable {
    private let vosk: VoskWrapper
    private let processingQueue = DispatchQueue(label: "com.livecaption.vosk", qos: .userInitiated)

    private var lastPartialUpdate = Date.distantPast
    private let partialUpdateInterval: TimeInterval = 0.1

    /// 確定テキストのコールバック（メインスレッドで呼ばれる）
    var onFinalResult: ((String) -> Void)?
    /// 部分テキストのコールバック（メインスレッドで呼ばれる）
    var onPartialResult: ((String) -> Void)?

    init(vosk: VoskWrapper) {
        self.vosk = vosk
    }

    /// オーディオデータを非同期で処理する。AudioCaptureManager のコールバックから呼ぶ。
    func feedAudio(_ data: Data) {
        processingQueue.async { [self] in
            let isFinal = vosk.acceptWaveform(data: data)

            if isFinal {
                let json = vosk.result()
                if let text = VoskResultParser.parseFinal(json), !text.isEmpty {
                    DispatchQueue.main.async { [self] in
                        onFinalResult?(text)
                    }
                }
            } else {
                let now = Date()
                guard now.timeIntervalSince(lastPartialUpdate) >= partialUpdateInterval else { return }
                lastPartialUpdate = now

                let json = vosk.partialResult()
                if let text = VoskResultParser.parsePartial(json) {
                    DispatchQueue.main.async { [self] in
                        onPartialResult?(text)
                    }
                }
            }
        }
    }

    /// ストリーム終了時の最終結果を取得する。
    func finalize(completion: @escaping (String?) -> Void) {
        processingQueue.async { [self] in
            let json = vosk.finalResult()
            let text = VoskResultParser.parseFinal(json)
            DispatchQueue.main.async {
                completion(text?.isEmpty == false ? text : nil)
            }
        }
    }
}

/// 音声キャプチャ → VOSK 認識 → UI 更新 を統括するビューモデル。
@MainActor
final class CaptionViewModel: ObservableObject {
    // MARK: - Published State

    @Published var captionText: String = ""
    @Published var partialText: String = ""
    @Published var isListening: Bool = false
    @Published var modelLoaded: Bool = false
    @Published var isLoadingModel: Bool = false
    @Published var errorMessage: String?
    @Published var statusMessage: String = "モデル未読込"

    // MARK: - Private

    private var audioManager: AudioCaptureManager?
    private var audioProcessor: AudioProcessor?
    private var voskWrapper: VoskWrapper?

    /// 直近の認識済みテキスト行
    private var recognizedLines: [String] = []
    private let maxLines = 8

    // MARK: - Model Management

    /// バンドル内のモデルを自動検出して読み込む。
    func loadBundledModel() {
        let searchPaths = [
            findProjectModelPath(),
            Bundle.main.resourcePath.map { "\($0)/vosk-model-small-ja-0.22" },
            "Resources/vosk-model-small-ja-0.22",
        ].compactMap { $0 }

        for path in searchPaths {
            if FileManager.default.fileExists(atPath: path) {
                loadModel(at: path)
                return
            }
        }

        errorMessage = "VOSK モデルが見つかりません。scripts/setup.sh を実行してください。"
        statusMessage = "モデルが見つかりません"
    }

    /// 指定パスからモデルを読み込む。
    func loadModel(at path: String) {
        isLoadingModel = true
        statusMessage = "モデル読込中..."
        errorMessage = nil

        let modelPath = path
        Task.detached {
            if VoskWrapper.isStubLibrary() {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.isLoadingModel = false
                    self.errorMessage = "libvosk.dylib がスタブです。scripts/setup.sh を実行してください。"
                    self.statusMessage = "ライブラリ未設定"
                }
                return
            }

            let wrapper = VoskWrapper(modelPath: modelPath)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isLoadingModel = false
                if let wrapper {
                    self.voskWrapper = wrapper
                    self.modelLoaded = true
                    self.statusMessage = "モデル読込完了"
                } else {
                    self.errorMessage = "VOSK モデルの読み込みに失敗しました: \(modelPath)"
                    self.statusMessage = "モデル読込失敗"
                }
            }
        }
    }

    // MARK: - Recording Control

    func toggleListening() {
        if isListening {
            stopListening()
        } else {
            Task { await startListening() }
        }
    }

    func startListening() async {
        guard let vosk = voskWrapper else {
            errorMessage = "モデルが読み込まれていません"
            return
        }

        let hasPermission = await AudioCaptureManager.requestMicrophonePermission()
        guard hasPermission else {
            errorMessage = AudioCaptureError.microphonePermissionDenied.localizedDescription
            return
        }

        // AudioProcessor を作成し、コールバックを設定
        let processor = AudioProcessor(vosk: vosk)
        processor.onFinalResult = { [weak self] text in
            self?.appendFinalText(text)
            self?.partialText = ""
        }
        processor.onPartialResult = { [weak self] text in
            self?.partialText = text
        }
        self.audioProcessor = processor

        // AudioCaptureManager を作成し、AudioProcessor に接続
        let manager = AudioCaptureManager()
        manager.onAudioData = { [processor] data in
            processor.feedAudio(data)
        }

        do {
            try manager.startCapture()
            self.audioManager = manager
            self.isListening = true
            self.statusMessage = "認識中..."
            self.errorMessage = nil
        } catch {
            self.errorMessage = error.localizedDescription
            self.audioProcessor = nil
        }
    }

    func stopListening() {
        audioManager?.stopCapture()
        audioManager = nil
        isListening = false
        statusMessage = "停止"

        audioProcessor?.finalize { [weak self] text in
            if let text {
                self?.appendFinalText(text)
            }
            self?.partialText = ""
        }
        audioProcessor = nil
    }

    /// 認識テキストをクリアする。
    func clearText() {
        recognizedLines.removeAll()
        captionText = ""
        partialText = ""
    }

    // MARK: - Private Helpers

    private func appendFinalText(_ text: String) {
        recognizedLines.append(text)
        if recognizedLines.count > maxLines {
            recognizedLines.removeFirst(recognizedLines.count - maxLines)
        }
        captionText = recognizedLines.joined(separator: "\n")
    }

    /// プロジェクトルートの Resources ディレクトリからモデルパスを探索する。
    private func findProjectModelPath() -> String? {
        let executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        var dir = executableURL.deletingLastPathComponent()

        for _ in 0..<10 {
            let candidate = dir.appendingPathComponent("Resources/vosk-model-small-ja-0.22").path
            if FileManager.default.fileExists(atPath: candidate) {
                return candidate
            }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }
}
