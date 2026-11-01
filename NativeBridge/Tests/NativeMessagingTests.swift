import Foundation
import XCTest
import BBCNativeCore

private let targetID = "11111111-1111-4111-8111-111111111111"
private let sentID = "22222222-2222-4222-8222-222222222222"
private let chatID = "any;-;fixture@example.test"

@objc final class FixtureChat: NSObject {
    nonisolated(unsafe) static var shared = FixtureChat()
    var sends = 0
    var typing = false
    var reads = 0
    var targetAvailable = true
    var loadable = false
    var loads = 0
    var last: FixtureMessage?
    @objc var guid: String { chatID }
    @objc(messageForGUID:) func message(_ guid: String) -> FixtureMessage? {
        guard guid == targetID, targetAvailable else { return nil }
        let value = FixtureMessage(); value.identity = targetID; return value
    }
    @objc(sendMessage:) func send(_ value: FixtureMessage) { sends += 1; last = value }
    @objc(loadMessagesBeforeAndAfterGUID:numberOfMessagesToLoadBeforeGUID:numberOfMessagesToLoadAfterGUID:loadImmediately:threadIdentifier:)
    func load(_ guid: String, before: UInt64, after: UInt64, immediately: Bool, thread: String?) -> Any? {
        loads += 1
        if loadable && guid == targetID && before > 0 && after > 0 {
            DispatchQueue.main.asyncAfter(deadline:.now()+0.05) { FixtureChat.shared.targetAvailable = true }
        }
        return nil
    }
    @objc(sendMessage:onService:) func send(_ value: FixtureMessage, on service: FixtureService) { sends += 1; last = value }
    @objc(setLocalUserIsTyping:) func setTyping(_ value: Bool) { typing = value }
    @objc var localUserIsTyping: Bool { typing }
    @objc func markAllMessagesAsRead() { reads += 1 }
}
@objc final class FixtureService: NSObject {
    @objc class func iMessageService() -> FixtureService { FixtureService() }
}
@objc final class FixtureRegistry: NSObject {
    @objc class func sharedInstance() -> FixtureRegistry { FixtureRegistry() }
    @objc(existingChatWithGUID:) func chat(_ guid: String) -> FixtureChat? { guid == chatID ? FixtureChat.shared : nil }
}
@objc final class FixtureMessage: NSObject {
    var body = NSAttributedString(string:"")
    var association: String?
    var associationType: Int64 = 0
    var emoji: String?
    var thread: String?
    var identity = sentID
    var range = NSRange()
    var summary: NSDictionary = [:]
    @objc var guid: String { identity }
    @objc(_imMessageItem) func item() -> FixtureItem { FixtureItem() }
    // A fixture target has a known native thread. No Apple API is called.
    @objc var threadIdentifier: String { "fixture-native-thread" }
    @objc var associatedMessageEmoji: String? { emoji }
    @objc(_associatedMessageEmoji:) func setEmoji(_ value: String) { emoji = value }
    @objc(instantMessageWithText:flags:threadIdentifier:)
    class func message(_ text: NSAttributedString, flags: UInt64, thread: String?) -> FixtureMessage {
        let value = FixtureMessage(); value.body = text; value.thread = thread; return value
    }
    @objc(initWithSender:time:text:messageSubject:fileTransferGUIDs:flags:error:guid:subject:associatedMessageGUID:associatedMessageType:associatedMessageRange:messageSummaryInfo:)
    init(sender: Any?, time: Any?, text: NSAttributedString, messageSubject: Any?, transfers: Any?, flags: UInt64, error: Any?, guid: Any?, subject: Any?, association: String, type: Int64, range: NSRange, summary: NSDictionary) {
        super.init(); body = text; self.association = association; associationType = type; identity = guid as? String ?? sentID; self.range = range; self.summary = summary
    }
    @objc(initWithSender:time:text:messageSubject:fileTransferGUIDs:flags:error:guid:subject:threadIdentifier:)
    init(sender: Any?, time: Any?, text: NSAttributedString, messageSubject: Any?, transfers: Any?, flags: UInt64, error: Any?, guid: Any?, subject: Any?, thread: String?) {
        super.init(); body = text; self.thread = thread; identity = guid as? String ?? sentID
    }
    override init() { super.init() }
}

