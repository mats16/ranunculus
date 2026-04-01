import Foundation
import SwiftUI

/// 文字起こしセグメントの一元管理ストア。
/// @MainActor で SwiftUI と直接バインドする。
@MainActor
final class TranscriptStore: ObservableObject {
    @Published var segments: [TranscriptSegment] = []
    @Published var partialText: String = ""

    var recordingStartTime: Date?

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    func addSegment(_ segment: TranscriptSegment) {
        segments.append(segment)
    }

    /// Whisper の結果でセグメントを更新する。
    func updateWithWhisperResult(id: UUID, text: String?) {
        guard let index = segments.firstIndex(where: { $0.id == id }) else { return }
        if let text, !text.isEmpty {
            segments[index].whisperText = text
        }
        segments[index].status = .done
    }

    /// セグメントのステータスを更新する。
    func updateStatus(id: UUID, status: SegmentStatus) {
        guard let index = segments.firstIndex(where: { $0.id == id }) else { return }
        segments[index].status = status
    }

    func clear() {
        segments.removeAll()
        partialText = ""
        recordingStartTime = nil
    }

    func exportAsText() -> String {
        segments.map { segment in
            let time = Self.timeFormatter.string(from: segment.startTime)
            return "[\(time)] \(segment.displayText)"
        }.joined(separator: "\n")
    }
}
