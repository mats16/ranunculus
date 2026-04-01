import SwiftUI
import UniformTypeIdentifiers

/// メインコントロールウィンドウ（議事録ビュー）。
struct ControlPanelView: View {
    @ObservedObject var viewModel: CaptionViewModel

    var body: some View {
        VStack(spacing: 12) {
            // ステータスバー
            HStack {
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)
                Text(viewModel.statusMessage)
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Spacer()

                // モデル状態
                HStack(spacing: 4) {
                    Text("VOSK")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(viewModel.voskModelLoaded ? Color.green.opacity(0.2) : Color.gray.opacity(0.2))
                        .cornerRadius(4)

                    Text("Whisper")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(viewModel.whisperModelLoaded ? Color.green.opacity(0.2) : Color.gray.opacity(0.2))
                        .cornerRadius(4)
                }
            }

            // モデル読込プログレス
            if viewModel.isLoadingModel {
                ProgressView("モデル読込中...")
                    .progressViewStyle(.linear)
            }

            Divider()

            // コントロールボタン
            HStack(spacing: 16) {
                // 録音開始/停止
                Button(action: { viewModel.toggleListening() }) {
                    HStack(spacing: 8) {
                        Image(systemName: viewModel.isListening ? "stop.circle.fill" : "record.circle")
                            .font(.title2)
                            .foregroundColor(viewModel.isListening ? .red : .accentColor)
                        Text(viewModel.isListening ? "停止" : "録音開始")
                    }
                    .frame(minWidth: 120)
                }
                .controlSize(.large)
                .disabled(!viewModel.voskModelLoaded)
                .keyboardShortcut(.space, modifiers: [])

                Spacer()

                // エクスポート
                Button(action: { viewModel.exportTranscript() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "square.and.arrow.up")
                        Text("書き出し")
                    }
                }
                .disabled(viewModel.store.segments.isEmpty)

                // クリア
                Button(action: { viewModel.clearText() }) {
                    Image(systemName: "trash")
                }
                .help("文字起こしをクリア")
                .disabled(viewModel.store.segments.isEmpty && viewModel.store.partialText.isEmpty)
            }

            Divider()

            // 議事録表示エリア
            GroupBox {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(viewModel.store.segments) { segment in
                                TranscriptRowView(segment: segment)
                            }

                            // 部分認識テキスト
                            if !viewModel.store.partialText.isEmpty {
                                HStack(alignment: .top, spacing: 8) {
                                    Text("")
                                        .frame(width: 60)
                                    Image(systemName: "waveform")
                                        .font(.caption2)
                                        .foregroundColor(.blue)
                                        .frame(width: 16)
                                    Text(viewModel.store.partialText)
                                        .font(.body)
                                        .foregroundColor(.secondary)
                                        .italic()
                                }
                                .padding(.vertical, 2)
                            }

                            Color.clear.frame(height: 1).id("bottom")
                        }
                        .padding(8)
                    }
                    .onChange(of: viewModel.store.segments.count) { _ in
                        withAnimation {
                            proxy.scrollTo("bottom")
                        }
                    }
                    .onChange(of: viewModel.store.partialText) { _ in
                        withAnimation {
                            proxy.scrollTo("bottom")
                        }
                    }
                }
            } label: {
                HStack {
                    Text("文字起こし")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("\(viewModel.store.segments.count) セグメント")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .frame(minHeight: 280)

            // エラー表示
            if let error = viewModel.errorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                    Spacer()
                }
            }
        }
        .padding()
        .frame(minWidth: 700, minHeight: 500)
    }

    private var statusColor: Color {
        if viewModel.isListening {
            return .red
        } else if viewModel.voskModelLoaded {
            return .blue
        } else {
            return .gray
        }
    }
}
