import Foundation
import XCTest
import Darwin
import BBCClient
@testable import BBCMessagesActions

/// Shared native-bridge fixtures (internal, reused by worker tests).
///
/// - `BridgeFixtureHarness.run(configuration:) { harness in ... }` starts a real `BridgeBroker` in a
///   temporary directory, hands over the endpoint, and always awaits `broker.shutdown()` before
///   deleting the directory.
/// - `FixturePeer` is a blocking loopback socket speaking the wire protocol. Every read has a
///   watchdog (`timeout`, default 10s) so a hung broker fails the test instead of the run. Use the
///   `async` helpers from tests; they run the blocking call off the main actor.
/// - `FixtureHelper` is an authenticated helper that records every forwarded command in order
///   (`commands`); `expectNoStrayCommand(barrier:)` proves nothing extra was forwarded by sending a
///   fresh worker call and requiring it to be the very next command on the ordered helper stream.
/// - `FixtureWorker` is an authenticated raw worker with an explicit request id.
final class FixturePeer: @unchecked Sendable {
    enum Read: Equatable { case packet(BBCJSONValue), closed, timedOut }
    private var fd: Int32
    private var buffer = Data()
    let role: String
    init(port: UInt16, role: String, timeout: Int = 10) throws {
        self.role = role
        fd = socket(AF_INET,SOCK_STREAM,0)
        guard fd >= 0 else { throw ActionFailure.unavailable }
        var tv = timeval(tv_sec:timeout,tv_usec:0), noSignal: Int32 = 1
        setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&tv,socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd,SOL_SOCKET,SO_SNDTIMEO,&tv,socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&noSignal,socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian; address.sin_addr.s_addr = inet_addr("127.0.0.1")
        guard withUnsafePointer(to:&address,{ $0.withMemoryRebound(to:sockaddr.self,capacity:1) { connect(fd,$0,socklen_t(MemoryLayout<sockaddr_in>.size)) } }) == 0 else { Darwin.close(fd); fd = -1; throw ActionFailure.unavailable }
    }
    init(adopting fd: Int32, role: String = "worker") { self.fd = fd; self.role = role }
    deinit { close() }
    func close() { if fd >= 0 { Darwin.close(fd); fd = -1 } }
    func sendRaw(_ data: Data) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd,bytes.baseAddress!.advanced(by:offset),bytes.count-offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw ActionFailure.unavailable }; offset += count
            }
        }
    }
    func send(_ packet: BBCJSONValue) throws { try sendRaw(BridgeWire.frame(packet)) }
    /// One framed packet, EOF/reset, or watchdog expiry. Never throws for those three outcomes.
    func read() -> Read {
        while buffer.firstIndex(of:10) == nil {
            var bytes = [UInt8](repeating:0,count:8192)
            let count = Darwin.read(fd,&bytes,bytes.count)
            if count < 0 && errno == EINTR { continue }
            if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { return .timedOut }
            guard count > 0 else { return .closed }
            guard buffer.count + count <= BridgeWire.maximumFrame else { return .closed }
            buffer.append(contentsOf:bytes.prefix(count))
        }
        let end = buffer.firstIndex(of:10)!, data = Data(buffer[..<end]); buffer.removeSubrange(...end)
        guard let value = try? JSONDecoder().decode(BBCJSONValue.self,from:data) else { return .closed }
        return .packet(value)
    }
    func receive() throws -> BBCJSONValue {
        guard case .packet(let value) = read() else { throw ActionFailure.unavailable }
        return value
    }
    func asyncRead() async -> Read { await Task.detached { self.read() }.value }
    func asyncReceive() async throws -> BBCJSONValue { try await Task.detached { try self.receive() }.value }
    func asyncSend(_ packet: BBCJSONValue) async throws { try await Task.detached { try self.send(packet) }.value }
    /// Completes the challenge/response. Returns false when the broker closes instead of authenticating.
    @discardableResult func authenticate(secret: String) throws -> Bool {
        guard case .packet(let challenge) = read(), let nonce = challenge.object?["nonce"]?.string else { return false }
        try send(.object(["kind":.string("authenticate"),"role":.string(role),"proof":.string(BridgeWire.proof(secret:secret,nonce:nonce,role:role,server:false))]))
        guard case .packet(let reply) = read(), reply.object?["kind"]?.string == "authenticated",
              reply.object?["proof"]?.string == BridgeWire.proof(secret:secret,nonce:nonce,role:role,server:true) else { return false }
        return true
    }
}

extension BBCJSONValue {
    static func result(id: String, _ result: BBCJSONValue) -> BBCJSONValue { .object(["kind":.string("result"),"id":.string(id),"result":result]) }
    static func call(id: String, method: String) -> BBCJSONValue { .object(["kind":.string("call"),"id":.string(id),"request":.object(["method":.string(method)])]) }
}

