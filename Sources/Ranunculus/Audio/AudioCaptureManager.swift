import AVFoundation

enum AudioCaptureError: Error, LocalizedError {
    case invalidHardwareFormat
    case converterCreationFailed
    case microphonePermissionDenied

    var errorDescription: String? {
        switch self {
        case .invalidHardwareFormat:
            return "無効なオーディオハードウェアフォーマットです"
        case .converterCreationFailed:
            return "オーディオフォーマットコンバーターの作成に失敗しました"
        case .microphonePermissionDenied:
            return "マイクのアクセスが拒否されました。システム設定 > プライバシーとセキュリティ > マイク で許可してください"
        }
    }
}

/// AVAudioEngine を使用してマイクからオーディオをキャプチャし、
/// VOSK が要求する 16kHz モノラル Int16 PCM フォーマットに変換する。
final class AudioCaptureManager {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?

    /// VOSK 用ターゲットフォーマット: 16kHz, モノラル, Int16
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16000,
        channels: 1,
        interleaved: true
    )!

    /// 変換済み PCM データのコールバック（オーディオスレッドから呼ばれる）
    var onAudioData: ((Data) -> Void)?

    /// マイクのパーミッションを確認・要求する。
    static func requestMicrophonePermission() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    /// マイクキャプチャを開始する。
    func startCapture() throws {
        let inputNode = engine.inputNode
        let hardwareFormat = inputNode.outputFormat(forBus: 0)

        guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0 else {
            throw AudioCaptureError.invalidHardwareFormat
        }

        // ハードウェアフォーマット → 16kHz Int16 モノラルへのコンバーター作成
        guard let conv = AVAudioConverter(from: hardwareFormat, to: targetFormat) else {
            throw AudioCaptureError.converterCreationFailed
        }
        conv.sampleRateConverterQuality = AVAudioQuality.medium.rawValue
        self.converter = conv

        // inputNode に tap を設置（フォーマットは必ずハードウェアネイティブ）
        let bufferSize: AVAudioFrameCount = 4096
        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: hardwareFormat) {
            [weak self] buffer, _ in
            self?.processAudioBuffer(buffer)
        }

        engine.prepare()
        try engine.start()
    }

    /// キャプチャを停止する。
    func stopCapture() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
    }

    /// AVAudioPCMBuffer を 16kHz Int16 に変換してコールバックに渡す。
    private func processAudioBuffer(_ inputBuffer: AVAudioPCMBuffer) {
        guard let converter = self.converter else { return }

        // サンプルレート変換後の出力フレーム数を計算
        let ratio = targetFormat.sampleRate / inputBuffer.format.sampleRate
        let outputFrameCount = AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio)
        guard outputFrameCount > 0 else { return }

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: outputFrameCount
        ) else { return }

        var error: NSError?
        var inputConsumed = false

        let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if inputConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            outStatus.pointee = .haveData
            inputConsumed = true
            return inputBuffer
        }

        guard status != .error, error == nil else { return }
        guard outputBuffer.frameLength > 0 else { return }

        // Int16 チャンネルデータからバイト列を抽出
        guard let int16Data = outputBuffer.int16ChannelData else { return }
        let byteCount = Int(outputBuffer.frameLength) * MemoryLayout<Int16>.size
        let data = Data(bytes: int16Data[0], count: byteCount)

        onAudioData?(data)
    }
}
