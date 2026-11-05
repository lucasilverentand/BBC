import Foundation
import Network
import BBCClient

/// Local IPC only. All mutable state belongs to queue; no native call is retried.
final class BridgeBroker: @unchecked Sendable {
    private static let advancedMethods = Set(["groups.create","groups.add","groups.remove","groups.name","groups.photo","groups.leave","messages.edit","messages.unsend","messages.multipart","availability"])
    /// Production defaults are unchanged; tests inject shorter deadlines and smaller limits.
    struct Configuration: Sendable {
        var commandDeadline: TimeInterval = 24
        var authenticationDeadline: TimeInterval = 5
        var maximumClients = 10
        var maximumPending = 8
        static let production = Configuration()
    }
    private let listener: NWListener
    private let configuration: Configuration
    private let queue = DispatchQueue(label:"club.bluebubble.native-bridge")
    private let helperSecret: String
    private let workerSecret: String
    private var clients: [UUID: Client] = [:]
    private var helper: UUID?
    private var capabilities: [BBCJSONValue] = []
    private var pending: [String: UUID] = [:]
    private var completed: Set<String> = []
    private var completedOrder: [String] = []
    private var startReported = false
    private var stopped = false
    private var listenerStarted = false
    private var listenerCancelled = false
    private var cancelWaiters: [() -> Void] = []
    private let endpointURL: URL
    private final class Once: @unchecked Sendable { var done = false }
    private final class Client: @unchecked Sendable {
        let connection: NWConnection
        let nonce = UUID().uuidString
        var role: String?
        var called = false
        var buffer = Data()
        init(_ connection: NWConnection) { self.connection = connection }
    }
    init(directory: URL = BridgeWire.directory, helperSecret: String? = nil, workerSecret: String? = nil, configuration: Configuration = .production) throws {
        self.configuration = configuration
        self.helperSecret = try helperSecret ?? BridgeWire.secret()
        self.workerSecret = try workerSecret ?? BridgeWire.secret()
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let info = try FileManager.default.attributesOfItem(atPath:directory.path)
        guard info[.type] as? FileAttributeType == .typeDirectory, (info[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              ((info[.posixPermissions] as? NSNumber)?.intValue ?? 0o777) & 0o077 == 0 else { throw ActionFailure.invalid }
        endpointURL = directory.appendingPathComponent("endpoint.json")
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host:"127.0.0.1",port:.any)
        listener = try NWListener(using:parameters)
        listener.newConnectionHandler = { [weak self] in self?.accept($0) }
    }
    func start(ready: @escaping @Sendable (UInt16?,String?) -> Void) {
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .ready = state, let port = self.listener.port?.rawValue {
                guard !self.startReported else { return }; self.startReported = true
                do {
                    let endpoint = BridgeWire.Endpoint(version:BridgeWire.version,port:port,secret:self.workerSecret,ownerPID:getpid())
                    try JSONEncoder().encode(endpoint).write(to:self.endpointURL,options:.atomic)
                    try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:self.endpointURL.path)
                    ready(port,self.helperSecret)
                } catch { self.stop(); ready(nil,nil) }
            } else {
                switch state {
                case .failed, .cancelled:
                    if case .cancelled = state { self.queue.async { self.listenerCancelled = true; let waiters = self.cancelWaiters; self.cancelWaiters = []; waiters.forEach { $0() } } }
                    self.stop()
                    if !self.startReported { self.startReported = true; ready(nil,nil) }
                default: break
                }
            }
        }
        queue.async { self.listenerStarted = true }
        listener.start(queue:queue)
    }
    func stop() {
        listener.cancel()
        queue.async { self.teardown() }
    }
    /// Stops accepting, closes every connection and removes only an endpoint file this broker wrote.
    /// Returns after teardown and listener cancellation (or `timeout`); safe to call repeatedly.
    func shutdown(timeout: TimeInterval = 5) async {
        listener.cancel()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void,Never>) in
            queue.async {
                self.teardown()
                let once = Once()   // only touched on `queue`
                let finish: @Sendable () -> Void = { if !once.done { once.done = true; continuation.resume() } }
                if self.listenerCancelled || !self.listenerStarted { finish(); return }
                self.cancelWaiters.append(finish)
                self.queue.asyncAfter(deadline:.now()+timeout) { finish() }
            }
        }
    }
    private func teardown() {
        stopped = true
        for client in clients.values { client.connection.cancel() }
        clients.removeAll(); helper = nil; capabilities = []; pending.removeAll()
        if let endpoint = try? BridgeWire.Endpoint.load(from:endpointURL), endpoint.ownerPID == getpid(), BridgeWire.equal(endpoint.secret,workerSecret) { try? FileManager.default.removeItem(at:endpointURL) }
    }
    private func accept(_ connection: NWConnection) {
        guard !stopped, clients.count < configuration.maximumClients else { connection.cancel(); return }
        let id = UUID(), client = Client(connection); clients[id] = client
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            if case .failed = state { connection?.cancel() }
            if case .cancelled = state { self?.closed(id) }
        }
        connection.start(queue:queue)
        send(.object(["kind":.string("challenge"),"nonce":.string(client.nonce)]),to:client)
        queue.asyncAfter(deadline:.now()+configuration.authenticationDeadline) { if client.role == nil { connection.cancel() } }
        receive(id)
    }
    private func closed(_ id: UUID) {
        clients.removeValue(forKey:id)
        if helper == id {
            helper = nil; capabilities = []
            let requests = pending; pending.removeAll()
            for (request,worker) in requests { finish(request,worker:worker,result:.object(["ok":.bool(false),"uncertain":.bool(true),"failure_code":.string("native_bridge_disconnected")])) }
        }
    }
    private func receive(_ id: UUID) {
        guard let client = clients[id] else { return }
        client.connection.receive(minimumIncompleteLength:1,maximumLength:8192) { [weak self] data,_,complete,error in
            guard let self else { return }
            if let data { client.buffer.append(data) }
            guard client.buffer.count <= BridgeWire.maximumFrame, error == nil else { client.connection.cancel(); return }
            while let end = client.buffer.firstIndex(of:10) {
                let data = Data(client.buffer[..<end]); client.buffer.removeSubrange(...end)
                guard let packet = try? JSONDecoder().decode(BBCJSONValue.self,from:data) else { client.connection.cancel(); return }
                self.handle(packet,id:id,client:client)
            }
            if complete { client.connection.cancel() } else { self.receive(id) }
        }
    }
    private func handle(_ packet: BBCJSONValue, id: UUID, client: Client) {
        guard let fields = packet.object, let kind = fields["kind"]?.string else { client.connection.cancel(); return }
        if client.role == nil {
            guard kind == "authenticate", let role = fields["role"]?.string, ["helper","worker"].contains(role), let proof = fields["proof"]?.string else { client.connection.cancel(); return }
            let secret = role == "helper" ? helperSecret : workerSecret
            guard BridgeWire.equal(proof,BridgeWire.proof(secret:secret,nonce:client.nonce,role:role,server:false)), role != "helper" || helper == nil else { client.connection.cancel(); return }
            client.role = role
            if role == "helper" { helper = id }
            send(.object(["kind":.string("authenticated"),"proof":.string(BridgeWire.proof(secret:secret,nonce:client.nonce,role:role,server:true))]),to:client)
            return
        }
        if client.role == "helper" {
            if kind == "hello", fields["version"]?.numberValue == Double(BridgeWire.version), case .array(let features) = fields["capabilities"] {
                let allowed = Set(["read","reply","link","tapback","custom-emoji","typing"]).union(Self.advancedMethods)
                capabilities = features.filter { $0.string.map(allowed.contains) == true }; return
            }
            guard kind == "result", let request = fields["id"]?.string, let result = fields["result"] else { client.connection.cancel(); return }
            if completed.contains(request) { return }
            guard let worker = pending.removeValue(forKey:request) else { return }
            finish(request,worker:worker,result:result); return
        }
        guard !client.called, kind == "call", let requestID = fields["id"]?.string, UUID(uuidString:requestID) != nil,
              let request = fields["request"], let method = request.object?["method"]?.string else { client.connection.cancel(); return }
        client.called = true
        // A duplicate of an in-flight id belongs to the original transaction: reject this caller
        // directly and never touch `pending`/`completed`, or the real result would be discarded.
        if pending[requestID] != nil {
            send(.object(["kind":.string("result"),"id":.string(requestID),"result":.object(["ok":.bool(false),"uncertain":.bool(false),"failure_code":.string("native_bridge_unavailable")])]),to:client,close:true); return
        }
        if method == "bridge.status" {
            finish(requestID,worker:id,result:.object(["ready":.bool(helper != nil && !capabilities.isEmpty),"version":.number(1),"capabilities":.array(capabilities)])); return
        }
        guard pending.count < configuration.maximumPending, (["read","reply","link","tapback","typing.start","typing.stop"].contains(method) || Self.advancedMethods.contains(method)), !completed.contains(requestID), pending[requestID] == nil,
              let helper, let embedded = clients[helper], !capabilities.isEmpty else {
            finish(requestID,worker:id,result:.object(["ok":.bool(false),"uncertain":.bool(false),"failure_code":.string("native_bridge_unavailable")])); return
        }
        pending[requestID] = id
        send(.object(["kind":.string("command"),"id":.string(requestID),"request":request]),to:embedded)
        queue.asyncAfter(deadline:.now()+configuration.commandDeadline) { [weak self] in
            guard let self, let worker = self.pending.removeValue(forKey:requestID) else { return }
            self.finish(requestID,worker:worker,result:.object(["ok":.bool(false),"uncertain":.bool(true),"failure_code":.string("native_bridge_timeout")]))
        }
    }
    private func finish(_ request: String, worker: UUID, result: BBCJSONValue) {
        if completed.insert(request).inserted { completedOrder.append(request) }
        if completedOrder.count > 256 { completed.remove(completedOrder.removeFirst()) }
        guard let client = clients[worker] else { return }
        send(.object(["kind":.string("result"),"id":.string(request),"result":result]),to:client,close:true)
    }
    private func send(_ packet: BBCJSONValue, to client: Client, close: Bool = false) {
        guard let data = try? BridgeWire.frame(packet) else { client.connection.cancel(); return }
        client.connection.send(content:data,completion:.contentProcessed { error in if close || error != nil { client.connection.cancel() } })
    }
}
