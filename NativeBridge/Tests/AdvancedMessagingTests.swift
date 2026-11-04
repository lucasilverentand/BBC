import Foundation
import XCTest
import BBCNativeCore

private let advancedChatID = "iMessage;+;fixture-group"
private let advancedMessageID = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"

@objc final class AdvancedHandle: NSObject {
    let address: String
    init(_ address: String) { self.address = address }
}
@objc final class AdvancedAccountController: NSObject {
    @objc class func sharedInstance() -> AdvancedAccountController { AdvancedAccountController() }
    @objc func activeIMessageAccount() -> AdvancedAccount { AdvancedAccount() }
}
@objc final class AdvancedAccount: NSObject {
    @objc(imHandleWithID:) func handle(_ address: String) -> AdvancedHandle { AdvancedHandle(address) }
}
@objc final class AdvancedRegistry: NSObject {
    @objc class func sharedInstance() -> AdvancedRegistry { AdvancedRegistry() }
    @objc(existingChatWithGUID:) func chat(_ guid: String) -> AdvancedChat? { guid == advancedChatID ? AdvancedChat.shared : nil }
    @objc(chatWithHandles:displayName:joinedChatsOnly:findMatchingNamedGroups:lastAddressedHandle:lastAddressedSIMID:needsFreshGroupCreation:)
    func create(_ handles: [AdvancedHandle], name: String?, joined: Bool, matching: Bool, lastHandle: Any?, sim: Any?, fresh: Bool) -> AdvancedChat {
        AdvancedChat.shared.addresses = handles.map(\.address)
        AdvancedChat.shared.name = name ?? ""
        AdvancedChat.shared.fresh = fresh
        return AdvancedChat.shared
    }
}
@objc final class AdvancedChat: NSObject {
    nonisolated(unsafe) static var shared = AdvancedChat()
    var addresses = ["first@example.test","second@example.test"]
    var name = "Fixture"
    var fresh = false
    var left = false
    var allowMembership = true
    var mutationCount = 0
    var photo: String?
    var lastSent: AdvancedMessage?
    let target = AdvancedMessage()
    @objc var guid: String { advancedChatID }
    @objc(_isiMessageService) func iMessage() -> Bool { true }
    @objc var participantHandleIDs: [String] { addresses }
    @objc var displayName: String { name }
    @objc(_setDisplayName:) func rename(_ value: String) { name = value; mutationCount += 1 }
    @objc(canAddParticipants:) func canAdd(_ handles: [AdvancedHandle]) -> Bool { allowMembership }
    @objc(canRemoveParticipants:) func canRemove(_ handles: [AdvancedHandle]) -> Bool { allowMembership && handles.count < addresses.count }
    @objc(inviteParticipants:reason:) func invite(_ handles: [AdvancedHandle], reason: Any?) { addresses += handles.map(\.address); mutationCount += 1 }
    @objc(removeParticipants:reason:) func remove(_ handles: [AdvancedHandle], reason: Any?) { addresses.removeAll { handles.map(\.address).contains($0) }; mutationCount += 1 }
    @objc var canLeaveChat: Bool { !left }
    @objc var hasLeftGroup: Bool { left }
    @objc func leave() { left = true; mutationCount += 1 }
    @objc(sendGroupPhotoUpdate:) func updatePhoto(_ guid: String) { photo = guid; mutationCount += 1 }
    @objc(messageForGUID:) func message(_ guid: String) -> AdvancedMessage? { guid == advancedMessageID ? target : nil }
    @objc(editMessageItem:atPartIndex:withNewPartText:newPartTranslation:backwardCompatabilityText:)
    func edit(_ item: AdvancedItem, index: Int64, text: NSAttributedString, translation: Any?, fallback: NSAttributedString) {
        target.item.part.content = text; target.item.part.edited = true; mutationCount += 1
    }
    @objc(retractMessagePart:) func retract(_ part: AdvancedPart) { part.retracted = true; mutationCount += 1 }
    @objc(sendMessage:onService:) func send(_ message: AdvancedMessage, service: FixtureService) { lastSent = message; mutationCount += 1 }
}
@objc final class AdvancedMessage: NSObject {
    var body = NSAttributedString(string:"")
    var transfers: [String] = []
    var identity = advancedMessageID
    var originalDate = Date().addingTimeInterval(-30)
    var own = true
    let item = AdvancedItem()
    @objc var guid: String { identity }
    @objc var time: Date { originalDate }
    @objc var isFromMe: Bool { own }
    @objc var isSent: Bool { true }
    @objc var expressiveSendStyleID: String?
    @objc(_imMessageItem) func nativeItem() -> AdvancedItem { item }
    @objc(initWithSender:time:text:messageSubject:fileTransferGUIDs:flags:error:guid:subject:threadIdentifier:)
    init(sender: Any?, time: Any?, text: NSAttributedString, subject: Any?, transfers: [String], flags: UInt64, error: Any?, guid: String, extraSubject: Any?, thread: Any?) {
        super.init(); body = text; self.transfers = transfers; identity = guid
    }
    override init() { super.init() }
}
@objc final class AdvancedItem: NSObject {
    let part = AdvancedPart()
    @objc(_newChatItems) func parts() -> [AdvancedPart] { [part] }
    @objc var isFullyRetracted: Bool { part.retracted }
}
@objc final class AdvancedPart: NSObject {
    var edited = false
    var retracted = false
    var eligible = true
    var content = NSAttributedString(string:"Original")
    @objc var index: Int64 { 0 }
    @objc var canEditMessageText: Bool { eligible }
    @objc var canRetract: Bool { eligible }
    @objc var isEditedMessagePart: Bool { edited }
    @objc var isRetractedMessagePart: Bool { retracted }
    @objc var text: NSAttributedString { content }
}
@objc final class AdvancedTransfer: NSObject {
    @objc var guid: String { "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB" }
}
@objc final class AdvancedTransferCenter: NSObject {
    nonisolated(unsafe) static var creations = 0
    @objc class func sharedInstance() -> AdvancedTransferCenter { AdvancedTransferCenter() }
    @objc(createNewOutgoingTransferWithLocalFileURL:) func transfer(_ url: URL) -> AdvancedTransfer { Self.creations += 1; return AdvancedTransfer() }
    @objc(createNewOutgoingGroupPhotoTransferWithLocalFileURL:) func photo(_ url: URL) -> AdvancedTransfer { AdvancedTransfer() }
}

