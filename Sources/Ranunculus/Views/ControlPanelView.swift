import SwiftUI

/// メインコントロールウィンドウ。
struct ControlPanelView: View {
    @ObservedObject var viewModel: CaptionViewModel
    @State private var showOverlay = false

    var body: some View {
        VStack(spacing: 16) {
            // ステータス表示
            HStack {
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)
                Text(viewModel.statusMessage)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Spacer()
            }

            // モデル読込プログレス
            if viewModel.isLoadingModel {
                ProgressView("モデル読込中...")
                    .progressViewStyle(.linear)
            }

            Divider()

            // コントロールボタン
            HStack(spacing: 16) {
                // 認識開始/停止
                Button(action: { viewModel.toggleListening() }) {
                    HStack(spacing: 8) {
                        Image(systemName: viewModel.isListening ? "stop.circle.fill" : "mic.circle.fill")
                            .font(.title2)
                        Text(viewModel.isListening ? "停止" : "開始")
                    }
                    .frame(minWidth: 100)
                }
                .controlSize(.large)
                .disabled(!viewModel.modelLoaded)
                .keyboardShortcut(.space, modifiers: [])

                // オーバーレイ表示
                Toggle(isOn: $showOverlay) {
                    HStack(spacing: 4) {
                        Image(systemName: "rectangle.on.rectangle")
                        Text("字幕オーバーレイ")
                    }
                }
                .toggleStyle(.switch)

                Spacer()

                // テキストクリア
                Button(action: { viewModel.clearText() }) {
                    Image(systemName: "trash")
                }
                .help("認識テキストをクリア")
            }

            Divider()

            // 字幕プレビュー
            GroupBox {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            if !viewModel.captionText.isEmpty {
                                Text(viewModel.captionText)
                                    .font(.body)
                                    .textSelection(.enabled)
                            }
                            if !viewModel.partialText.isEmpty {
                                Text(viewModel.partialText)
                                    .font(.body)
                                    .foregroundColor(.secondary)
                            }
                            Color.clear.frame(height: 1).id("bottom")
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                    }
                    .onChange(of: viewModel.captionText) { _ in
                        withAnimation {
                            proxy.scrollTo("bottom")
                        }
                    }
                    .onChange(of: viewModel.partialText) { _ in
                        withAnimation {
                            proxy.scrollTo("bottom")
                        }
                    }
                }
            } label: {
                Text("認識テキスト")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(minHeight: 160)

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
        .frame(minWidth: 520, minHeight: 360)
        .onChange(of: showOverlay) { newValue in
            if newValue {
                OverlayPanelController.shared.show(viewModel: viewModel)
            } else {
                OverlayPanelController.shared.hide()
            }
        }
    }

    private var statusColor: Color {
        if viewModel.isListening {
            return .green
        } else if viewModel.modelLoaded {
            return .blue
        } else {
            return .gray
        }
    }
}
