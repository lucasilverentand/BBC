import Foundation
import XCTest
import Darwin
import BBCClient
@testable import BBCMessagesActions

private final class FixtureBridgePeer: @unchecked Sendable {
    private var fd: Int32
    private var buffer = Data()
    init(port: UInt16) throws {
        fd = socket(AF_INET,SOCK_STREAM,0)
        guard fd >= 0 else { throw ActionFailure.unavailable }
        var timeout = timeval(tv_sec:3,tv_usec:0), noSignal: Int32 = 1
        setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&timeout,socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&noSignal,socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian; address.sin_addr.s_addr = inet_addr("127.0.0.1")
        guard withUnsafePointer(to:&address,{ $0.withMemoryRebound(to:sockaddr.self,capacity:1) { connect(fd,$0,socklen_t(MemoryLayout<sockaddr_in>.size)) } }) == 0 else { Darwin.close(fd); fd = -1; throw ActionFailure.unavailable }
    }
    deinit { close() }
    func close() { if fd >= 0 { Darwin.close(fd); fd = -1 } }
    func send(_ packet: BBCJSONValue) throws {
        let data = try BridgeWire.frame(packet)
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd,bytes.baseAddress!.advanced(by:offset),bytes.count-offset)
                guard count > 0 else { throw ActionFailure.unavailable }; offset += count
            }
        }
    }
    func receive() throws -> BBCJSONValue {
        while buffer.firstIndex(of:10) == nil {
            var bytes = [UInt8](repeating:0,count:8192)
            let count = Darwin.read(fd,&bytes,bytes.count)
            guard count > 0, buffer.count + count <= BridgeWire.maximumFrame else { throw ActionFailure.unavailable }
            buffer.append(contentsOf:bytes.prefix(count))
        }
        let end = buffer.firstIndex(of:10)!, data = Data(buffer[..<end]); buffer.removeSubrange(...end)
        return try JSONDecoder().decode(BBCJSONValue.self,from:data)
    }
    func authenticate(_ secret: String) throws {
        let nonce = try receive().object!["nonce"]!.string!
        try send(.object(["kind":.string("authenticate"),"role":.string("helper"),"proof":.string(BridgeWire.proof(secret:secret,nonce:nonce,role:"helper",server:false))]))
        let reply = try receive()
        guard reply.object?["proof"]?.string == BridgeWire.proof(secret:secret,nonce:nonce,role:"helper",server:true) else { throw ActionFailure.unavailable }
        try send(.object(["kind":.string("hello"),"version":.number(1),"capabilities":.array([.string("tapback"),.string("arbitrary-code")])]))
    }
}

