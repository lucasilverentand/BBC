import Foundation
import CryptoKit
import Security
import BBCClient
import Darwin

enum BridgeWire {
    static let version = 1
    static let maximumFrame = 131_072
    static let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Blue Bubble Club/native-bridge", isDirectory: true)
    static let endpoint = directory.appendingPathComponent("endpoint.json")
    static func secret() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw ActionFailure.unavailable }
        return Data(bytes).base64EncodedString()
    }
    static func proof(secret: String, nonce: String, role: String, server: Bool) -> String {
        guard let data = Data(base64Encoded: secret), data.count == 32 else { return "" }
        return Data(HMAC<SHA256>.authenticationCode(for: Data("\(server ? "server" : "client"):\(nonce):\(role)".utf8), using: SymmetricKey(data: data))).base64EncodedString()
    }
    static func equal(_ left: String, _ right: String) -> Bool {
        let a = Array(left.utf8), b = Array(right.utf8)
        return !a.isEmpty && a.count == b.count && zip(a,b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
    static func frame(_ value: BBCJSONValue) throws -> Data {
        let data = try JSONEncoder().encode(value)
        guard data.count <= maximumFrame else { throw ActionFailure.invalid }
        return data + Data([10])
    }
    struct Endpoint: Codable, Sendable {
        let version: Int
        let port: UInt16
        let secret: String
        let ownerPID: Int32
        static func load(from url: URL = BridgeWire.endpoint) throws -> Self {
            let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw ActionFailure.unavailable }
            let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? file.close() }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
                  info.st_mode & 0o077 == 0, info.st_size > 0, info.st_size <= 4096 else { throw ActionFailure.invalid }
            let data = try file.read(upToCount: 4097) ?? Data()
            let value = try JSONDecoder().decode(Self.self, from: data)
            guard value.version == BridgeWire.version, value.port > 0, value.ownerPID > 0,
                  Data(base64Encoded: value.secret)?.count == 32 else { throw ActionFailure.invalid }
            return value
        }
    }
}

/// A fresh authenticated connection per call, with no reconnect or replay.
enum NativeBridgeClient {
    static func request(_ request: BBCJSONValue, endpoint: BridgeWire.Endpoint? = nil, timeout seconds: Int = 25) throws -> BBCJSONValue {
        var dispatched = false
        do {
        let selected = try endpoint ?? BridgeWire.Endpoint.load()
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ActionFailure.unavailable }
        defer { close(fd) }
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal)))
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        address.sin_port = selected.port.bigEndian; address.sin_addr.s_addr = inet_addr("127.0.0.1")
        guard withUnsafePointer(to: &address, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }) == 0 else { throw ActionFailure.unavailable }
        var buffer = Data()
        func receive() throws -> BBCJSONValue {
            while buffer.firstIndex(of: 10) == nil {
                var chunk = [UInt8](repeating: 0, count: 8192)
                let count = Darwin.read(fd, &chunk, chunk.count)
                if count < 0 && errno == EINTR { continue }
                guard count > 0, buffer.count + count <= BridgeWire.maximumFrame else { throw ActionFailure.uncertain }
                buffer.append(contentsOf: chunk.prefix(count))
            }
            let end = buffer.firstIndex(of: 10)!, data = Data(buffer[..<end])
            buffer.removeSubrange(...end)
            return try JSONDecoder().decode(BBCJSONValue.self, from: data)
        }
        func send(_ value: BBCJSONValue) throws {
            let data = try BridgeWire.frame(value)
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count-offset)
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { throw ActionFailure.uncertain }; offset += count
                }
            }
        }
        let challenge = try receive()
        guard challenge.object?["kind"]?.string == "challenge", let nonce = challenge.object?["nonce"]?.string, UUID(uuidString: nonce) != nil else { throw ActionFailure.unavailable }
        try send(.object(["kind":.string("authenticate"),"role":.string("worker"),"proof":.string(BridgeWire.proof(secret:selected.secret,nonce:nonce,role:"worker",server:false))]))
        let authenticated = try receive()
        guard authenticated.object?["kind"]?.string == "authenticated", let proof = authenticated.object?["proof"]?.string,
              BridgeWire.equal(proof,BridgeWire.proof(secret:selected.secret,nonce:nonce,role:"worker",server:true)) else { throw ActionFailure.unavailable }
        let id = UUID().uuidString
        dispatched = true
        try send(.object(["kind":.string("call"),"id":.string(id),"request":request]))
        let result = try receive()
        guard result.object?["kind"]?.string == "result", result.object?["id"]?.string == id, let value = result.object?["result"] else { throw ActionFailure.uncertain }
        return value
        } catch { throw dispatched ? ActionFailure.uncertain : ActionFailure.unavailable }
    }
    static func status() -> BBCJSONValue {
        (try? request(.object(["method":.string("bridge.status")]))) ?? .object(["ready":.bool(false),"reason":.string("native_bridge_not_started"),"capabilities":.array([])])
    }
}
