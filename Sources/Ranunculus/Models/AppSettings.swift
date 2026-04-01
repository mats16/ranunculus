import SwiftUI

/// アプリ設定の一元管理。@AppStorage で UserDefaults に永続化。
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @AppStorage("obsidianVaultPath") var obsidianVaultPath: String = AppSettings.defaultVaultPath
    @AppStorage("obsidianSubfolder") var obsidianSubfolder: String = "Ranunculus"
    @AppStorage("obsidianAutoSaveEnabled") var obsidianAutoSaveEnabled: Bool = true

    static let defaultVaultPath: String = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Obsidian Vault")
            .path
    }()

    /// Vault パス + サブフォルダを結合した保存先ディレクトリ URL。
    var saveDirectoryURL: URL {
        let expanded = NSString(string: obsidianVaultPath).expandingTildeInPath
        var url = URL(fileURLWithPath: expanded)
        if !obsidianSubfolder.isEmpty {
            url = url.appendingPathComponent(obsidianSubfolder)
        }
        return url
    }

    /// Vault パスが存在するか。
    var vaultPathExists: Bool {
        var isDir: ObjCBool = false
        let expanded = NSString(string: obsidianVaultPath).expandingTildeInPath
        return FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir) && isDir.boolValue
    }
}
