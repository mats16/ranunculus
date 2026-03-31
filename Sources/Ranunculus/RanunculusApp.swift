import SwiftUI
import AppKit

@main
struct RanunculusApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var viewModel = CaptionViewModel()

    var body: some Scene {
        WindowGroup("Ranunculus") {
            ControlPanelView(viewModel: viewModel)
                .onAppear {
                    viewModel.loadBundledModel()
                }
        }
        .windowResizability(.contentMinSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // アプリがバックグラウンドに行ってもオーバーレイを表示し続けるため
        // アクティベーションポリシーを regular に設定
        NSApplication.shared.setActivationPolicy(.regular)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