@objc final class FixtureItem: NSObject {
    nonisolated(unsafe) static var ambiguous = false
    @objc(_newChatItems) func parts() -> [FixturePart] { Self.ambiguous ? [FixturePart(),FixturePart()] : [FixturePart()] }
}
@objc final class FixturePart: NSObject {
    @objc var index: Int64 { 0 }
    @objc var messagePartRange: NSRange { NSRange(location:4,length:17) }
    @objc var messageSummaryInfo: NSDictionary { ["fixture":"native-summary"] }
}

@objc final class FixtureFailingDetector: NSObject {
    nonisolated(unsafe) static var drainBeforeRaising = false
    @objc class func sharedInstance() -> FixtureFailingDetector { FixtureFailingDetector() }
    @objc(scanMessage:outgoing:waitUntilDone:completionBlock:)
    func scan(_ message: FixtureMessage, outgoing: Bool, waitUntilDone: Bool, completion: @escaping (Int,Bool,Any?) -> Void) {
        completion(0,true,nil)
        if Self.drainBeforeRaising { RunLoop.main.run(until:Date().addingTimeInterval(0.02)) }
        NSException(name:NSExceptionName("FixtureScanFailure"),reason:nil,userInfo:nil).raise()
    }
}

final class NativeMessagingTests: XCTestCase {
    override func setUp() { FixtureChat.shared = FixtureChat(); FixtureItem.ambiguous = false; FixtureFailingDetector.drainBeforeRaising = false }
    private var resolver: BBCNativeClassResolver {
        { name in
            switch name {
            case "IMChat": FixtureChat.self
            case "IMChatRegistry": FixtureRegistry.self
            case "IMMessage": FixtureMessage.self
            case "IMService": FixtureService.self
            default: nil
            }
        }
    }
    private func perform(_ method: String, fields: [String:Any] = [:]) -> [String:Any] {
        var request: [String:Any] = ["method":method,"chat_guid":chatID,"message_guid":targetID,"typing_id":targetID,"deadline":(Date().timeIntervalSince1970+5)*1000]
        request.merge(fields) { _,new in new }
        // The exact target's guid must differ from the newly created message.
        var result: [String:Any] = [:]
        let completed = expectation(description:"native result")
        BBCNativePerform(request,resolver) { result = $0; completed.fulfill() }
        wait(for:[completed],timeout:6)
        return result
    }
    func testUnknownChatAndMessageCannotDispatch() {
        XCTAssertEqual(perform("tapback",fields:["chat_guid":"any;-;other@example.test"])["ok"] as? Bool,false)
        XCTAssertEqual(perform("tapback",fields:["message_guid":sentID])["ok"] as? Bool,false)
        XCTAssertEqual(FixtureChat.shared.sends,0)
    }
    func testExpiredTypingCannotStartAnIndicator() {
        XCTAssertEqual(perform("typing.start",fields:["deadline":0])["ok"] as? Bool,false)
        XCTAssertFalse(FixtureChat.shared.typing)
    }
    func testEvictedMessageLoadsOnceBeforeOneExactEmojiDispatch() {
        FixtureChat.shared.targetAvailable = false
        FixtureChat.shared.loadable = true
        let result = perform("tapback",fields:["reaction":"🦥","associated_message_guid":"p:0/"+targetID])
        XCTAssertEqual(result["ok"] as? Bool,true)
        XCTAssertEqual(FixtureChat.shared.loads,1)
        XCTAssertEqual(FixtureChat.shared.sends,1)
        XCTAssertEqual(FixtureChat.shared.last?.emoji,"🦥")
        XCTAssertEqual(FixtureChat.shared.last?.association,"p:0/"+targetID)
    }
    func testTypingCleanupSurvivesAnchorEviction() {
        FixtureChat.shared.typing = true
        FixtureChat.shared.targetAvailable = false
        XCTAssertEqual(perform("typing.stop")["ok"] as? Bool,true)
        XCTAssertFalse(FixtureChat.shared.typing)
    }
    func testAmbiguousNativePartDoesNotSendAReaction() {
        FixtureItem.ambiguous = true
        XCTAssertEqual(perform("tapback",fields:["reaction":"🦥","associated_message_guid":"p:0/"+targetID])["ok"] as? Bool,false)
        XCTAssertEqual(FixtureChat.shared.sends,0)
    }
    func testUnsupportedSelectorsFailWithoutDispatch() {
        var result: [String:Any] = [:]
        BBCNativePerform(["method":"reply","chat_guid":chatID,"message_guid":targetID,"text":"fixture"],{ _ in nil }) { result = $0 }
        XCTAssertEqual(result["uncertain"] as? Bool,false)
        XCTAssertEqual(FixtureChat.shared.sends,0)
    }
    func testCapabilitiesReflectAvailableNativeMethods() {
        let methods = BBCNativeCapabilities(resolver)
        XCTAssertTrue(methods.contains("custom-emoji")); XCTAssertFalse(methods.contains("link"))
    }
    func testCustomEmojiAddAndRemovePreserveExactUnicodeAndTarget() {
        for emoji in ["🦥","👍🏽","👩‍💻"] {
            for remove in [false,true] {
                let result = perform("tapback",fields:["reaction":emoji,"remove":remove,"associated_message_guid":"p:0/"+targetID])
                XCTAssertEqual(result["ok"] as? Bool,true)
                XCTAssertEqual(FixtureChat.shared.last?.emoji,emoji)
                XCTAssertEqual(FixtureChat.shared.last?.association,"p:0/"+targetID)
                XCTAssertEqual(FixtureChat.shared.last?.associationType,remove ? 3006 : 2006)
                XCTAssertEqual(FixtureChat.shared.last?.range,NSRange(location:4,length:17))
                XCTAssertEqual(FixtureChat.shared.last?.summary,["fixture":"native-summary"])
            }
        }
        XCTAssertEqual(FixtureChat.shared.sends,6)
    }
    func testClassicRemovalAndBalloonTargetAreExplicit() {
        XCTAssertEqual(perform("tapback",fields:["reaction":"love","remove":true,"associated_message_guid":"bp:"+targetID])["ok"] as? Bool,true)
        XCTAssertEqual(FixtureChat.shared.last?.associationType,3000)
        XCTAssertEqual(FixtureChat.shared.last?.association,"bp:"+targetID)
    }
    func testWrongAssociationCannotSend() {
        XCTAssertEqual(perform("tapback",fields:["reaction":"🦥","associated_message_guid":"p:0/"+sentID])["ok"] as? Bool,false)
        XCTAssertEqual(FixtureChat.shared.sends,0)
    }
    func testReplyUsesTheExistingNativeThreadIdentity() {
        XCTAssertEqual(perform("reply",fields:["text":"fixture reply"])["ok"] as? Bool,true)
        XCTAssertEqual(FixtureChat.shared.last?.thread,"fixture-native-thread")
        XCTAssertEqual(FixtureChat.shared.last?.body.string,"fixture reply")
        XCTAssertEqual(FixtureChat.shared.sends,1)
    }
    func testReadAndTypingCallNativeChatWithoutSendingAMessage() {
        XCTAssertEqual(perform("typing.start")["ok"] as? Bool,true)
        XCTAssertTrue(FixtureChat.shared.typing)
        XCTAssertEqual(perform("typing.stop")["ok"] as? Bool,true)
        XCTAssertFalse(FixtureChat.shared.typing)
        XCTAssertEqual(perform("read")["ok"] as? Bool,true)
        XCTAssertEqual(FixtureChat.shared.reads,1); XCTAssertEqual(FixtureChat.shared.sends,0)
    }
    func testScannerCallbackThenExceptionCannotSendAfterNotDispatchedFailure() {
        let base = resolver
        var receipt: [String:Any] = [:], completions = 0
        BBCNativePerform(["method":"link","chat_guid":chatID,"message_guid":targetID,"text":"https://example.test"],{ name in
            name == "IMDDController" ? FixtureFailingDetector.self : base(name)
        }) {
            receipt = $0; completions += 1
        }
        XCTAssertEqual(receipt["ok"] as? Bool,false)
        XCTAssertEqual(receipt["uncertain"] as? Bool,false)
        // Drain the exact callback queued before the scanner raised.
        let drained = expectation(description:"queued scanner callback drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for:[drained],timeout:1)
        XCTAssertEqual(completions,1)
        XCTAssertEqual(FixtureChat.shared.sends,0)
    }
    func testScannerExceptionAfterReentrantSendPreservesItsOnlyReceipt() {
        FixtureFailingDetector.drainBeforeRaising = true
        let base = resolver
        var receipts: [[String:Any]] = []
        BBCNativePerform(["method":"link","chat_guid":chatID,"message_guid":targetID,"text":"https://example.test"],{ name in
            name == "IMDDController" ? FixtureFailingDetector.self : base(name)
        }) { receipts.append($0) }
        XCTAssertEqual(FixtureChat.shared.sends,1)
        XCTAssertEqual(receipts.count,1)
        XCTAssertEqual(receipts.first?["ok"] as? Bool,true)
    }
}
