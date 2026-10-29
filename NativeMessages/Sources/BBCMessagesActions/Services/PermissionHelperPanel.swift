import AppKit
import SwiftUI

@MainActor final class PermissionHelperPanel: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    func show(model: AppModel) {
        if let panel { panel.makeKeyAndOrderFront(nil); return }
        let content = NSHostingView(rootView: PermissionHelperView(model: model))
        let panel = NSPanel(contentRect: .init(origin: .zero, size: content.fittingSize), styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.delegate = self
        panel.title = "BBC permissions"
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = content
        panel.setContentSize(content.fittingSize)
        if let frame = (NSApp.mainWindow?.screen ?? NSScreen.main)?.visibleFrame {
            panel.setFrameOrigin(.init(x: max(frame.minX + 12, frame.maxX - panel.frame.width - 24), y: frame.minY + 48))
        }
        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
    }
    func close() { panel?.close() }
    func windowWillClose(_ notification: Notification) { panel?.contentView = nil; panel = nil }
}
