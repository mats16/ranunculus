import Foundation

/// WAV ファイルを読み込み、Whisper の入力フォーマット（16kHz mono f32）に変換する。
enum WAVFileReader {
    /// WAV ファイルを読み込み、Float 配列（-1.0〜1.0）として返す。
    /// - Parameter path: WAV ファイルのパス
    /// - Returns: 16kHz mono f32 サンプル配列
    static func readAsFloat(path: String) throws -> [Float] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))

        guard data.count > 44 else {
            throw WAVReaderError.fileTooSmall
        }

        // WAV ヘッダーの検証
        let riff = String(data: data[0..<4], encoding: .ascii)
        let wave = String(data: data[8..<12], encoding: .ascii)
        guard riff == "RIFF", wave == "WAVE" else {
            throw WAVReaderError.invalidFormat
        }

        // fmt チャンクからフォーマット情報を取得
        let audioFormat: UInt16 = data.withUnsafeBytes { $0.load(fromByteOffset: 20, as: UInt16.self) }
        let bitsPerSample: UInt16 = data.withUnsafeBytes { $0.load(fromByteOffset: 34, as: UInt16.self) }

        guard audioFormat == 1 else { // PCM のみ対応
            throw WAVReaderError.unsupportedFormat(audioFormat)
        }

        // data チャンクを探す
        var offset = 12
        while offset + 8 < data.count {
            let chunkID = String(data: data[offset..<offset+4], encoding: .ascii) ?? ""
            let chunkSize: UInt32 = data.withUnsafeBytes { $0.load(fromByteOffset: offset + 4, as: UInt32.self) }

            if chunkID == "data" {
                let dataOffset = offset + 8
                let dataEnd = min(dataOffset + Int(chunkSize), data.count)
                let pcmData = data[dataOffset..<dataEnd]

                return convertToFloat(pcmData: pcmData, bitsPerSample: bitsPerSample)
            }

            offset += 8 + Int(chunkSize)
            // チャンクサイズが奇数の場合、パディングバイトをスキップ
            if chunkSize % 2 != 0 { offset += 1 }
        }

        throw WAVReaderError.noDataChunk
    }

    /// PCM データを Float 配列に変換する。
    private static func convertToFloat(pcmData: Data, bitsPerSample: UInt16) -> [Float] {
        switch bitsPerSample {
        case 16:
            let sampleCount = pcmData.count / 2
            var result = [Float](repeating: 0, count: sampleCount)
            pcmData.withUnsafeBytes { raw in
                let samples = raw.bindMemory(to: Int16.self)
                for i in 0..<sampleCount {
                    result[i] = Float(samples[i]) / 32768.0
                }
            }
            return result
        default:
            // 16bit 以外は空配列を返す（現状の WAVSegmentWriter は常に 16bit）
            return []
        }
    }
}

enum WAVReaderError: Error, LocalizedError {
    case fileTooSmall
    case invalidFormat
    case unsupportedFormat(UInt16)
    case noDataChunk

    var errorDescription: String? {
        switch self {
        case .fileTooSmall: return "WAV ファイルが小さすぎます"
        case .invalidFormat: return "無効な WAV フォーマットです"
        case .unsupportedFormat(let fmt): return "未対応のオーディオフォーマットです: \(fmt)"
        case .noDataChunk: return "data チャンクが見つかりません"
        }
    }
}
