import Foundation
import XCTest
import BBCNativeCore

private let scopedChat = "any;-;remote@example.test"
@objc private final class IncomingHandle: NSObject { @objc var ID = "remote@example.test" }
@objc private final class IncomingMessage: NSObject {
    @objc var isTypingMessage = true
    @objc var isCancelTypingMessage = false
    @objc var isFromMe = false
    @objc var sender = IncomingHandle()
    @objc var time = Date()
    @objc var guid = "typing-source"
}
@objc private final class IncomingChat: NSObject {
    nonisolated(unsafe) static var current = IncomingChat()
    @objc var guid = scopedChat
    @objc var isLastMessageTypingIndicator = true
    @objc var lastIncomingMessage: IncomingMessage? = IncomingMessage()
    @objc var participants = [IncomingHandle()]
}
@objc private final class IncomingRegistry: NSObject {
    @objc class func sharedInstance() -> IncomingRegistry { IncomingRegistry() }
    @objc(existingChatWithGUID:) func chat(_ guid: String) -> IncomingChat? { guid == scopedChat ? .current : nil }
}

final class IncomingTypingTests: XCTestCase {
    private let resolver: BBCNativeClassResolver = { name in
        ["IMChat":IncomingChat.self,"IMMessage":IncomingMessage.self,"IMHandle":IncomingHandle.self,"IMChatRegistry":IncomingRegistry.self][name]
    }
    private func observe(_ chat: String = scopedChat) -> [String:Any] {
        var result: [String:Any] = [:]
        BBCNativePerform(["method":"typing.observe","chat_guid":chat],resolver) { result = $0 }
        return result
    }
    override func setUp() { IncomingChat.current = IncomingChat() }
    func testScopedIncomingSignalContainsOnlyIdentityAndDeadline() {
        XCTAssertTrue(BBCNativeCapabilities(resolver).contains("incoming-typing"))
        let result = observe()
        XCTAssertEqual(result["ok"] as? Bool,true)
        XCTAssertEqual(result["active"] as? Bool,true)
        XCTAssertEqual(result["sender_handle"] as? String,"remote@example.test")
        XCTAssertEqual(Set(result.keys),["ok","active","chat_guid","sender_handle","source_guid","expires_at","observation"])
        XCTAssertLessThanOrEqual(result["expires_at"] as! Double,Date().addingTimeInterval(8).timeIntervalSince1970*1000)
    }
    func testCancellationOwnTypingMissingAndWrongChatFailClosed() {
        IncomingChat.current.lastIncomingMessage?.isCancelTypingMessage = true
        XCTAssertEqual(observe()["active"] as? Bool,false)
        IncomingChat.current.lastIncomingMessage?.isCancelTypingMessage = false
        IncomingChat.current.lastIncomingMessage?.isFromMe = true
        XCTAssertEqual(observe()["active"] as? Bool,false)
        IncomingChat.current.lastIncomingMessage = nil
        XCTAssertEqual(observe()["active"] as? Bool,false)
        XCTAssertEqual(observe("any;-;other@example.test")["ok"] as? Bool,false)
        XCTAssertEqual(observe("any;+;group")["ok"] as? Bool,false)
    }
    func testSenderMustMatchSoleNativeParticipantAndDateCannotBeFuture() {
        IncomingChat.current.lastIncomingMessage?.sender.ID = "unrelated@example.test"
        XCTAssertEqual(observe()["ok"] as? Bool,false)
        IncomingChat.current = IncomingChat()
        IncomingChat.current.lastIncomingMessage?.time = Date().addingTimeInterval(30)
        XCTAssertEqual(observe()["ok"] as? Bool,false)
        IncomingChat.current = IncomingChat()
        IncomingChat.current.participants.append(IncomingHandle())
        XCTAssertEqual(observe()["ok"] as? Bool,false)
    }
    func testOldSignalDeadlineDoesNotRenewWithPolling() {
        IncomingChat.current.lastIncomingMessage?.time = Date().addingTimeInterval(-10)
        let first = observe()["expires_at"] as! Double
        XCTAssertLessThan(first,Date().timeIntervalSince1970*1000)
        XCTAssertEqual(observe()["expires_at"] as? Double,first)
    }
}
