import SwiftUI

/// 設定画面（Cmd+, で表示）。
struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section("Obsidian 連携") {
                Toggle("録音停止時に自動保存", isOn: $settings.obsidianAutoSaveEnabled)

                HStack {
                    TextField("Vault パス", text: $settings.obsidianVaultPath)
                        .textFieldStyle(.roundedBorder)
                    Button("選択…") {
                        chooseDirectory()
                    }
                }

                TextField("サブフォルダ", text: $settings.obsidianSubfolder)
                    .textFieldStyle(.roundedBorder)

                if !settings.vaultPathExists {
                    Label("指定された Vault ディレクトリが見つかりません", systemImage: "exclamationmark.triangle")
                        .foregroundColor(.orange)
                        .font(.caption)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .padding()
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Obsidian Vault のディレクトリを選択してください"

        if panel.runModal() == .OK, let url = panel.url {
            settings.obsidianVaultPath = url.path
        }
    }
}
