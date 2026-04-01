import Foundation

/// 16kHz モノラル Int16 PCM の WAV ファイルをストリーミング書き込みする。
/// VOSK の VAD で区切られた発話区間ごとに1ファイルを生成する。
final class WAVSegmentWriter {
    static let sampleRate: UInt32 = 16000
    static let channels: UInt16 = 1
    static let bitsPerSample: UInt16 = 16

    private let filePath: String
    private let fileHandle: FileHandle
    private var dataSize: UInt32 = 0
    private var silencePassed = false
    private var sampleCount: UInt32 = 0

    /// 先頭無音スキップの閾値（Int16 スケール、≈ 0.01 in float）
    private static let silenceThreshold: Int16 = 327

    /// セグメントの開始時刻
    let startTime: Date

    /// 一時ディレクトリ内にセグメントファイルを作成する。
    static func create() throws -> WAVSegmentWriter {
        let dir = NSTemporaryDirectory() + "ranunculus/"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let path = dir + "segment_\(UUID().uuidString).wav"

        FileManager.default.createFile(atPath: path, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: path) else {
            throw WAVWriterError.cannotCreateFile(path)
        }

        return WAVSegmentWriter(filePath: path, fileHandle: handle, startTime: Date())
    }

    private init(filePath: String, fileHandle: FileHandle, startTime: Date) {
        self.filePath = filePath
        self.fileHandle = fileHandle
        self.startTime = startTime

        // WAV ヘッダーのプレースホルダー（44バイト）を書き込む
        let header = Data(count: 44)
        fileHandle.write(header)
    }

    /// Int16 PCM データを書き込む。先頭の無音区間はスキップする。
    func write(_ data: Data) {
        data.withUnsafeBytes { raw in
            guard let baseAddress = raw.baseAddress else { return }
            let samples = baseAddress.assumingMemoryBound(to: Int16.self)
            let count = data.count / MemoryLayout<Int16>.size
            guard count > 0 else { return }

            var writeStartIndex = 0

            if !silencePassed {
                for i in 0..<count {
                    if abs(samples[i]) > Self.silenceThreshold {
                        silencePassed = true
                        writeStartIndex = i
                        break
                    }
                }
                if !silencePassed { return }
            }

            let samplesToWrite = count - writeStartIndex
            let bytesToWrite = samplesToWrite * MemoryLayout<Int16>.size
            let byteOffset = writeStartIndex * MemoryLayout<Int16>.size
            let chunk = data[data.startIndex + byteOffset ..< data.startIndex + byteOffset + bytesToWrite]
            fileHandle.write(chunk)
            dataSize += UInt32(bytesToWrite)
            sampleCount += UInt32(samplesToWrite)
        }
    }

    /// WAV ファイルを完成させ、ヘッダーを書き込んでクローズする。
    /// - Returns: ファイルパスと録音時間（秒）
    func finalize() -> (path: String, duration: TimeInterval) {
        // WAV ヘッダーを書き込む
        fileHandle.seek(toFileOffset: 0)
        fileHandle.write(buildWAVHeader())
        fileHandle.closeFile()

        let duration = Double(sampleCount) / Double(Self.sampleRate)
        return (path: filePath, duration: duration)
    }

    // MARK: - Private

    private func buildWAVHeader() -> Data {
        var header = Data(capacity: 44)

        let byteRate = Self.sampleRate * UInt32(Self.channels) * UInt32(Self.bitsPerSample / 8)
        let blockAlign = Self.channels * (Self.bitsPerSample / 8)

        // RIFF header
        header.append(contentsOf: "RIFF".utf8)
        var chunkSize = dataSize + 36
        header.append(Data(bytes: &chunkSize, count: 4))
        header.append(contentsOf: "WAVE".utf8)

        // fmt sub-chunk
        header.append(contentsOf: "fmt ".utf8)
        var subchunk1Size: UInt32 = 16
        header.append(Data(bytes: &subchunk1Size, count: 4))
        var audioFormat: UInt16 = 1 // PCM
        header.append(Data(bytes: &audioFormat, count: 2))
        var channels = Self.channels
        header.append(Data(bytes: &channels, count: 2))
        var sampleRate = Self.sampleRate
        header.append(Data(bytes: &sampleRate, count: 4))
        var br = byteRate
        header.append(Data(bytes: &br, count: 4))
        var ba = blockAlign
        header.append(Data(bytes: &ba, count: 2))
        var bps = Self.bitsPerSample
        header.append(Data(bytes: &bps, count: 2))

        // data sub-chunk
        header.append(contentsOf: "data".utf8)
        var ds = dataSize
        header.append(Data(bytes: &ds, count: 4))

        return header
    }
}

enum WAVWriterError: Error, LocalizedError {
    case cannotCreateFile(String)

    var errorDescription: String? {
        switch self {
        case .cannotCreateFile(let path):
            return "WAV ファイルを作成できません: \(path)"
        }
    }
}
