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
        var subscriptions: [Subscription] = []
        var deliveries: [Delivery] = []
        var highWater: Int64 = 0
        var highWaterChat = ""
        var revisit: Int64 = 0
        var revisitChat = ""
        var snapshots: [String:SnapshotRecord] = [:]
        var initialized = false
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
        } else { state = State() }
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
            let database = try MessagesDatabase(url:databaseURL)
            let maximum = try database.maximumRowID()
            var next = state
            if !next.initialized { next.highWater = maximum; next.initialized = true }
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
            var next = state; next.subscriptions.removeAll { $0.id == id }; next.deliveries.removeAll { $0.subscriptionID == id }; try save(next)
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
            if next.subscriptions.isEmpty {
                next.snapshots.removeAll(); next.initialized = false; next.highWater = 0; next.highWaterChat = ""; next.revisit = 0; next.revisitChat = ""
                try save(next); observation = "idle"; return
            }
            let database = try MessagesDatabase(url:databaseURL)
            if !next.initialized { next.highWater = try database.maximumRowID(); next.initialized = true }
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
            try save(next); observation = "watching"
        } catch { observation = (error as? ActionFailure) == .busy ? "outbox_full" : "observation_unavailable" }
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
        }
        next.snapshots[snapshot.key] = SnapshotRecord(rowID:snapshot.rowID,digest:snapshot.digest)
    }
    private func save(_ next: State) throws {
        guard next != state else { return }
        let data = try JSONEncoder.sorted.encode(next)
        guard data.count <= 64 * 1024 * 1024 else { throw ActionFailure.unavailable }
        try data.write(to:file,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
        state = next
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