final class AdvancedMessagingTests: XCTestCase {
    override func setUp() { AdvancedChat.shared = AdvancedChat(); AdvancedTransferCenter.creations = 0 }
    private var resolver: BBCNativeClassResolver {
        { name in
            switch name {
            case "IMChat": AdvancedChat.self
            case "IMChatRegistry": AdvancedRegistry.self
            case "IMAccountController": AdvancedAccountController.self
            case "IMMessage": AdvancedMessage.self
            case "IMService": FixtureService.self
            case "IMFileTransferCenter": AdvancedTransferCenter.self
            default: nil
            }
        }
    }
    private func perform(_ method: String, fields: [String:Any] = [:]) -> [String:Any] {
        var request: [String:Any] = ["method":method,"chat_guid":advancedChatID,"message_guid":advancedMessageID]
        request.merge(fields) { _,new in new }
        let done = expectation(description:"native result")
        var result: [String:Any] = [:]
        BBCNativePerform(request,resolver) { result = $0; done.fulfill() }
        wait(for:[done],timeout:4)
        return result
    }
    func testCapabilitiesOnlyExposePresentNativeOperations() {
        let capabilities = BBCNativeCapabilities(resolver)
        XCTAssertTrue(capabilities.contains("groups.create")); XCTAssertTrue(capabilities.contains("messages.multipart"))
        XCTAssertFalse(capabilities.contains("availability"))
    }
    func testCreateRequestsFreshGroupAndConfirmsExactParticipants() {
        let result = perform("groups.create",fields:["participants":["first@example.test","second@example.test"],"name":"BBC fixture"])
        XCTAssertEqual(result["ok"] as? Bool,true)
        XCTAssertEqual(result["chat_guid"] as? String,advancedChatID)
        XCTAssertTrue(AdvancedChat.shared.fresh)
        XCTAssertEqual(AdvancedChat.shared.name,"BBC fixture")
    }
    func testMembershipHonorsNativeEligibilityAndExactRequestedHandles() {
        AdvancedChat.shared.allowMembership = false
        XCTAssertEqual(perform("groups.add",fields:["participants":["third@example.test"]])["uncertain"] as? Bool,false)
        XCTAssertEqual(AdvancedChat.shared.mutationCount,0)
        AdvancedChat.shared.allowMembership = true
        XCTAssertEqual(perform("groups.add",fields:["participants":["third@example.test"]])["ok"] as? Bool,true)
        XCTAssertEqual(perform("groups.remove",fields:["participants":["third@example.test"]])["ok"] as? Bool,true)
        XCTAssertEqual(AdvancedChat.shared.addresses,["first@example.test","second@example.test"])
    }
    func testNameAndLeaveConfirmNativeStateWithoutSendingAMessage() {
        XCTAssertEqual(perform("groups.name",fields:["name":"New fixture name"])["ok"] as? Bool,true)
        XCTAssertEqual(perform("groups.leave")["ok"] as? Bool,true)
        XCTAssertTrue(AdvancedChat.shared.left)
        XCTAssertNil(AdvancedChat.shared.lastSent)
    }
    func testPhotoAcknowledgementDoesNotClaimAnUnobservedEffect() {
        let result = perform("groups.photo",fields:["file_path":"/private/tmp/fixture.png"])
        XCTAssertNil(result["ok"])
        XCTAssertEqual(result["accepted"] as? Bool,true)
        XCTAssertEqual(result["uncertain"] as? Bool,true)
        XCTAssertEqual(result["native_confirmation"] as? String,"pending")
    }
    func testEditAndUnsendRespectOriginalAgeAndNativeEligibility() {
        AdvancedChat.shared.target.originalDate = Date().addingTimeInterval(-121)
        XCTAssertEqual(perform("messages.unsend")["uncertain"] as? Bool,false)
        AdvancedChat.shared.target.originalDate = Date().addingTimeInterval(-901)
        XCTAssertEqual(perform("messages.edit",fields:["text":"Edited"])["uncertain"] as? Bool,false)
        XCTAssertEqual(AdvancedChat.shared.mutationCount,0)
        AdvancedChat.shared.target.originalDate = Date().addingTimeInterval(-10)
        AdvancedChat.shared.target.item.part.eligible = false
        XCTAssertEqual(perform("messages.edit",fields:["text":"Edited"])["uncertain"] as? Bool,false)
        AdvancedChat.shared.target.item.part.eligible = true
        XCTAssertEqual(perform("messages.edit",fields:["text":"Edited"])["ok"] as? Bool,true)
        XCTAssertEqual(perform("messages.unsend")["ok"] as? Bool,true)
        XCTAssertEqual(AdvancedChat.shared.mutationCount,2)
    }
    func testIncomingOrWrongNativePartCannotBeEdited() {
        AdvancedChat.shared.target.own = false
        XCTAssertEqual(perform("messages.edit",fields:["text":"Edited"])["uncertain"] as? Bool,false)
        AdvancedChat.shared.target.own = true
        XCTAssertEqual(perform("messages.edit",fields:["text":"Edited","part_index":1])["uncertain"] as? Bool,false)
        XCTAssertEqual(AdvancedChat.shared.mutationCount,0)
    }
    func testMultipartCreatesOneNativeMessageWithOrderedPartsAndEffect() {
        let effect = "com.apple.messages.effect.CKConfettiEffect"
        let result = perform("messages.multipart",fields:["text":"Fixture", "files":[["file_path":"/private/tmp/first.png"],["file_path":"/private/tmp/second.mp4"]],"effect":effect])
        XCTAssertEqual(result["ok"] as? Bool,true)
        XCTAssertEqual(AdvancedChat.shared.mutationCount,1)
        let message = AdvancedChat.shared.lastSent!
        XCTAssertEqual(message.body.string,"Fixture\u{fffc}\u{fffc}")
        XCTAssertEqual(message.transfers.count,2)
        XCTAssertEqual(message.body.attribute(NSAttributedString.Key("__kIMMessagePartAttributeName"),at:7,effectiveRange:nil) as? NSNumber,1)
        XCTAssertEqual(message.body.attribute(NSAttributedString.Key("__kIMMessagePartAttributeName"),at:8,effectiveRange:nil) as? NSNumber,2)
        XCTAssertEqual(message.expressiveSendStyleID,effect)
        XCTAssertNotEqual(message.guid,advancedMessageID)
    }
    func testMissingCapabilityRejectsWithoutMutation() {
        let result = perform("availability",fields:["address":"fixture@example.test"])
        XCTAssertEqual(result["uncertain"] as? Bool,false)
        XCTAssertEqual(AdvancedChat.shared.mutationCount,0)
    }
    func testMissingEffectSelectorRejectsBeforeCreatingTransfers() {
        let base = resolver
        var result: [String: Any] = [:]
        BBCNativePerform(["method":"messages.multipart", "chat_guid":advancedChatID,
                          "files":[["file_path":"/private/tmp/fixture.png"]],
                          "effect":"com.apple.messages.effect.CKConfettiEffect"], { name in
            name == "IMMessage" ? FixtureMessage.self : base(name)
        }) { result = $0 }
        XCTAssertEqual(result["failure_code"] as? String, "native_effect_unavailable")
        XCTAssertEqual(result["uncertain"] as? Bool, false)
        XCTAssertEqual(AdvancedTransferCenter.creations, 0)
        XCTAssertEqual(AdvancedChat.shared.mutationCount, 0)
    }
    func testInvalidEffectRejectsBeforeCreatingTransfers() {
        let result = perform("messages.multipart", fields: ["files":[["file_path":"/private/tmp/fixture.png"]], "effect":"invalid"])
        XCTAssertEqual(result["failure_code"] as? String, "native_invalid_effect")
        XCTAssertEqual(AdvancedTransferCenter.creations, 0)
        XCTAssertEqual(AdvancedChat.shared.mutationCount, 0)
    }

}
