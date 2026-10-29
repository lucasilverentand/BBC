import Foundation
import Observation
import BBCClient
import Darwin
import AppKit
@preconcurrency import ApplicationServices
import CoreServices

@MainActor @Observable final class AppModel {
    private(set) var keys: [APIKeyRecord] = []
    private(set) var running = false
    private(set) var starting = false
    private(set) var startAtLogin = LoginItem.enabled
    private(set) var loginNeedsApproval = LoginItem.needsApproval
    private(set) var updatingLogin = false
    private var opened = false
    var error: String?
    private(set) var permissions = PermissionStatus()
    @ObservationIgnored private let permissionHelper = PermissionHelperPanel()
    private let store: APIKeyStore?
    private var server: LocalAPIServer?
    private var router: APIRouter?
    private var lock: Int32 = -1
    private var listenerID = UUID()
    init() {
        do { let value = try APIKeyStore(); store = value; keys = value.keys }
        catch { store = nil; self.error = "Could not open the local API key store. Check its ownership and permissions." }
    }
    func appOpened() {
        guard !opened else { return }; opened = true
        if UserDefaults.standard.bool(forKey: "startAPIOnLaunch") {
            let port = UserDefaults.standard.object(forKey: "apiPort") as? Int ?? 7861
            start(port: port, allowNetwork: UserDefaults.standard.bool(forKey: "allowNetwork"))
        }
    }
    func refreshLoginItem() {
        startAtLogin = LoginItem.enabled; loginNeedsApproval = LoginItem.needsApproval
    }
    func setStartAtLogin(_ value: Bool) async {
        guard !updatingLogin else { return }; updatingLogin = true
        defer { updatingLogin = false; refreshLoginItem() }
        do { try await LoginItem.setEnabled(value) }
        catch { self.error = "Could not update Start at login. Check Blue Bubble Club in System Settings → General → Login Items." }
    }
    func refreshPermissions() { permissions = PermissionStatus.current() }
    func showPermissionHelper() { refreshPermissions(); permissionHelper.show(model: self) }
    func closePermissionHelper() { permissionHelper.close() }
    func setUpPermission(_ step: PermissionStep) {
        showPermissionHelper()
        switch step {
        case .fullDiskAccess: NSWorkspace.shared.open(step.settingsURL)
        case .accessibility:
            requestAccessibility()
            NSWorkspace.shared.open(step.settingsURL)
        case .automation:
            Task {
                await requestAutomation(); refreshPermissions()
                if !permissions.automation { NSWorkspace.shared.open(step.settingsURL) }
            }
        }
    }
    func requestAutomation() async {
        do {
            let pid = try await NativeMessagesStartup.ensureRunning()
            let target = NSAppleEventDescriptor(processIdentifier: pid)
            guard let descriptor = target.aeDesc else { throw ActionFailure.unavailable }
            let status = AEDeterminePermissionToAutomateTarget(descriptor, typeWildCard, typeWildCard, true)
            if status != noErr { error = "Messages Automation permission was not granted." }
        } catch { self.error = "Open Messages in this macOS account before allowing Automation." }
    }
    func requestAccessibility() {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }
    func createKey(name: String) -> String? {
        do { guard let store else { throw ActionFailure.unavailable }; let secret = try store.create(name: name); keys = store.keys; return secret }
        catch { self.error = "Could not create an API key."; return nil }
    }
    func revoke(_ id: UUID) {
        do { guard let store else { throw ActionFailure.unavailable }; try store.revoke(id); keys = store.keys; router?.stop() }
        catch { self.error = "Could not revoke the API key." }
    }
    func start(port: Int, allowNetwork: Bool) {
        guard server == nil else { return }
        do {
            guard let store, !store.keys.isEmpty, let port = UInt16(exactly: port), port > 0 else { error = "Create an API key and choose a port from 1 to 65535."; return }
            let fd = open(store.directory.appendingPathComponent("listener.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { throw ActionFailure.unavailable }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); throw ActionFailure.busy }
            lock = fd
            guard let executable = Bundle.main.executableURL else { throw ActionFailure.unavailable }
            let client = BBCClient(executable: executable, nativeExecutable: executable)
            let router = APIRouter(keys: store) { try await client.request($0) }
            self.router = router
            let listener = try LocalAPIServer(host: allowNetwork ? "0.0.0.0" : "127.0.0.1", port: port, router: router)
            server = listener; starting = true; error = nil
            let generation = UUID(); listenerID = generation
            listener.start { [weak self] ready in Task { @MainActor in
                guard let self, self.listenerID == generation else { return }; self.starting = false; self.running = ready
                if !ready, self.server != nil { self.error = "The API listener stopped. Check the port and try again."; self.stop() }
            } }
        } catch { stop(); self.error = "Could not start the local API. Check the port and whether another BBC instance is running." }
    }
    func stop() {
        listenerID = UUID()
        let oldServer = server; server = nil; oldServer?.stop(); router?.stop(); router = nil
        if lock >= 0 { flock(lock, LOCK_UN); close(lock); lock = -1 }
        running = false; starting = false
    }
}
