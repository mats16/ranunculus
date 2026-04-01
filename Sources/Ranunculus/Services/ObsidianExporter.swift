import Foundation
import Combine

/// 文字起こし結果を Obsidian Vault に Markdown としてリアルタイム保存するサービス。
/// セグメントの追加・Whisper 更新を Combine で監視し、自動的にファイルを上書き。
@MainActor
final class ObsidianExporter {
    private let store: TranscriptStore
    private let onError: (String) -> Void
    private var currentFilePath: URL?
    private var cancellable: AnyCancellable?

    private static let titleDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    private static let fileDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "yyyy-MM-dd_HHmmss"
        return f
    }()

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    init(store: TranscriptStore, onError: @escaping (String) -> Void) {
        self.store = store
        self.onError = onError
        startObserving()
    }

    private func startObserving() {
        cancellable = store.$segments
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [weak self] segments in
                guard !segments.isEmpty else { return }
                self?.save()
            }
    }

    private func save() {
        guard !store.segments.isEmpty else { return }

        let settings = AppSettings.shared
        guard settings.obsidianAutoSaveEnabled else { return }

        if currentFilePath == nil {
            let dir = settings.saveDirectoryURL
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            } catch {
                onError("Obsidian 保存先の作成に失敗: \(error.localizedDescription)")
                return
            }

            let date = store.recordingStartTime ?? store.segments.first?.startTime ?? Date()
            let fileName = "\(Self.fileDateFormatter.string(from: date))_議事録.md"
            currentFilePath = dir.appendingPathComponent(fileName)
        }

        guard let filePath = currentFilePath else { return }

        let date = store.recordingStartTime ?? store.segments.first?.startTime ?? Date()
        let markdown = generateMarkdown(date: date)
        do {
            try markdown.write(to: filePath, atomically: true, encoding: .utf8)
        } catch {
            onError("Obsidian Vault への保存に失敗: \(error.localizedDescription)")
        }
    }

    /// 監視を停止し、最終保存を行う。
    func stop() {
        cancellable = nil
        save()
    }

    /// ファイルパスをリセットし、監視を再開する。
    func reset() {
        currentFilePath = nil
        startObserving()
    }

    // MARK: - Private

    private func generateMarkdown(date: Date) -> String {
        let title = "議事録 \(Self.titleDateFormatter.string(from: date))"
        let isoDate = Self.iso8601Formatter.string(from: date)

        var lines: [String] = []

        lines.append("---")
        lines.append("title: \(title)")
        lines.append("date: \(isoDate)")
        lines.append("tags:")
        lines.append("  - ranunculus")
        lines.append("  - 議事録")
        lines.append("---")
        lines.append("")
        lines.append("# \(title)")
        lines.append("")
        lines.append("## Transcription")
        lines.append("")

        for segment in store.segments {
            lines.append(segment.displayText)
        }

        lines.append("")
        return lines.joined(separator: "\n")
    }
}
