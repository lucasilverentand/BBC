import Foundation
import CryptoKit
import Security
import BBCClient
import Darwin

struct WebhookSnapshot: Sendable {
    let rowID: Int64
    let key: String
    let incoming: Bool
    let payload: BBCJSONValue
    var digest: String { (try? JSONEncoder.sorted.encode(payload)).map { SHA256.hash(data:$0).map { String(format:"%02x",$0) }.joined() } ?? "" }
}

/// A local durable outbox. Retrying delivery never dispatches a Messages action.
@MainActor final class WebhookService {
    struct Subscription: Codable, Equatable {
        let id: UUID
        let keyID: UUID
        let url: URL
        let chat: String?
        let secret: String
        let afterRowID: Int64
    }
    struct Delivery: Codable, Equatable {
        let id: UUID
        let subscriptionID: UUID
        let body: Data
        var attempts: Int = 0
        var nextAttempt: Date = .distantPast
    }
    struct State: Codable, Equatable {
        var stream: EventStreamState?
        var subscriptions: [Subscription] = []
        var deliveries: [Delivery] = []
        var highWater: Int64 = 0
        var highWaterChat = ""
        var revisit: Int64 = 0
        var revisitChat = ""
        var snapshots: [String:SnapshotRecord] = [:]
        var initialized = false
        var databaseIdentity: String?
        var databaseChanged: Bool?
    }
    struct SnapshotRecord: Codable, Equatable { let rowID: Int64; let digest: String }
    static let maximumSubscriptions = 8
    static let maximumDeliveries = 512
    static let maximumSnapshots = 100_000
    private let keys: APIKeyStore
    private let databaseURL: URL
    private let file: URL
    private let storeLock: WebhookStoreLock
    private let deliver: @Sendable (URLRequest) async -> Bool
    private(set) var state: State
    private(set) var observation = "stopped"
    private var task: Task<Void,Never>?
    private var running = false
    private var generation = UUID()
    private var operationScan = 0
    init(keys: APIKeyStore,
         databaseURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Messages/chat.db"),
         deliver: @escaping @Sendable (URLRequest) async -> Bool = WebhookHTTPDelivery.send) throws {
        self.keys = keys; self.databaseURL = databaseURL; self.deliver = deliver
        file = keys.directory.appendingPathComponent("webhooks.json")
        storeLock = try WebhookStoreLock(directory:keys.directory)
        if FileManager.default.fileExists(atPath:file.path) {
            let info = try FileManager.default.attributesOfItem(atPath:file.path)
            guard info[.type] as? FileAttributeType == .typeRegular,
                  ((info[.posixPermissions] as? NSNumber)?.intValue ?? 0o777) & 0o077 == 0,
                  (info[.size] as? NSNumber)?.intValue ?? Int.max <= 64 * 1024 * 1024 else { throw ActionFailure.invalid }
            state = try JSONDecoder().decode(State.self,from:Data(contentsOf:file))
            guard state.subscriptions.count <= Self.maximumSubscriptions, state.deliveries.count <= Self.maximumDeliveries,
                  state.snapshots.count <= Self.maximumSnapshots else { throw ActionFailure.invalid }
            if let stream = state.stream {
                guard stream.clients.count <= 8, stream.events.count <= EventStreamState.maximumEvents,
                      stream.events.reduce(0,{ $0 + $1.body.count }) <= EventStreamState.maximumBytes else { throw ActionFailure.invalid }
            }
        } else { state = State() }
        if state.databaseChanged == true { observation = "database_changed" }
    }
    func start() {
        guard task == nil else { return }
        generation = UUID(); let selected = generation
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.generation == selected else { return }
                await self.tick()
                try? await Task.sleep(for:.seconds(1))
            }
        }
    }
    func stop() { generation = UUID(); task?.cancel(); task = nil; observation = "stopped" }
    func handle(method: String, params: [String:BBCJSONValue], keyID: UUID) async throws -> BBCJSONValue {
        guard keys.keys.contains(where: { $0.id == keyID }) else { throw ActionFailure.invalid }
        switch method {
        case "webhooks.register":
            guard state.subscriptions.count < Self.maximumSubscriptions,
                  let raw = params["url"]?.string, let url = Self.validURL(raw) else { throw ActionFailure.invalid }
            let chat = try SearchFilter.optionalText(params["chat_guid"],maximum:512)
            let identity = try sourceIdentity()
            let database = try MessagesDatabase(url:databaseURL)
            let maximum = try database.maximumRowID()
            guard Self.sameSource(identity,try sourceIdentity()) else { throw ActionFailure.unavailable }
            var next = state
            if next.subscriptions.isEmpty && next.stream?.clients.isEmpty != false { resetObservation(in:&next) }
            try bindSource(identity,maximum:maximum,in:&next)
            var bytes = [UInt8](repeating:0,count:32)
            guard SecRandomCopyBytes(kSecRandomDefault,bytes.count,&bytes) == errSecSuccess else { throw ActionFailure.unavailable }
            let item = Subscription(id:UUID(),keyID:keyID,url:url,chat:chat,secret:Data(bytes).base64EncodedString(),afterRowID:maximum)
            next.subscriptions.append(item); try save(next)
            return .object(["ok":.bool(true),"webhook_id":.string(item.id.uuidString),"signing_secret":.string(item.secret),"observation":.string(observation)])
        case "webhooks.list":
            return .object(["webhooks":.array(state.subscriptions.filter { $0.keyID == keyID }.map { item in
                .object(["webhook_id":.string(item.id.uuidString),"url":.string(item.url.absoluteString),"chat_guid":item.chat.map(BBCJSONValue.string) ?? .null,
                         "pending":.number(Double(state.deliveries.filter { $0.subscriptionID == item.id }.count))])
            }),"observation":.string(observation),"pending_total":.number(Double(state.deliveries.count)),
                            "update_tracking":.string("recent-message-window"),"tracked_messages":.number(Double(state.snapshots.count)),"tracking_limit":.number(Double(Self.maximumSnapshots))])
        case "webhooks.remove":
            guard let raw = params["webhook_id"]?.string, let id = UUID(uuidString:raw),
                  state.subscriptions.contains(where: { $0.id == id && $0.keyID == keyID }) else { throw ActionFailure.invalid }
            var next = state; next.subscriptions.removeAll { $0.id == id }; next.deliveries.removeAll { $0.subscriptionID == id }
            if next.subscriptions.isEmpty && next.stream?.clients.isEmpty != false { resetObservation(in:&next); observation = "idle" }
            try save(next)
            return .object(["ok":.bool(true),"webhook_id":.string(id.uuidString)])
        default: throw ActionFailure.invalid
        }
    }
    nonisolated static func validURL(_ raw: String) -> URL? {
        guard raw.utf8.count <= 2048, !raw.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
              let url = URL(string:raw), let host = url.host?.lowercased(), !host.isEmpty,
              url.user == nil, url.password == nil, url.fragment == nil,
              url.scheme == "https" || (url.scheme == "http" && ["localhost","127.0.0.1","[::1]","::1"].contains(host)) else { return nil }
        return url
    }
    nonisolated static func signature(secret: String, timestamp: String, body: Data) -> String {
        guard let key = Data(base64Encoded:secret) else { return "" }
        let input = Data((timestamp+".").utf8)+body
        return "v1="+HMAC<SHA256>.authenticationCode(for:input,using:SymmetricKey(data:key)).map { String(format:"%02x",$0) }.joined()
    }
    /// Exposed internally for deterministic tests; bounded on each timer tick.
    func tick(now: Date = Date()) async {
        guard !running else { return }; running = true; defer { running = false }
        let selected = generation
        do {
            let valid = Set(keys.keys.map(\.id))
            var next = state
            next.subscriptions.removeAll { !valid.contains($0.keyID) }
            let active = Set(next.subscriptions.map(\.id))
            next.deliveries.removeAll { !active.contains($0.subscriptionID) }
            if var stream = next.stream {
                stream.clients = stream.clients.filter { valid.contains($0.key) }
                stream.events.removeAll { !valid.contains($0.keyID) }
                next.stream = stream
            }
            if next.subscriptions.isEmpty && next.stream?.clients.isEmpty != false {
                resetObservation(in:&next)
                try save(next); observation = "idle"; return
            }
            if next.databaseChanged == true { try save(next); throw ObservationFailure.databaseChanged }
            let identity = try sourceIdentity()
            let database = try MessagesDatabase(url:databaseURL)
            try bindSource(identity,maximum:database.maximumRowID(),in:&next)
            // Keep the new-message cursor separate from revisits. A read receipt
            // changes an existing row; ROWID alone cannot represent that event.
            let fresh = try database.webhookSnapshots(after:next.highWater,afterChat:next.highWaterChat,limit:100)
            for snapshot in fresh {
                try ingest(snapshot,fresh:true,into:&next,now:now)
                next.highWater = max(next.highWater,snapshot.rowID)
                next.highWaterChat = snapshot.payload.object?["chat_guid"]?.string ?? ""
            }
            // Recent sends need prompt sent/delivered/read updates even when an
            // account's older-history baseline takes many revisit cycles.
            let recent = try database.webhookSnapshots(after:0,through:next.highWater,throughChat:next.highWaterChat,limit:100,descending:true)
            for snapshot in recent { try ingest(snapshot,fresh:false,into:&next,now:now) }
            let revisited = try database.webhookSnapshots(after:next.revisit,afterChat:next.revisitChat,through:next.highWater,throughChat:next.highWaterChat,limit:100)
            for snapshot in revisited {
                try ingest(snapshot,fresh:false,into:&next,now:now)
                next.revisit = max(next.revisit,snapshot.rowID)
                next.revisitChat = snapshot.payload.object?["chat_guid"]?.string ?? ""
            }
            if revisited.count < 100 { next.revisit = 0; next.revisitChat = "" }
            if !Self.sameSource(identity,try sourceIdentity()) {
                // Discard events produced by a scan straddling file replacement.
                var blocked = state; blocked.databaseChanged = true; try save(blocked)
                throw ObservationFailure.databaseChanged
            }
            try save(next); observation = "watching"
        } catch {
            if error is ObservationFailure { observation = "database_changed" }
            else { observation = (error as? ActionFailure) == .busy ? "outbox_full" : "observation_unavailable" }
        }
        reconcileOperationEvents()
        // Delivery continues even if a full outbox or unavailable database has
        // paused observation. A successful drain allows the next scan to resume.
        for delivery in state.deliveries.filter({ $0.nextAttempt <= now }).prefix(4) {
            guard !Task.isCancelled, generation == selected, let item = state.subscriptions.first(where: { $0.id == delivery.subscriptionID }),
                  keys.keys.contains(where: { $0.id == item.keyID }) else { continue }
            let timestamp = String(Int64(now.timeIntervalSince1970))
            var request = URLRequest(url:item.url); request.httpMethod = "POST"; request.httpBody = delivery.body; request.timeoutInterval = 10
            request.setValue("application/json",forHTTPHeaderField:"Content-Type")
            request.setValue(delivery.id.uuidString,forHTTPHeaderField:"X-BBC-Event-ID")
            request.setValue(timestamp,forHTTPHeaderField:"X-BBC-Timestamp")
            request.setValue(Self.signature(secret:item.secret,timestamp:timestamp,body:delivery.body),forHTTPHeaderField:"X-BBC-Signature")
            let accepted = await deliver(request)
            var next = state
            guard let index = next.deliveries.firstIndex(where: { $0.id == delivery.id && $0.subscriptionID == delivery.subscriptionID }) else { continue }
            if accepted { next.deliveries.remove(at:index) }
            else {
                next.deliveries[index].attempts = min(30,next.deliveries[index].attempts+1)
                next.deliveries[index].nextAttempt = now.addingTimeInterval(min(3600,pow(2,Double(next.deliveries[index].attempts))))
            }
            do { try save(next) } catch { observation = "storage_unavailable"; return }
            if generation != selected { return }
        }
    }
    private func ingest(_ snapshot: WebhookSnapshot, fresh: Bool, into next: inout State, now: Date) throws {
        let previous = next.snapshots[snapshot.key]
        guard previous?.digest != snapshot.digest else { return }
        if previous == nil, next.snapshots.count >= Self.maximumSnapshots,
           let oldest = next.snapshots.min(by: { $0.value.rowID < $1.value.rowID }) {
            // New arrivals continue when the tracking window is full. Revisits
            // outside it cannot establish an old baseline by evicting new rows.
            guard snapshot.rowID >= oldest.value.rowID else { return }
            next.snapshots.removeValue(forKey:oldest.key)
        }
        let type = fresh && snapshot.incoming ? "message.received" : (previous == nil ? nil : "message.updated")
        if let type {
            let subscriptions = next.subscriptions.filter { item in
                (item.chat == nil || item.chat == snapshot.payload.object?["chat_guid"]?.string) &&
                (type != "message.received" || snapshot.rowID > item.afterRowID)
            }
            guard next.deliveries.count+subscriptions.count <= Self.maximumDeliveries else { throw ActionFailure.busy }
            let eventID = UUID()
            let packet: BBCJSONValue = .object(["id":.string(eventID.uuidString),"type":.string(type),
                                              "observed_at":.string(ISO8601DateFormatter().string(from:now)),"message":snapshot.payload])
            let body = try JSONEncoder.sorted.encode(packet)
            guard body.count <= 131_072 else { throw ActionFailure.invalid }
            for item in subscriptions { next.deliveries.append(.init(id:eventID,subscriptionID:item.id,body:body)) }
            if let clients = next.stream?.clients {
                for (keyID,client) in clients where type != "message.received" || snapshot.rowID > client.afterRowID {
                    try next.stream?.append(packet,keyID:keyID)
                }
            }
        }
        next.snapshots[snapshot.key] = SnapshotRecord(rowID:snapshot.rowID,digest:snapshot.digest)
    }
    /// No cursor means a new baseline at the current tail. Resume requires the last
    /// durably consumed cursor; a gap is explicit and never silently skips events.
    func streamBatch(keyID: UUID, after cursor: String?) throws -> EventStreamBatch {
        guard keys.keys.contains(where:{ $0.id == keyID }) else { throw ActionFailure.invalid }
        var next = state
        if next.stream == nil { next.stream = EventStreamState() }
        if next.stream!.clients[keyID] == nil {
            guard next.stream!.clients.count < 8 else { throw ActionFailure.busy }
            let identity = try sourceIdentity(), database = try MessagesDatabase(url:databaseURL)
            let maximum = try database.maximumRowID()
            guard Self.sameSource(identity,try sourceIdentity()) else { throw ActionFailure.unavailable }
            try bindSource(identity,maximum:maximum,in:&next)
            next.stream!.clients[keyID] = .init(since:Date(),afterRowID:maximum)
            try save(next)
        }
        let stream = state.stream!
        let position: Int64
        if let cursor {
            guard let value = try? stream.position(cursor), value >= stream.clients[keyID]!.floor else {
                return EventStreamBatch(status:409,cursor:nil,frames:Data())
            }
            position = value
        } else { position = stream.sequence }
        let events = stream.events.filter { $0.keyID == keyID && $0.sequence > position }.prefix(16)
        var frames = Data(), last = position
        for event in events {
            frames.append(Data("id: \(stream.cursor(event.sequence))\nevent: bbc.event\ndata: ".utf8))
            frames.append(event.body); frames.append(Data("\n\n".utf8)); last = event.sequence
        }
        return EventStreamBatch(status:200,cursor:stream.cursor(last),frames:frames,observation:observation)
    }

    /// The operation file remains authoritative. Its publication marker is written
    /// after the replay journal, so interruption can duplicate a notification but
    /// cannot turn a notification into another native dispatch.
    func publishOperation(file: URL, keyID: UUID, operationID: UUID) throws {
        guard let client = state.stream?.clients[keyID], keys.keys.contains(where:{ $0.id == keyID }) else { return }
        var operation = try JSONDecoder().decode(APIRouter.Operation.self,from:Data(contentsOf:file))
        guard let result = operation.result, let method = operation.method,
              let created = operation.createdAt, created >= client.since else { return }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let digest = APIKeyStore.digest(String(decoding:try encoder.encode(result),as:UTF8.self))
        guard digest != operation.eventDigest else { return }
        var next = state
        try next.stream?.append(.object(["id":.string(operationID.uuidString+":"+digest),"type":.string("operation.updated"),
            "operation_id":.string(operationID.uuidString),"method":.string(method),"result":result]),keyID:keyID)
        try save(next)
        operation.eventDigest = digest
        try encoder.encode(operation).write(to:file,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
    }
    private func reconcileOperationEvents() {
        guard state.stream?.clients.isEmpty == false,
              let files = try? FileManager.default.contentsOfDirectory(at:keys.directory,includingPropertiesForKeys:nil).filter({ $0.lastPathComponent.hasPrefix("operation-") && $0.pathExtension == "json" }).sorted(by:{ $0.lastPathComponent < $1.lastPathComponent }), !files.isEmpty else { return }
        // Round-robin replay repairs a crash between receipt persistence and publication.
        for _ in 0..<min(100,files.count) {
            let file = files[operationScan % files.count]; operationScan = (operationScan+1) % files.count
            let name = file.deletingPathExtension().lastPathComponent
            let raw = String(name.dropFirst("operation-".count))
            guard raw.count == 73, let key = UUID(uuidString:String(raw.prefix(36))), let id = UUID(uuidString:String(raw.suffix(36))) else { continue }
            try? publishOperation(file:file,keyID:key,operationID:id)
        }
    }

    private func save(_ next: State) throws {
        guard next != state else { return }
        // A revisit can safely restart from an earlier persisted cursor because
        // unchanged message hashes produce no events. Avoid rewriting the whole
        // snapshot file every second just to checkpoint that scan position.
        var previous = state; previous.revisit = next.revisit; previous.revisitChat = next.revisitChat
        if next == previous { state = next; return }
        let data = try JSONEncoder.sorted.encode(next)
        guard data.count <= 64 * 1024 * 1024 else { throw ActionFailure.unavailable }
        try data.write(to:file,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
        state = next
    }
    private enum ObservationFailure: Error { case databaseChanged }
    private func resetObservation(in next: inout State) {
        next.snapshots.removeAll(); next.initialized = false; next.highWater = 0; next.highWaterChat = ""; next.revisit = 0; next.revisitChat = ""
        next.databaseIdentity = nil; next.databaseChanged = nil
    }
    private func sourceIdentity() throws -> String {
        var info = stat()
        guard stat(databaseURL.path,&info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw ActionFailure.unavailable }
        let file = "\(info.st_dev):\(info.st_ino):\(info.st_birthtimespec.tv_sec):\(info.st_birthtimespec.tv_nsec)"
        // A fresh URL avoids Foundation's cached resource values. The volume UUID persists
        // across reboots, unlike `volumeIdentifierKey`, so a copy restored onto another
        // volume cannot pass as the same database by matching its inode and birth time.
        // A volume that reports no UUID falls back to inode and birth time.
        guard let volume = try URL(fileURLWithPath:databaseURL.path).resourceValues(forKeys:[.volumeUUIDStringKey]).volumeUUIDString,
              !volume.isEmpty, !volume.contains(":") else { return file }
        return "\(file):\(volume)"
    }
    /// The same Messages database keeps its inode, birth time and volume UUID. `st_dev`
    /// is recorded but not compared: APFS can renumber the same volume across a reboot,
    /// which must not pause webhooks. An identity saved before the volume UUID was
    /// recorded matches on inode and birth time, and the next bind upgrades it.
    /// Identities that do not parse compare exactly.
    nonisolated static func sameSource(_ stored: String, _ live: String) -> Bool {
        let a = stored.split(separator:":",omittingEmptySubsequences:false), b = live.split(separator:":",omittingEmptySubsequences:false)
        guard (4...5).contains(a.count), (4...5).contains(b.count) else { return stored == live }
        guard a[1..<4] == b[1..<4] else { return false }
        return a.count == 4 || b.count == 4 || a[4] == b[4]
    }
    private func bindSource(_ identity: String, maximum: Int64, in next: inout State) throws {
        if next.databaseChanged == true || (next.databaseIdentity.map { !Self.sameSource($0,identity) } ?? false) ||
            (next.initialized && maximum < next.highWater) {
            next.databaseChanged = true; try save(next); observation = "database_changed"
            throw ObservationFailure.databaseChanged
        }
        next.databaseIdentity = identity
        if !next.initialized { next.highWater = maximum; next.initialized = true }
    }
}

/// Held for the service lifetime, including any delivery still awaiting a result.
private final class WebhookStoreLock: Sendable {
    private let fd: Int32
    init(directory: URL) throws {
        let value = open(directory.appendingPathComponent("webhooks.lock").path,O_CREAT|O_RDWR|O_NOFOLLOW|O_CLOEXEC,0o600)
        guard value >= 0 else { throw ActionFailure.unavailable }
        var info = stat()
        guard fstat(value,&info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o077 == 0 else { close(value); throw ActionFailure.invalid }
        guard flock(value,LOCK_EX|LOCK_NB) == 0 else { close(value); throw ActionFailure.busy }
        fd = value
    }
    deinit { flock(fd,LOCK_UN); close(fd) }
}

private extension JSONEncoder {
    static var sorted: JSONEncoder { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return encoder }
}

/// Stop at the response headers: a webhook endpoint cannot stream an unbounded
/// response body into the app. Redirects never receive the event or signature.
private final class WebhookHTTPDelivery: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool,Never>?
    private var session: URLSession?
    static func send(_ request: URLRequest) async -> Bool {
        let delegate = WebhookHTTPDelivery()
        return await withCheckedContinuation { continuation in
            delegate.continuation = continuation
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpShouldSetCookies = false; configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
            configuration.timeoutIntervalForRequest = 10; configuration.timeoutIntervalForResource = 15
            let session = URLSession(configuration:configuration,delegate:delegate,delegateQueue:nil)
            delegate.session = session; session.dataTask(with:request).resume()
        }
    }
    private func finish(_ value: Bool) {
        lock.lock(); let pending = continuation; continuation = nil; let session = session; self.session = nil; lock.unlock()
        pending?.resume(returning:value); session?.invalidateAndCancel()
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let accepted = (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
        completionHandler(.cancel); finish(accepted)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) { finish(false) }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
