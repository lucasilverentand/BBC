import SwiftUI
import AppKit

struct PermissionHelperView: View {
    @Bindable var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Messages setup").font(.headline)
                Spacer()
                Text("\(model.permissions.grantedCount) of 3").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                AppFileDragView(url: Bundle.main.bundleURL).frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Drag this app into Settings").fontWeight(.medium)
                    Text("Drop it into Full Disk Access or Accessibility, then enable it.").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(12).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
            PermissionChecklistView(model: model, compact: true)
            if model.permissions.allGranted {
                Label("Permissions are ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Text(model.permissions.messagesRunning ? "Changes are checked automatically. If macOS asks you to quit, reopen BBC after enabling access." : "Open Messages and sign in on this Mac. Permissions are checked automatically while this helper is open.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Recheck") { model.refreshPermissions() }
                Spacer()
                Button("Done") { model.closePermissionHelper() }.keyboardShortcut(.defaultAction)
            }
        }.padding(18).frame(width: 330).fixedSize(horizontal: false, vertical: true)
        .task {
            while !Task.isCancelled {
                model.refreshPermissions()
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }
}

/// Native file-URL dragging works with System Settings' app permission lists.
struct AppFileDragView: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> AppDragImage {
        let view = AppDragImage(); view.appURL = url
        view.image = AppBrand.icon
        view.imageScaling = .scaleProportionallyUpOrDown
        view.toolTip = "Drag Blue Bubble Club into the System Settings permission list"
        view.setAccessibilityLabel("Drag Blue Bubble Club app into System Settings")
        return view
    }
    func updateNSView(_ view: AppDragImage, context: Context) { view.appURL = url }
}
final class AppDragImage: NSImageView, NSDraggingSource {
    var appURL = Bundle.main.bundleURL
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        guard let image else { return }
        let item = NSDraggingItem(pasteboardWriter: appURL as NSURL)
        item.setDraggingFrame(bounds, contents: image)
        beginDraggingSession(with: [item], event: event, source: self)
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
}
