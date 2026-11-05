import Foundation
import XCTest
import Darwin
import BBCClient
@testable import BBCMessagesActions

private let shortTimes = BridgeBroker.Configuration(commandDeadline:0.4,authenticationDeadline:0.4)

@MainActor final class BridgeIPCTests: XCTestCase {
    func testRoleAndDirectionProofsCannotBeInterchanged() throws {
        let secret = try BridgeWire.secret(), nonce = UUID().uuidString
        let worker = BridgeWire.proof(secret:secret,nonce:nonce,role:"worker",server:false)
        XCTAssertNotEqual(worker,BridgeWire.proof(secret:secret,nonce:nonce,role:"helper",server:false))
        XCTAssertNotEqual(worker,BridgeWire.proof(secret:secret,nonce:nonce,role:"worker",server:true))
        XCTAssertFalse(BridgeWire.equal("", ""))
    }
    func testNoHelperIsReportedUnavailableWithoutDispatch() async throws {
        try await BridgeFixtureHarness.run { h in
            let observed = try await h.status()
            XCTAssertEqual(observed.object?["ready"]?.bool,false)
            let endpoint = h.endpoint
            let result = try await Task.detached { try NativeBridgeClient.request(.object(["method":.string("tapback")]),endpoint:endpoint,timeout:10) }.value
            XCTAssertEqual(result.object?["uncertain"]?.bool,false)
            XCTAssertEqual(result.object?["failure_code"]?.string,"native_bridge_unavailable")
        }
    }
    func testWrongWorkerSecretCannotAuthenticate() async throws {
        try await BridgeFixtureHarness.run { h in
            let wrong = BridgeWire.Endpoint(version:1,port:h.endpoint.port,secret:try BridgeWire.secret(),ownerPID:getpid())
            do { _ = try await Task.detached { try NativeBridgeClient.request(.object(["method":.string("bridge.status")]),endpoint:wrong,timeout:10) }.value; XCTFail("Unauthenticated caller") }
            catch { XCTAssertEqual(error as? ActionFailure,.unavailable) }
        }
    }
    func testAuthenticatedCommandIsForwardedOnceAndResultIsCorrelated() async throws {
        try await BridgeFixtureHarness.run { h in
            let helper = try await FixtureHelper(harness:h)
            let endpoint = h.endpoint
            let call = Task.detached { try NativeBridgeClient.request(.object(["method":.string("tapback")]),endpoint:endpoint,timeout:10) }
            let command = try await helper.nextCommand()
            XCTAssertEqual(command.method,"tapback")
            try await helper.reply(id:command.id,.object(["ok":.bool(true),"guid":.string("fixture-result")]))
            // A result for an unknown id cannot poison the helper or trigger dispatch.
            try await helper.reply(id:UUID().uuidString)
            let result = try await call.value
            XCTAssertEqual(result.object?["guid"]?.string,"fixture-result")
            try await helper.expectNoStrayCommand(harness:h)
            XCTAssertEqual(helper.commands.count,2)
            let observed = try await h.status()
            XCTAssertEqual(observed.object?["capabilities"],.array([.string("tapback"),.string("read"),.string("reply")]))
        }
    }
    func testDisconnectAfterForwardingIsUncertainAndNeverReplayed() async throws {
        try await BridgeFixtureHarness.run { h in
            let helper = try await FixtureHelper(harness:h), worker = try await FixtureWorker(harness:h), id = UUID().uuidString
            try await worker.call(id:id)
            _ = try await helper.nextCommand(); helper.peer.close()
            let result = try await worker.result()
            XCTAssertEqual(result.object?["uncertain"]?.bool,true)
            XCTAssertEqual(result.object?["failure_code"]?.string,"native_bridge_disconnected")
            let observed = try await h.status()
            XCTAssertEqual(observed.object?["ready"]?.bool,false)
            XCTAssertEqual(helper.commands.count,1)
        }
    }
    func testDuplicatePendingIDIsRejectedWithoutPoisoningOriginalTransaction() async throws {
        try await BridgeFixtureHarness.run { h in
            let helper = try await FixtureHelper(harness:h), original = try await FixtureWorker(harness:h), duplicate = try await FixtureWorker(harness:h), id = UUID().uuidString
            try await original.call(id:id)
            _ = try await helper.nextCommand()
            try await duplicate.call(id:id)
            let rejected = try await duplicate.result()
            XCTAssertEqual(rejected.object?["uncertain"]?.bool,false)
            XCTAssertEqual(rejected.object?["failure_code"]?.string,"native_bridge_unavailable")
            try await helper.reply(id:id,.object(["ok":.bool(true),"guid":.string("original")]))
            let result = try await original.result()
            XCTAssertEqual(result.object?["guid"]?.string,"original")
            try await helper.expectNoStrayCommand(harness:h)
            XCTAssertEqual(helper.commands.count,2)
        }
    }
    func testStatusCallCannotCompleteAnotherWorkersPendingID() async throws {
        try await BridgeFixtureHarness.run { h in
            let helper = try await FixtureHelper(harness:h), original = try await FixtureWorker(harness:h)
            let id = UUID().uuidString
            try await original.call(id:id)
            _ = try await helper.nextCommand()
            let duplicate = try await FixtureWorker(harness:h)
            try await duplicate.call(id:id,method:"bridge.status")
            let rejected = try await duplicate.result()
            XCTAssertEqual(rejected.object?["failure_code"]?.string,"native_bridge_unavailable")
            try await helper.reply(id:id,.object(["ok":.bool(true),"guid":.string("original")]))
            let result = try await original.result()
            XCTAssertEqual(result.object?["guid"]?.string,"original")
            try await helper.expectNoStrayCommand(harness:h)
            XCTAssertEqual(helper.commands.count,2)
        }
    }
    func testSilentHelperTimesOutUncertainWithOneCommand() async throws {
        try await BridgeFixtureHarness.run(configuration:shortTimes) { h in
            let helper = try await FixtureHelper(harness:h), worker = try await FixtureWorker(harness:h)
            try await worker.call(id:UUID().uuidString)
            _ = try await helper.nextCommand()
            let result = try await worker.result()
            XCTAssertEqual(result.object?["uncertain"]?.bool,true)
            XCTAssertEqual(result.object?["failure_code"]?.string,"native_bridge_timeout")
            try await helper.expectNoStrayCommand(harness:h)
            XCTAssertEqual(helper.commands.count,2)
        }
    }
    func testLateResultAfterExpiryIsIgnoredAndNewRequestSucceeds() async throws {
        try await BridgeFixtureHarness.run(configuration:shortTimes) { h in
            let helper = try await FixtureHelper(harness:h), worker = try await FixtureWorker(harness:h), expired = UUID().uuidString
            try await worker.call(id:expired)
            _ = try await helper.nextCommand()
            let timeout = try await worker.result()   // broker expired the transaction before any helper answer
            XCTAssertEqual(timeout.object?["failure_code"]?.string,"native_bridge_timeout")
            try await helper.reply(id:expired,.object(["ok":.bool(true),"guid":.string("late")]))   // actually late
            let next = try await FixtureWorker(harness:h), fresh = UUID().uuidString
            try await next.call(id:fresh)
            let command = try await helper.nextCommand()
            XCTAssertEqual(command.id,fresh)
            try await helper.reply(id:fresh,.object(["ok":.bool(true),"guid":.string("fresh")]))
            let result = try await next.result()
            XCTAssertEqual(result.object?["guid"]?.string,"fresh")
            // The expired id can never be redispatched.
            let again = try await FixtureWorker(harness:h)
            try await again.call(id:expired)
            let rejected = try await again.result()
            XCTAssertEqual(rejected.object?["failure_code"]?.string,"native_bridge_unavailable")
            try await helper.expectNoStrayCommand(harness:h)
            XCTAssertEqual(helper.commands.count,3)
        }
    }
    func testDuplicateResultsAreIgnored() async throws {
        try await BridgeFixtureHarness.run { h in
            let helper = try await FixtureHelper(harness:h), worker = try await FixtureWorker(harness:h), id = UUID().uuidString
            try await worker.call(id:id)
            _ = try await helper.nextCommand()
            try await helper.reply(id:id,.object(["ok":.bool(true),"guid":.string("first")]))
            try await helper.reply(id:id,.object(["ok":.bool(true),"guid":.string("second")]))
            let result = try await worker.result()
            XCTAssertEqual(result.object?["guid"]?.string,"first")
            try await helper.expectNoStrayCommand(harness:h)
            XCTAssertEqual(helper.commands.count,2)
        }
    }
    func testSecondHelperIsRejectedAndFirstKeepsServing() async throws {
        try await BridgeFixtureHarness.run { h in
            let helper = try await FixtureHelper(harness:h)
            let second = try FixturePeer(port:h.endpoint.port,role:"helper"), secret = h.helperSecret
            let authenticated = try await Task.detached { try second.authenticate(secret:secret) }.value
            XCTAssertFalse(authenticated)
            let closed = await second.asyncRead()
            XCTAssertEqual(closed,.closed)
            let observed = try await h.status()
            XCTAssertEqual(observed.object?["ready"]?.bool,true)
            try await helper.expectNoStrayCommand(harness:h)
            XCTAssertEqual(helper.commands.count,1)
        }
    }
    func testClientCapacityRejectsExtraConnectionsAndKeepsExistingRequest() async throws {
        var limits = BridgeBroker.Configuration.production; limits.maximumClients = 4
        try await BridgeFixtureHarness.run(configuration:limits) { h in
            let helper = try await FixtureHelper(harness:h), worker = try await FixtureWorker(harness:h), id = UUID().uuidString
            try await worker.call(id:id)
            _ = try await helper.nextCommand()
            let idle = [try FixturePeer(port:h.endpoint.port,role:"worker"),try FixturePeer(port:h.endpoint.port,role:"worker")]  // fills 4/4 (helper, worker, 2 idle)
            for peer in idle { guard case .packet = await peer.asyncRead() else { return XCTFail("challenge expected") } }
            let rejected = try FixturePeer(port:h.endpoint.port,role:"worker")
            let outcome = await rejected.asyncRead()
            XCTAssertEqual(outcome,.closed)
            try await helper.reply(id:id,.object(["ok":.bool(true),"guid":.string("kept")]))
            let result = try await worker.result()
            XCTAssertEqual(result.object?["guid"]?.string,"kept")
            idle.forEach { $0.close() }
        }
    }
    func testPendingCapacityRejectsExtraRequestAndPreservesExistingOnes() async throws {
        var limits = BridgeBroker.Configuration.production; limits.maximumPending = 2
        try await BridgeFixtureHarness.run(configuration:limits) { h in
            let helper = try await FixtureHelper(harness:h)
            let a = try await FixtureWorker(harness:h), b = try await FixtureWorker(harness:h), c = try await FixtureWorker(harness:h)
            let ids = [UUID().uuidString,UUID().uuidString,UUID().uuidString]
            try await a.call(id:ids[0]); _ = try await helper.nextCommand()
            try await b.call(id:ids[1]); _ = try await helper.nextCommand()
            try await c.call(id:ids[2])
            let rejected = try await c.result()
            XCTAssertEqual(rejected.object?["uncertain"]?.bool,false)
            XCTAssertEqual(rejected.object?["failure_code"]?.string,"native_bridge_unavailable")
            try await helper.reply(id:ids[0],.object(["ok":.bool(true),"guid":.string("a")]))
            try await helper.reply(id:ids[1],.object(["ok":.bool(true),"guid":.string("b")]))
            let ra = try await a.result(), rb = try await b.result()
            XCTAssertEqual(ra.object?["guid"]?.string,"a"); XCTAssertEqual(rb.object?["guid"]?.string,"b")
            try await helper.expectNoStrayCommand(harness:h)
            XCTAssertEqual(helper.commands.count,3)
        }
    }
    func testUnauthenticatedConnectionIsClosedAfterAuthenticationDeadline() async throws {
        try await BridgeFixtureHarness.run(configuration:shortTimes) { h in
            let idle = try FixturePeer(port:h.endpoint.port,role:"worker")
            guard case .packet(let challenge) = await idle.asyncRead() else { return XCTFail("challenge expected") }
            XCTAssertEqual(challenge.object?["kind"]?.string,"challenge")
            let outcome = await idle.asyncRead()
            XCTAssertEqual(outcome,.closed)
        }
    }
    func testMalformedHelperTrafficDisconnectsHelperAndFailsPendingUncertain() async throws {
        for garbage in [Data("not json\n".utf8), try BridgeWire.frame(.object(["kind":.string("result")]))] {
            try await BridgeFixtureHarness.run { h in
                let helper = try await FixtureHelper(harness:h), worker = try await FixtureWorker(harness:h)
                try await worker.call(id:UUID().uuidString)
                _ = try await helper.nextCommand()
                try helper.peer.sendRaw(garbage)
                let result = try await worker.result()
                XCTAssertEqual(result.object?["uncertain"]?.bool,true)
                XCTAssertEqual(result.object?["failure_code"]?.string,"native_bridge_disconnected")
                let closed = await helper.peer.asyncRead()
                XCTAssertEqual(closed,.closed)
                let observed = try await h.status()
                XCTAssertEqual(observed.object?["ready"]?.bool,false)
                XCTAssertEqual(helper.commands.count,1)
            }
        }
    }
    func testShutdownIsAwaitableClosesConnectionsAndRemovesOwnedEndpoint() async throws {
        try await BridgeFixtureHarness.run { h in
            let helper = try await FixtureHelper(harness:h)
            XCTAssertTrue(FileManager.default.fileExists(atPath:h.endpointFile.path))
            await h.broker.shutdown()
            XCTAssertFalse(FileManager.default.fileExists(atPath:h.endpointFile.path))
            let closed = await helper.peer.asyncRead()
            XCTAssertEqual(closed,.closed)
            XCTAssertThrowsError(try FixturePeer(port:h.endpoint.port,role:"worker",timeout:2))
            await h.broker.shutdown()   // idempotent
        }
    }
    func testShutdownDoesNotRemoveEndpointOwnedBySomeoneElse() async throws {
        try await BridgeFixtureHarness.run { h in
            let foreign = BridgeWire.Endpoint(version:1,port:h.endpoint.port,secret:try BridgeWire.secret(),ownerPID:getpid())
            try JSONEncoder().encode(foreign).write(to:h.endpointFile,options:.atomic)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:h.endpointFile.path)
            await h.broker.shutdown()
            XCTAssertEqual(try BridgeWire.Endpoint.load(from:h.endpointFile).secret,foreign.secret)
        }
    }
    func testClientRejectsReplyThatIsNotAResultFrame() async throws {
        // Synthetic broker: authenticates the worker, then answers with the right id but the wrong kind.
        let secret = try BridgeWire.secret(), server = socket(AF_INET,SOCK_STREAM,0)
        guard server >= 0 else { return XCTFail("socket") }
        defer { Darwin.close(server) }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0; address.sin_addr.s_addr = inet_addr("127.0.0.1")
        XCTAssertEqual(withUnsafePointer(to:&address){ $0.withMemoryRebound(to:sockaddr.self,capacity:1) { Darwin.bind(server,$0,socklen_t(MemoryLayout<sockaddr_in>.size)) } },0)
        XCTAssertEqual(Darwin.listen(server,1),0)
        var bound = sockaddr_in(), length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to:&bound){ $0.withMemoryRebound(to:sockaddr.self,capacity:1) { getsockname(server,$0,&length) } }
        let endpoint = BridgeWire.Endpoint(version:1,port:UInt16(bigEndian:bound.sin_port),secret:secret,ownerPID:getpid())
        for kind in ["challenge","command","status"] {
            let serving = Task.detached { () -> Void in
                var timeout = timeval(tv_sec:10,tv_usec:0)
                setsockopt(server,SOL_SOCKET,SO_RCVTIMEO,&timeout,socklen_t(MemoryLayout<timeval>.size))
                let connection = accept(server,nil,nil); guard connection >= 0 else { return }
                let peer = FixturePeer(adopting:connection)
                let nonce = UUID().uuidString
                try peer.send(.object(["kind":.string("challenge"),"nonce":.string(nonce)]))
                _ = try peer.receive()
                try peer.send(.object(["kind":.string("authenticated"),"proof":.string(BridgeWire.proof(secret:secret,nonce:nonce,role:"worker",server:true))]))
                let call = try peer.receive()
                try peer.send(.object(["kind":.string(kind),"id":call.object!["id"]!,"result":.object(["ok":.bool(true)])]))
                peer.close()
            }
            do { _ = try await Task.detached { try NativeBridgeClient.request(.object(["method":.string("tapback")]),endpoint:endpoint,timeout:10) }.value; XCTFail("accepted reply kind \(kind)") }
            catch { XCTAssertEqual(error as? ActionFailure,.uncertain) }
            try await serving.value
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
