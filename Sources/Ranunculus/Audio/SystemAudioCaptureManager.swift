import AVFoundation
import ScreenCaptureKit

/// 音声入力ソースの選択モード
enum AudioSourceMode: String, CaseIterable {
    case microphone = "マイク"
    case systemAudio = "システム音声"
    case both = "両方"
}

enum SystemAudioCaptureError: Error, LocalizedError {
    case screenRecordingPermissionDenied
    case noDisplayFound

    var errorDescription: String? {
        switch self {
        case .screenRecordingPermissionDenied:
            return "画面収録のアクセスが拒否されました。システム設定 > プライバシーとセキュリティ > 画面収録 で許可してください"
        case .noDisplayFound:
            return "利用可能なディスプレイが見つかりません"
        }
    }
}

/// ScreenCaptureKit を使用してシステム音声をキャプチャし、
/// VOSK が要求する 16kHz モノラル Int16 PCM フォーマットに変換する。
final class SystemAudioCaptureManager: NSObject, @unchecked Sendable {
    private var stream: SCStream?
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private let audioQueue = DispatchQueue(label: "com.ranunculus.systemaudio", qos: .userInitiated)

    /// VOSK 用ターゲットフォーマット: 16kHz, モノラル, Int16
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16000,
        channels: 1,
        interleaved: true
    )!

    /// 変換済み PCM データのコールバック
    var onAudioData: ((Data) -> Void)?

    /// ストリームが予期せず停止した場合のコールバック
    var onStreamStopped: ((Error?) -> Void)?

    /// 画面収録パーミッションを確認する。
    static func requestPermission() async -> Bool {
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            return true
        } catch {
            return false
        }
    }

    /// システム音声キャプチャを開始する。
    func startCapture() async throws {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            throw SystemAudioCaptureError.screenRecordingPermissionDenied
        }

        guard let display = content.displays.first else {
            throw SystemAudioCaptureError.noDisplayFound
        }

        // 自アプリのウィンドウを除外
        let bundleID = Bundle.main.bundleIdentifier
        let ownWindows = content.windows.filter { $0.owningApplication?.bundleIdentifier == bundleID }
        let filter = SCContentFilter(display: display, excludingWindows: ownWindows)

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = 48000
        config.channelCount = 2

        // ビデオオーバーヘッドを最小化（音声のみ必要だが完全無効化は不可）
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.showsCursor = false

        if #available(macOS 14.0, *) {
            config.excludesCurrentProcessAudio = true
        }

        let newStream = SCStream(filter: filter, configuration: config, delegate: self)
        try newStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        try await newStream.startCapture()
        self.stream = newStream
    }

    /// キャプチャを停止する。
    func stopCapture() {
        guard let stream = self.stream else { return }
        self.stream = nil
        Task {
            try? await stream.stopCapture()
        }
        converter = nil
        sourceFormat = nil
    }

    // MARK: - Private

    private func processAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard let formatDesc = sampleBuffer.formatDescription else { return }
        guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else { return }

        let currentFormat = AVAudioFormat(streamDescription: asbd)
        guard let currentFormat else { return }

        if sourceFormat != currentFormat {
            sourceFormat = currentFormat
            converter = AVAudioConverter(from: currentFormat, to: targetFormat)
            converter?.sampleRateConverterQuality = AVAudioQuality.medium.rawValue
        }
        guard let converter else { return }

        let frameCount = AVAudioFrameCount(sampleBuffer.numSamples)
        guard frameCount > 0 else { return }

        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: currentFormat, frameCapacity: frameCount) else { return }
        inputBuffer.frameLength = frameCount

        let status1 = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: inputBuffer.mutableAudioBufferList
        )
        guard status1 == noErr else { return }

        let ratio = targetFormat.sampleRate / currentFormat.sampleRate
        let outputFrameCount = AVAudioFrameCount(Double(frameCount) * ratio)
        guard outputFrameCount > 0 else { return }

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: outputFrameCount
        ) else { return }

        var convError: NSError?
        var inputConsumed = false

        let status = converter.convert(to: outputBuffer, error: &convError) { _, outStatus in
            if inputConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            outStatus.pointee = .haveData
            inputConsumed = true
            return inputBuffer
        }

        guard status != .error, convError == nil else { return }
        guard outputBuffer.frameLength > 0 else { return }

        guard let int16Data = outputBuffer.int16ChannelData else { return }
        let byteCount = Int(outputBuffer.frameLength) * MemoryLayout<Int16>.size
        let data = Data(bytes: int16Data[0], count: byteCount)

        onAudioData?(data)
    }
}

// MARK: - SCStreamOutput

extension SystemAudioCaptureManager: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        processAudioSampleBuffer(sampleBuffer)
    }
}

// MARK: - SCStreamDelegate

extension SystemAudioCaptureManager: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        self.stream = nil
        converter = nil
        sourceFormat = nil
        onStreamStopped?(error)
    }
}