final class FixtureHelper: @unchecked Sendable {
    let peer: FixturePeer
    private(set) var commands: [String] = []
    init(harness: BridgeFixtureHarness, capabilities: [String] = ["tapback","read","reply"], timeout: Int = 10) async throws {
        peer = try FixturePeer(port:harness.endpoint.port,role:"helper",timeout:timeout)
        let secret = harness.helperSecret, p = peer
        guard try await Task.detached(operation:{ try p.authenticate(secret:secret) }).value else { throw ActionFailure.unavailable }
        try await peer.asyncSend(.object(["kind":.string("hello"),"version":.number(1),"capabilities":.array(capabilities.map { .string($0) })]))
        try await harness.waitUntilReady()
    }
    /// Next forwarded command (records its id); fails on EOF or watchdog.
    func nextCommand() async throws -> (id: String, method: String) {
        let packet = try await peer.asyncReceive()
        guard packet.object?["kind"]?.string == "command", let id = packet.object?["id"]?.string,
              let method = packet.object?["request"]?.object?["method"]?.string else { throw ActionFailure.invalid }
        commands.append(id); return (id,method)
    }
    func reply(id: String, _ result: BBCJSONValue = .object(["ok":.bool(true)])) async throws { try await peer.asyncSend(.result(id:id,result)) }
    /// Barrier: a fresh worker call must be the very next command, so no earlier stray command exists.
    func expectNoStrayCommand(harness: BridgeFixtureHarness, method: String = "tapback") async throws {
        let barrier = try await FixtureWorker(harness: harness), id = UUID().uuidString
        try await barrier.call(id:id,method:method)
        let next = try await nextCommand()
        XCTAssertEqual(next.id,id,"a stray command was forwarded before the barrier")
        try await reply(id:id)
        _ = try await barrier.result()
    }
}

final class FixtureWorker: @unchecked Sendable {
    let peer: FixturePeer
    init(harness: BridgeFixtureHarness, timeout: Int = 10) async throws {
        peer = try FixturePeer(port:harness.endpoint.port,role:"worker",timeout:timeout)
        let secret = harness.endpoint.secret, p = peer
        guard try await Task.detached(operation:{ try p.authenticate(secret:secret) }).value else { throw ActionFailure.unavailable }
    }
    func call(id: String, method: String = "tapback") async throws { try await peer.asyncSend(.call(id:id,method:method)) }
    /// The `result` object of the next result frame; fails on EOF/watchdog.
    func result() async throws -> BBCJSONValue {
        let packet = try await peer.asyncReceive()
        guard packet.object?["kind"]?.string == "result", let result = packet.object?["result"] else { throw ActionFailure.invalid }
        return result
    }
}

private final class BridgeStartGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<UInt16, Error>?
    init(_ continuation: CheckedContinuation<UInt16, Error>) { self.continuation = continuation }
    func finish(_ result: Result<UInt16, Error>) {
        lock.lock(); let current = continuation; continuation = nil; lock.unlock()
        current?.resume(with:result)
    }
}

struct BridgeFixtureHarness: Sendable {
    let broker: BridgeBroker
    let directory: URL
    let endpoint: BridgeWire.Endpoint
    let helperSecret: String
    var endpointFile: URL { directory.appendingPathComponent("endpoint.json") }
    /// Starts a broker, runs `body`, then awaits shutdown before removing the directory.
    @MainActor static func run(configuration: BridgeBroker.Configuration = .production, _ body: @MainActor (BridgeFixtureHarness) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bbc-bridge-\(UUID().uuidString)")
        let secret = try BridgeWire.secret(), broker = try BridgeBroker(directory:directory,helperSecret:secret,configuration:configuration)
        do {
            _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
                let gate = BridgeStartGate(continuation)
                broker.start { port,_ in gate.finish(port.map { .success($0) } ?? .failure(ActionFailure.unavailable)) }
                DispatchQueue.global().asyncAfter(deadline:.now()+5) { gate.finish(.failure(ActionFailure.unavailable)) }
            }
            let harness = BridgeFixtureHarness(broker:broker,directory:directory,endpoint:try BridgeWire.Endpoint.load(from:directory.appendingPathComponent("endpoint.json")),helperSecret:secret)
            try await body(harness)
        } catch {
            await broker.shutdown(); try? FileManager.default.removeItem(at:directory); throw error
        }
        await broker.shutdown(); try? FileManager.default.removeItem(at:directory)
    }

    func status() async throws -> BBCJSONValue {
        let endpoint = self.endpoint
        return try await Task.detached { try NativeBridgeClient.request(.object(["method":.string("bridge.status")]),endpoint:endpoint,timeout:10) }.value
    }
    /// Bounded readiness poll (a condition wait, not an ordering proof).
    func waitUntilReady(deadline: TimeInterval = 10) async throws {
        let end = Date().addingTimeInterval(deadline)
        while Date() < end {
            if try await status().object?["ready"]?.bool == true { return }
            try await Task.sleep(for:.milliseconds(10))
        }
        throw ActionFailure.unavailable
    }
}