@MainActor final class BridgeIPCTests: XCTestCase {
    private func fixture(_ run: (BridgeWire.Endpoint,String) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let secret = try BridgeWire.secret(), broker = try BridgeBroker(directory:directory,helperSecret:secret)
        defer { broker.stop(); try? FileManager.default.removeItem(at:directory) }
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            broker.start { port,_ in if let port { continuation.resume(returning:port) } else { continuation.resume(throwing:ActionFailure.unavailable) } }
        }
        let endpoint = try BridgeWire.Endpoint.load(from:directory.appendingPathComponent("endpoint.json"))
        XCTAssertEqual(endpoint.port,port)
        try await run(endpoint,secret)
    }
    private func status(_ endpoint: BridgeWire.Endpoint) async throws -> BBCJSONValue {
        try await Task.detached { try NativeBridgeClient.request(.object(["method":.string("bridge.status")]),endpoint:endpoint) }.value
    }
    private func ready(_ endpoint: BridgeWire.Endpoint) async throws {
        for _ in 0..<20 {
            if try await status(endpoint).object?["ready"]?.bool == true { return }
            try await Task.sleep(for:.milliseconds(50))
        }
        throw ActionFailure.unavailable
    }
    func testRoleAndDirectionProofsCannotBeInterchanged() throws {
        let secret = try BridgeWire.secret(), nonce = UUID().uuidString
        let worker = BridgeWire.proof(secret:secret,nonce:nonce,role:"worker",server:false)
        XCTAssertNotEqual(worker,BridgeWire.proof(secret:secret,nonce:nonce,role:"helper",server:false))
        XCTAssertNotEqual(worker,BridgeWire.proof(secret:secret,nonce:nonce,role:"worker",server:true))
        XCTAssertFalse(BridgeWire.equal("", ""))
    }
    func testNoHelperIsReportedUnavailableWithoutDispatch() async throws {
        try await fixture { endpoint,_ in
            let observed = try await status(endpoint)
            XCTAssertEqual(observed.object?["ready"]?.bool,false)
            let result = try await Task.detached { try NativeBridgeClient.request(.object(["method":.string("tapback")]),endpoint:endpoint) }.value
            XCTAssertEqual(result.object?["uncertain"]?.bool,false)
            XCTAssertEqual(result.object?["failure_code"]?.string,"native_bridge_unavailable")
        }
    }
    func testWrongWorkerSecretCannotAuthenticate() async throws {
        try await fixture { endpoint,_ in
            let wrong = BridgeWire.Endpoint(version:1,port:endpoint.port,secret:try BridgeWire.secret(),ownerPID:getpid())
            do { _ = try await status(wrong); XCTFail("Unauthenticated caller") }
            catch { XCTAssertEqual(error as? ActionFailure,.unavailable) }
        }
    }
    func testAuthenticatedCommandIsForwardedOnceAndResultIsCorrelated() async throws {
        try await fixture { endpoint,secret in
            let peer = try FixtureBridgePeer(port:endpoint.port); defer { peer.close() }
            try peer.authenticate(secret); try await ready(endpoint)
            let response = Task.detached {
                let packet = try peer.receive()
                XCTAssertEqual(packet.object?["request"]?.object?["method"]?.string,"tapback")
                try peer.send(.object(["kind":.string("result"),"id":packet.object!["id"]!,"result":.object(["ok":.bool(true),"guid":.string("fixture-result")])]))
                // A delayed response for an expired transaction cannot poison
                // the live helper connection or trigger another dispatch.
                try peer.send(.object(["kind":.string("result"),"id":.string(UUID().uuidString),"result":.object(["ok":.bool(true)])]))
            }
            let result = try await Task.detached { try NativeBridgeClient.request(.object(["method":.string("tapback")]),endpoint:endpoint) }.value
            try await response.value
            XCTAssertEqual(result.object?["guid"]?.string,"fixture-result")
            let observed = try await status(endpoint)
            XCTAssertEqual(observed.object?["capabilities"],.array([.string("tapback")]))
        }
    }
    func testDisconnectAfterForwardingIsUncertainAndNeverReplayed() async throws {
        try await fixture { endpoint,secret in
            let peer = try FixtureBridgePeer(port:endpoint.port)
            try peer.authenticate(secret); try await ready(endpoint)
            let disconnect = Task.detached { _ = try peer.receive(); peer.close() }
            let result = try await Task.detached { try NativeBridgeClient.request(.object(["method":.string("tapback")]),endpoint:endpoint) }.value
            try await disconnect.value
            XCTAssertEqual(result.object?["uncertain"]?.bool,true)
            XCTAssertEqual(result.object?["failure_code"]?.string,"native_bridge_disconnected")
            let observed = try await status(endpoint)
            XCTAssertEqual(observed.object?["ready"]?.bool,false)
        }
    }
    func testEndpointRejectsBroadPermissionsAndSymlinks() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        let file = directory.appendingPathComponent("endpoint.json")
        try JSONEncoder().encode(BridgeWire.Endpoint(version:1,port:1234,secret:try BridgeWire.secret(),ownerPID:getpid())).write(to:file)
        try FileManager.default.setAttributes([.posixPermissions:0o644],ofItemAtPath:file.path)
        XCTAssertThrowsError(try BridgeWire.Endpoint.load(from:file))
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
        XCTAssertEqual(try BridgeWire.Endpoint.load(from:file).port,1234)
        let link = directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at:link,withDestinationURL:file)
        XCTAssertThrowsError(try BridgeWire.Endpoint.load(from:link))
    }
    func testUnknownSecurityConfigurationNeverEnablesTheBridge() {
        XCTAssertEqual(BridgeReadiness.parseSIP("System Integrity Protection status: enabled."),.enabled)
        XCTAssertEqual(BridgeReadiness.parseSIP("System Integrity Protection status: disabled."),.disabled)
        XCTAssertFalse(BridgeReadiness(sip:.unknown,libraryValidationDisabled:true).allowed)
        XCTAssertFalse(BridgeReadiness(sip:.disabled,libraryValidationDisabled:false).allowed)
    }
}
