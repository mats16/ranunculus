import SwiftUI
import Combine

/// VOSK の確定結果 + WAV 情報をまとめた構造体。
struct FinalizedSegmentInfo {
    let voskText: String
    let wavFilePath: String?
    let duration: TimeInterval
    let startTime: Date
}

/// processingQueue 上で VOSK にオーディオを供給しつつ WAV に書き込み、
/// 結果をメインスレッドに送る。
/// @MainActor の外で動作するため @unchecked Sendable。
/// 内部状態は processingQueue のシリアル実行で保護される。
private final class AudioProcessor: @unchecked Sendable {
    private let vosk: VoskWrapper
    private let processingQueue = DispatchQueue(label: "com.ranunculus.vosk", qos: .userInitiated)

    private var lastPartialUpdate = Date.distantPast
    private let partialUpdateInterval: TimeInterval = 0.1

    private var wavWriter: WAVSegmentWriter?

    var onFinalResult: ((FinalizedSegmentInfo) -> Void)?
    var onPartialResult: ((String) -> Void)?

    init(vosk: VoskWrapper) {
        self.vosk = vosk
    }

    func prepareWAVWriter() {
        processingQueue.async { [self] in
            do {
                wavWriter = try WAVSegmentWriter.create()
            } catch {
                print("[AudioProcessor] WAV ライター作成失敗: \(error)")
            }
        }
    }

