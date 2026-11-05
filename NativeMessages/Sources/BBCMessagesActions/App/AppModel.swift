import Foundation
import Observation
import BBCClient
import Darwin
import AppKit
@preconcurrency import ApplicationServices
import CoreServices

@MainActor @Observable final class AppModel {
    let log = AppLog()
    var selectedPage: AppPage? = .server
    private(set) var keys: [APIKeyRecord] = []
    private(set) var running = false
    private(set) var starting = false
    private(set) var startAtLogin = LoginItem.enabled
    private(set) var loginNeedsApproval = LoginItem.needsApproval
    private(set) var updatingLogin = false
    private var opened = false
    var mode: OperatingMode { keys.contains { $0.access == .full } ? .full : .readOnly }
    var permissionSteps: [PermissionStep] { mode == .readOnly ? [.fullDiskAccess] : PermissionStep.allCases }
    var grantedPermissionCount: Int { permissionSteps.filter { permissions.granted($0) }.count }
    var error: String? {
        didSet { if let error, error != oldValue { log.record(error, level: .error) } }
    }
    private(set) var permissions = PermissionStatus()
    @ObservationIgnored private let permissionHelper = PermissionHelperPanel()
    private let store: APIKeyStore?
    private var server: LocalAPIServer?
    private var router: APIRouter?
    @ObservationIgnored private var webhookService: WebhookService?
    @ObservationIgnored private var scheduleService: LocalScheduleService?
    private var lock: Int32 = -1
    private var listenerID = UUID()
    @ObservationIgnored private let nativeHost = BridgeHost()
    private(set) var nativeStarting = false
    private(set) var nativeConnected = false
    private(set) var nativeRequirements = "Checking native bridge requirements…"
    init() {
        do {
            let legacy = UserDefaults.standard.string(forKey: "operatingMode")
            let legacyMode = legacy.map { OperatingMode(rawValue: $0) ?? .readOnly }
            let value = try APIKeyStore(legacyMode: legacyMode, legacyNetworkAccess: UserDefaults.standard.bool(forKey: "allowNetwork"))
            store = value; keys = value.keys
            UserDefaults.standard.removeObject(forKey: "operatingMode")
        }
        catch { store = nil; self.error = "Could not open the local API key store. Check its ownership and permissions." }
    }
    func appOpened() {
        guard !opened else { return }; opened = true
        log.record("App launched.")
        if let error { log.record(error, level: .error) }
        if UserDefaults.standard.bool(forKey: "startAPIOnLaunch") {
            let port = UserDefaults.standard.object(forKey: "apiPort") as? Int ?? 7861
            start(port: port)
        }
        switch NativeMessagesStartup.launchPlan(openHidden: NativeMessagesStartup.hiddenLaunchEnabled,
                                                connectBridge: UserDefaults.standard.bool(forKey:"startNativeBridgeOnLaunch"),
                                                fullAccess: mode == .full) {
        case .connectBridge: startNativeBridge(openHiddenOnFailure: NativeMessagesStartup.hiddenLaunchEnabled)
        case .openHidden: openMessagesHidden()
        case .none: break
        }
    }
    /// Open (or reuse) this user's Messages process and hide it. Launching is
    /// not a capability fallback: native actions still require the bridge.
    func openMessagesHidden() {
        Task {
            do {
                let pid = try await NativeMessagesStartup.ensureRunning()
                await NativeMessagesStartup.hide(pid: pid)
                log.record("Messages opened hidden.")
            } catch { self.error = "Could not open Messages. Sign into Messages in this macOS account." }
        }
    }
    func refreshLoginItem() {
        startAtLogin = LoginItem.enabled; loginNeedsApproval = LoginItem.needsApproval
    }
    func setStartAtLogin(_ value: Bool) async {
        guard !updatingLogin else { return }; updatingLogin = true
        defer { updatingLogin = false; refreshLoginItem() }
        do { try await LoginItem.setEnabled(value); log.record(value ? "Start at login enabled." : "Start at login disabled.") }
        catch { self.error = "Could not update Start at login. Check Blue Bubble Club in System Settings → General → Login Items." }
    }
    func refreshPermissions() { permissions = PermissionStatus.current() }
    func refreshNativeBridge() {
        guard mode == .full else { nativeConnected = false; nativeRequirements = "Read-only mode does not start native messaging."; return }
        Task {
            let readiness = await Task.detached { BridgeReadiness.current() }.value
            let status = await Task.detached { NativeBridgeClient.status() }.value
            guard mode == .full else { return }
            let connected = status.object?["ready"]?.bool == true
            if connected != nativeConnected { log.record(connected ? "Native messaging connected." : "Native messaging disconnected.") }
            nativeConnected = connected
            if nativeConnected { nativeRequirements = "Native messaging connected. No mouse or keyboard automation." }
            else if readiness.sip == .enabled { nativeRequirements = "Native messaging requires a host configured for private APIs. SIP is enabled. BBC does not change security settings." }
            else if !readiness.allowed { nativeRequirements = "Native messaging host setup is incomplete. Check SIP and library validation in the setup guide." }
            else { nativeRequirements = "Host requirements pass. Start the native bridge to connect Messages." }
        }
    }
    func startNativeBridge(openHiddenOnFailure: Bool = false) {
        guard mode == .full, !nativeStarting else { return }; nativeStarting = true
        log.record("Connecting native messaging.")
        Task {
            defer { nativeStarting = false; refreshNativeBridge() }
            do { try await nativeHost.start() }
            catch {
                self.error = "Could not start the native bridge. Check host setup and whether Messages can quit. No UI fallback was used."
                // Keep Messages available for observation and ordinary sends;
                // the bridge itself is not retried.
                if openHiddenOnFailure { openMessagesHidden() }
            }
        }
    }
    func stopNativeBridge() { log.record("Disconnecting native messaging."); nativeHost.stop(); nativeConnected = false; refreshNativeBridge() }
    func showPermissionHelper() { refreshPermissions(); permissionHelper.show(model: self) }
    func closePermissionHelper() { permissionHelper.close() }
    func setUpPermission(_ step: PermissionStep) {
        guard permissionSteps.contains(step) else { return }
        log.record("Opening \(step.title) settings.")
        NSWorkspace.shared.open(step.settingsURL)
        switch step {
        case .fullDiskAccess: showPermissionHelper()
        case .automation:
            closePermissionHelper()
            Task {
                await requestAutomation(); refreshPermissions()
                if !permissions.automation { NSWorkspace.shared.open(step.settingsURL) }
            }
        }
    }
    func requestAutomation() async {
        guard mode == .full else { return }
        do {
            let pid = try await NativeMessagesStartup.ensureRunning()
            let target = NSAppleEventDescriptor(processIdentifier: pid)
            guard let descriptor = target.aeDesc else { throw ActionFailure.unavailable }
            let status = AEDeterminePermissionToAutomateTarget(descriptor, typeWildCard, typeWildCard, true)
            if status != noErr { error = "Messages Automation permission was not granted." }
        } catch { self.error = "Open Messages in this macOS account before allowing Automation." }
    }
    func createKey(name: String, access: APIKeyAccess = .readOnly, allowedClients: String = "", allowNetwork: Bool = false) -> String? {
        do { guard let store else { throw ActionFailure.unavailable }; let secret = try store.create(name: name,access:access,allowedClients:allowedClients,allowNetwork:allowNetwork); keys = store.keys; log.record("API key created."); return secret }
        catch { self.error = "Could not create an API key."; return nil }
    }
    func rotateKey(_ id: UUID) -> String? {
        do {
            guard let store else { throw ActionFailure.unavailable }
            let secret = try store.rotate(id)
            keys = store.keys
            log.record("API key rotated.")
            return secret
        } catch { self.error = "Could not rotate the API key."; return nil }
    }
    func revoke(_ id: UUID) {
        do { guard let store else { throw ActionFailure.unavailable }; try store.revoke(id); keys = store.keys; router?.keysChanged(); log.record("API key revoked.") }
        catch { self.error = "Could not revoke the API key." }
    }
    func updateKey(_ id: UUID, name: String, access: APIKeyAccess, allowedClients: String, allowNetwork: Bool) -> Bool {
        do {
            guard let store else { throw ActionFailure.unavailable }
            try store.update(id,access:access,allowedClients:allowedClients,allowNetwork:allowNetwork,name:name); keys = store.keys; router?.keysChanged(); log.record("API key settings updated."); return true
        } catch { self.error = "Could not update the API key."; return false }
    }
    func start(port: Int) {
        guard server == nil else { return }
        do {
            guard let store else { error = "Could not open the API key store."; return }
            guard let port = UInt16(exactly: port), port > 0 else { error = "Choose a port from 1 to 65535."; return }
            let fd = open(store.directory.appendingPathComponent("listener.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { throw ActionFailure.unavailable }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); throw ActionFailure.busy }
            lock = fd
            guard let executable = Bundle.main.executableURL else { throw ActionFailure.unavailable }
            let client = BBCClient(executable: executable, nativeExecutable: executable)
            // Reuse the stores across API restarts: an already dispatched send
            // or webhook can finish after stop and must retain the same owner.
            let webhooks: WebhookService
            if let cached = webhookService { webhooks = cached }
            else { webhooks = try WebhookService(keys:store); webhookService = webhooks }
            var schedules: LocalScheduleService?
            if let cached = scheduleService { schedules = cached }
            else {
                schedules = try LocalScheduleService(directory:store.directory.appendingPathComponent("schedules",isDirectory:true),
                    isKeyActive:{ id in store.allows(id,method:"send") },execute:{ try await client.request($0) },
                    mediaExpiresAt:{ id in try MediaStore(directory:store.directory.appendingPathComponent("media")).resolve(id).0.created.addingTimeInterval(MediaStore.lifetime) })
                scheduleService = schedules
            }
            let router = APIRouter(keys:store,webhooks:webhooks,schedules:schedules,mode:.full) { try await client.request($0) }
            self.router = router
            let listener = try LocalAPIServer(host: "0.0.0.0", port: port, router: router) { [weak self] method, status in
                self?.log.record("\(method) request: HTTP \(status).", level: status >= 400 ? .error : .info)
            }
            server = listener; starting = true; error = nil
            log.record("Starting API on port \(port).")
            let generation = UUID(); listenerID = generation
            listener.start { [weak self] ready in Task { @MainActor in
                guard let self, self.listenerID == generation else { return }; self.starting = false; self.running = ready
                if ready { self.log.record("API running."); self.router?.startServices() }
                else if self.server != nil { self.error = "The API listener stopped. Check the port and try again."; self.stop() }
            } }
        } catch { stop(); self.error = "Could not start the local API. Check the port and whether another BBC instance is running." }
    }
    func stop() {
        if server != nil { log.record("API stopped.") }
        listenerID = UUID()
        let oldServer = server; server = nil; oldServer?.stop(); router?.stop(); router = nil
        if lock >= 0 { flock(lock, LOCK_UN); close(lock); lock = -1 }
        running = false; starting = false
    }
}
