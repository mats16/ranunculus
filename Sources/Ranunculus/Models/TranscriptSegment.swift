import Foundation

/// 文字起こしセグメントの処理状態。
enum SegmentStatus: Equatable {
    /// Whisper 処理待ち
    case pending
    /// Whisper 処理中
    case processing
    /// 処理完了（Whisper 結果反映済み、またはスキップ）
    case done
}

/// VOSK の VAD で区切られた1発話区間を表すデータモデル。
struct TranscriptSegment: Identifiable, Equatable {
    let id: UUID
    let startTime: Date
    var endTime: Date?
    let voskText: String
    var whisperText: String?
    var wavFilePath: String?
    var status: SegmentStatus

    /// 表示用テキスト。Whisper 結果があればそちらを優先。
    var displayText: String {
        whisperText ?? voskText
    }

    /// セグメントの長さ（秒）。endTime が未設定なら nil。
    var duration: TimeInterval? {
        guard let end = endTime else { return nil }
        return end.timeIntervalSince(startTime)
    }

    init(
        id: UUID = UUID(),
        startTime: Date,
        endTime: Date? = nil,
        voskText: String,
        whisperText: String? = nil,
        wavFilePath: String? = nil,
        status: SegmentStatus = .pending
    ) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.voskText = voskText
        self.whisperText = whisperText
        self.wavFilePath = wavFilePath
        self.status = status
    }
}
