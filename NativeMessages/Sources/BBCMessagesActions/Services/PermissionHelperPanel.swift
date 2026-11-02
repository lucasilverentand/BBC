import AppKit
import SwiftUI

@MainActor final class PermissionHelperPanel: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private var positioningTask: Task<Void, Never>?
    func show(model: AppModel) {
        if panel != nil { positionBesideSettings(); return }
        let content = NSHostingView(rootView: PermissionHelperView(model: model))
        let panel = NSPanel(contentRect: .init(origin: .zero, size: content.fittingSize), styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.delegate = self
        panel.title = "Full Disk Access"
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = content
        panel.setContentSize(content.fittingSize)
        self.panel = panel
        positionBesideSettings()
        // Settings can take a moment to open its pane. Keep tracking its bounds
        // without Accessibility access or capturing any window contents.
        positioningTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                self?.positionBesideSettings()
            }
        }
    }

    private func positionBesideSettings() {
        guard let panel else { return }
        guard let settings = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences").first,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let window = windows.first(where: {
                  ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == settings.processIdentifier &&
                  ($0[kCGWindowLayer as String] as? NSNumber)?.intValue == 0 &&
                  ($0[kCGWindowBounds as String] as? [String: Any]) != nil
              }),
              let bounds = window[kCGWindowBounds as String] as? [String: Any],
              let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
              let primaryScreen = NSScreen.screens.first else {
            panel.orderOut(nil)
            return
        }
        // Window-server coordinates start at the primary display's top left;
        // AppKit coordinates start at its bottom left, also across displays.
        let settingsFrame = NSRect(x: rect.minX, y: primaryScreen.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
        guard let screen = NSScreen.screens.max(by: {
            intersectionArea($0.frame, settingsFrame) < intersectionArea($1.frame, settingsFrame)
        }) else { return }
        let visible = screen.visibleFrame.insetBy(dx: 12, dy: 12)
        let size = panel.frame.size
        let gap: CGFloat = 12
        let candidates = [
            NSPoint(x: settingsFrame.maxX + gap, y: settingsFrame.maxY - size.height),
            NSPoint(x: settingsFrame.minX - gap - size.width, y: settingsFrame.maxY - size.height),
            NSPoint(x: settingsFrame.minX, y: settingsFrame.minY - gap - size.height),
            NSPoint(x: settingsFrame.minX, y: settingsFrame.maxY + gap)
        ]
        let origin = candidates.first { visible.contains(NSRect(origin: $0, size: size)) } ?? NSPoint(
            x: min(max(settingsFrame.maxX + gap, visible.minX), max(visible.minX, visible.maxX - size.width)),
            y: min(max(settingsFrame.maxY - size.height, visible.minY), max(visible.minY, visible.maxY - size.height))
        )
        if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    private func intersectionArea(_ first: NSRect, _ second: NSRect) -> CGFloat {
        let overlap = first.intersection(second)
        return overlap.isNull ? 0 : overlap.width * overlap.height
    }

    func close() { panel?.close() }
    func windowWillClose(_ notification: Notification) {
        positioningTask?.cancel(); positioningTask = nil
        panel?.contentView = nil; panel = nil
    }
}