    func feedAudio(_ data: Data) {
        processingQueue.async { [self] in
            wavWriter?.write(data)

            let isFinal = vosk.acceptWaveform(data: data)

            if isFinal {
                let json = vosk.result()
                if let text = VoskResultParser.parseFinal(json), !text.isEmpty {
                    let info = finalizeCurrentWriter()

                    do {
                        wavWriter = try WAVSegmentWriter.create()
                    } catch {
                        print("[AudioProcessor] 新しい WAV ライター作成失敗: \(error)")
                        wavWriter = nil
                    }

                    DispatchQueue.main.async { [self] in
                        onFinalResult?(FinalizedSegmentInfo(
                            voskText: text,
                            wavFilePath: info?.path,
                            duration: info?.duration ?? 0,
                            startTime: info?.startTime ?? Date()
                        ))
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

    func finalize(completion: @escaping (FinalizedSegmentInfo?) -> Void) {
        processingQueue.async { [self] in
            let json = vosk.finalResult()
            let text = VoskResultParser.parseFinal(json)
            let info = finalizeCurrentWriter()
            wavWriter = nil

            DispatchQueue.main.async {
                guard let text, !text.isEmpty, let info else {
                    completion(nil)
                    return
                }
                completion(FinalizedSegmentInfo(
                    voskText: text,
                    wavFilePath: info.path,
                    duration: info.duration,
                    startTime: info.startTime
                ))
            }
        }
    }

    /// 現在の WAV ライターを finalize し、情報を返す。startTime は finalize 前に取得。
    private func finalizeCurrentWriter() -> (path: String, duration: TimeInterval, startTime: Date)? {
        guard let writer = wavWriter else { return nil }
        let startTime = writer.startTime
        let result = writer.finalize()
        return (path: result.path, duration: result.duration, startTime: startTime)
    }
}

/// 音声キャプチャ → VOSK 認識 → WAV 書き込み → Whisper 再認識 → UI 更新 を統括するビューモデル。
@MainActor
final class CaptionViewModel: ObservableObject {
    // MARK: - Published State

    @Published var store = TranscriptStore()
    @Published var isListening: Bool = false
    @Published var voskModelLoaded: Bool = false
    @Published var whisperModelLoaded: Bool = false
    @Published var isLoadingModel: Bool = false
    @Published var errorMessage: String?
    @Published var statusMessage: String = "モデル未読込"
    @Published var audioSourceMode: AudioSourceMode = .both

    // MARK: - Private

    private var audioManager: AudioCaptureManager?
    private var systemAudioManager: SystemAudioCaptureManager?
    private var audioProcessor: AudioProcessor?
    private var voskWrapper: VoskWrapper?
    private let whisperQueue = WhisperQueue()
    private var whisperService: WhisperService?
    private var obsidianExporter: ObsidianExporter?

    private static let fileDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        return f
    }()

    // MARK: - Model Management

    func loadBundledModel() {
        guard let path = findModelPath(named: "vosk-model-small-ja-0.22") else {
            errorMessage = "VOSK モデルが見つかりません。scripts/setup.sh を実行してください。"
            statusMessage = "モデルが見つかりません"
            return
        }
        loadVoskModel(at: path)
    }

    func loadVoskModel(at path: String) {
        isLoadingModel = true
        statusMessage = "VOSK モデル読込中..."
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
                if let wrapper {
                    self.voskWrapper = wrapper
                    self.voskModelLoaded = true
                    self.statusMessage = "VOSK 読込完了"
                    self.loadWhisperModel()
                } else {
                    self.isLoadingModel = false
                    self.errorMessage = "VOSK モデルの読み込みに失敗しました: \(modelPath)"
                    self.statusMessage = "VOSK 読込失敗"
                }
            }
        }
    }

    private func loadWhisperModel() {
        statusMessage = "Whisper モデル読込中..."

        guard let modelPath = findModelPath(named: "ggml-kotoba-whisper-v2.0-q5_0.bin") else {
            isLoadingModel = false
            whisperModelLoaded = false
            statusMessage = "VOSK のみ（Whisper モデル未検出）"
            return
        }

        let service = WhisperService(queue: whisperQueue, store: store)
        Task.detached {
            let success = service.loadModel(at: modelPath)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isLoadingModel = false
                if success {
                    self.whisperService = service
                    self.whisperModelLoaded = true
                    self.statusMessage = "モデル読込完了"
                } else {
                    self.statusMessage = "VOSK のみ（Whisper 読込失敗）"
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

        store.recordingStartTime = Date()
        obsidianExporter = ObsidianExporter(store: store) { [weak self] msg in
            self?.errorMessage = msg
        }

        let processor = AudioProcessor(vosk: vosk)
        processor.onFinalResult = { [weak self] info in
            self?.commitSegment(info)
        }
        processor.onPartialResult = { [weak self] text in
            self?.store.partialText = text
        }
        self.audioProcessor = processor
        processor.prepareWAVWriter()

        whisperService?.start()

        do {
            switch audioSourceMode {
            case .microphone:
                try await startMicrophoneCapture(processor: processor)
            case .systemAudio:
                try await startSystemAudioCapture(processor: processor)
            case .both:
                try await startMicrophoneCapture(processor: processor)
                try await startSystemAudioCapture(processor: processor)
            }
            self.isListening = true
            self.statusMessage = "録音中..."
            self.errorMessage = nil
        } catch {
            self.errorMessage = error.localizedDescription
            audioManager?.stopCapture()
            audioManager = nil
            systemAudioManager?.stopCapture()
            systemAudioManager = nil
            self.audioProcessor = nil
            whisperService?.stop()
        }
    }

    func stopListening() {
        audioManager?.stopCapture()
        audioManager = nil
        systemAudioManager?.stopCapture()
        systemAudioManager = nil
        isListening = false
        statusMessage = "停止中..."

        audioProcessor?.finalize { [weak self] info in
            guard let self else { return }

            if let info {
                self.commitSegment(info)
            }
            self.store.partialText = ""

            Task {
                await self.whisperQueue.finish()
                self.obsidianExporter?.stop()
                self.obsidianExporter = nil
                self.statusMessage = "停止"
            }
        }
        audioProcessor = nil
    }

    func clearText() {
        store.clear()
        obsidianExporter?.reset()
        Task { await whisperQueue.reset() }
    }

    func exportTranscript() {
        let text = store.exportAsText()
        guard !text.isEmpty else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "transcript_\(Self.fileDateFormatter.string(from: Date())).txt"

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Private Helpers

    private func startMicrophoneCapture(processor: AudioProcessor) async throws {
        let hasPermission = await AudioCaptureManager.requestMicrophonePermission()
        guard hasPermission else {
            throw AudioCaptureError.microphonePermissionDenied
        }

        let manager = AudioCaptureManager()
        manager.onAudioData = { [processor] data in
            processor.feedAudio(data)
        }
        try manager.startCapture()
        self.audioManager = manager
    }

    private func startSystemAudioCapture(processor: AudioProcessor) async throws {
        let hasPermission = await SystemAudioCaptureManager.requestPermission()
        guard hasPermission else {
            throw SystemAudioCaptureError.screenRecordingPermissionDenied
        }

        let manager = SystemAudioCaptureManager()
        manager.onAudioData = { [processor] data in
            processor.feedAudio(data)
        }
        manager.onStreamStopped = { [weak self] error in
            DispatchQueue.main.async {
                self?.errorMessage = error?.localizedDescription ?? "システム音声キャプチャが停止しました"
                if self?.audioManager == nil {
                    self?.isListening = false
                    self?.statusMessage = "停止"
                }
            }
        }
        try await manager.startCapture()
        self.systemAudioManager = manager
    }

    private func commitSegment(_ info: FinalizedSegmentInfo) {
        let segment = TranscriptSegment(
            startTime: info.startTime,
            endTime: info.startTime.addingTimeInterval(info.duration),
            voskText: info.voskText,
            wavFilePath: info.wavFilePath,
            status: whisperModelLoaded ? .pending : .done
        )
        store.addSegment(segment)
        store.partialText = ""

        if whisperModelLoaded, info.wavFilePath != nil {
            Task { await whisperQueue.enqueue(segmentID: segment.id) }
        } else if let path = info.wavFilePath {
            // Whisper 無効時は WAV ファイルを即削除
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    private func findModelPath(named name: String) -> String? {
        let executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        var dir = executableURL.deletingLastPathComponent()

        for _ in 0..<10 {
            let candidate = dir.appendingPathComponent("Resources/\(name)").path
            if FileManager.default.fileExists(atPath: candidate) {
                return candidate
            }
            dir = dir.deletingLastPathComponent()
        }

        if let bundlePath = Bundle.main.resourcePath {
            let candidate = "\(bundlePath)/\(name)"
            if FileManager.default.fileExists(atPath: candidate) {
                return candidate
            }
        }

        let relativePath = "Resources/\(name)"
        if FileManager.default.fileExists(atPath: relativePath) {
            return relativePath
        }

        return nil
    }
}
