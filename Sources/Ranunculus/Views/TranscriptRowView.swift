import SwiftUI

/// 議事録の1セグメントを表示する行ビュー。
struct TranscriptRowView: View {
    let segment: TranscriptSegment

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // タイムスタンプ
            Text(Self.timeFormatter.string(from: segment.startTime))
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 60, alignment: .leading)

            // ステータスインジケータ
            Group {
                switch segment.status {
                case .pending:
                    Image(systemName: "clock")
                        .foregroundColor(.orange)
                case .processing:
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 12, height: 12)
                case .done:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                }
            }
            .font(.caption2)
            .frame(width: 16)

            // テキスト
            Text(segment.displayText)
                .font(.body)
                .foregroundColor(segment.status == .done ? .primary : .secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
    }
}
