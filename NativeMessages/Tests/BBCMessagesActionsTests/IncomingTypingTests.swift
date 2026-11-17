import Foundation
import XCTest
import BBCClient
import Network
@testable import BBCMessagesActions

final class IncomingTypingLeaseTests: XCTestCase {
    private let chat = "any;-;remote@example.test"
    private func sample(source: String = "source", expires: Double = 9000) -> BBCJSONValue {
        .object(["ok":.bool(true),"active":.bool(true),"chat_guid":.string(chat),"sender_handle":.string("remote@example.test"),"source_guid":.string(source),"expires_at":.number(expires)])
    }
    func testStartStopExpiryAreEphemeralAndNeverRenewAStaleSample() {
        var lease = IncomingTypingLease()
        let start = String(decoding:lease.update(sample(),chat:chat,now:1000),as:UTF8.self)
        XCTAssertTrue(start.contains("typing.started")); XCTAssertFalse(start.contains("\nid:"))
        XCTAssertFalse(start.hasPrefix("id:")); XCTAssertFalse(start.contains("source_guid"))
        XCTAssertTrue(lease.update(sample(),chat:chat,now:2000).isEmpty)
        let expired = String(decoding:lease.update(nil,chat:chat,now:9000),as:UTF8.self)
        XCTAssertTrue(expired.contains("typing.expired"))
        XCTAssertTrue(lease.update(sample(),chat:chat,now:9001).isEmpty)
        _ = lease.update(sample(source:"new",expires:14000),chat:chat,now:10000)
        let stop = String(decoding:lease.update(.object(["ok":.bool(true),"active":.bool(false),"chat_guid":.string(chat)]),chat:chat,now:11000),as:UTF8.self)
        XCTAssertTrue(stop.contains("typing.stopped"))
    }
    func testWrongScopeAndOverlongLeaseCannotCreateEvents() {
        var lease = IncomingTypingLease()
        XCTAssertTrue(lease.update(sample(),chat:"any;-;other@example.test",now:1000).isEmpty)
        XCTAssertTrue(lease.update(sample(expires:999999),chat:chat,now:1000).isEmpty)
        XCTAssertTrue(lease.update(.object(["ok":.bool(false)]),chat:chat,now:1000).isEmpty)
    }
    @MainActor func testUnauthorizedOrUnscopedStreamsDoNotTouchNativeObserver() async throws {
        actor Counter { var value = 0; func record() { value += 1 } }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let keys = try APIKeyStore(directory:directory), token = try keys.create(name:"fixture",access:.readOnly)
        let counter = Counter()
        let router = APIRouter(keys:keys,observeTyping:{ _ in await counter.record(); return nil }) { _ in .null }
        let peer = Network.NWEndpoint.hostPort(host:.ipv4(.loopback),port:1)
        _ = await router.incomingTyping(headers:["x-bbc-typing-chat":chat],peer:peer)
        _ = await router.incomingTyping(headers:["authorization":"Bearer "+token],peer:peer)
        _ = await router.incomingTyping(headers:["authorization":"Bearer "+token,"x-bbc-typing-chat":"any;+;group"],peer:peer)
        _ = await router.incomingTyping(headers:["authorization":"Bearer "+token,"x-bbc-typing-chat":"any;+;group;-;confused"],peer:peer)
        let untouched = await counter.value
        XCTAssertEqual(untouched,0)
        _ = await router.incomingTyping(headers:["authorization":"Bearer "+token,"x-bbc-typing-chat":chat],peer:peer)
        let observed = await counter.value
        XCTAssertEqual(observed,1)
    }
}
