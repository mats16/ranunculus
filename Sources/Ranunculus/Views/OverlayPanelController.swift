import AppKit
import SwiftUI

/// 常に最前面に表示されるフローティング字幕パネルを管理する。
@MainActor
final class OverlayPanelController {
    static let shared = OverlayPanelController()

    private var panel: NSPanel?
    private var hostingView: NSHostingView<CaptionOverlayView>?

    func show(viewModel: CaptionViewModel) {
        if panel != nil { return }

        let overlayView = CaptionOverlayView(viewModel: viewModel)
        let hosting = NSHostingView(rootView: overlayView)
        hosting.frame = NSRect(x: 0, y: 0, width: 720, height: 120)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 120),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false

        // 全 Space で表示、フルスクリーンアプリの上にも表示
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        panel.contentView = hosting

        // 画面下部中央に配置
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.midX - 360
            let y = screenFrame.minY + 60
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        panel.orderFront(nil)
        self.panel = panel
        self.hostingView = hosting
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
        hostingView = nil
    }

    var isVisible: Bool {
        panel != nil
    }
}
