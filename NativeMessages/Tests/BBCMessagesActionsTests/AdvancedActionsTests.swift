import Foundation
import XCTest
import SQLite3
import BBCClient
@testable import BBCMessagesActions

final class AdvancedActionsTests: XCTestCase {
    private func payload(_ method: String, _ parameters: [String:BBCJSONValue]) -> BBCJSONValue {
        .object(["method":.string(method),"params":.object(parameters)])
    }
    func testAdvancedRequestsRejectInjectedPathsAndSelectors() throws {
        let chat = BBCJSONValue.string("iMessage;+;fixture")
        XCTAssertThrowsError(try AdvancedRequest(payload("messages.multipart",["chat_guid":chat,"text":.string("Hello"),"file_path":.string("/etc/passwd")])))
        XCTAssertThrowsError(try AdvancedRequest(payload("groups.leave",["chat_guid":chat,"selector":.string("join")])))
        XCTAssertThrowsError(try AdvancedRequest(payload("availability",["address":.string("sms:fixture@example.test")])))
        XCTAssertThrowsError(try AdvancedRequest(payload("groups.leave",["chat_guid":.string("SMS;+;fixture")])))
        XCTAssertThrowsError(try AdvancedRequest(payload("groups.leave",["chat_guid":.string("iMessage;-;fixture@example.test")])))
        XCTAssertNoThrow(try AdvancedRequest(payload("groups.leave",["chat_guid":chat])))
    }
    func testMembershipRequiresBoundedDistinctAddresses() throws {
        let first = BBCJSONValue.string("fixture@example.test")
        XCTAssertThrowsError(try AdvancedRequest(payload("groups.create",["participants":.array([first])])) )
        XCTAssertThrowsError(try AdvancedRequest(payload("groups.create",["participants":.array([first,.string("FIXTURE@example.test")])])) )
        XCTAssertNoThrow(try AdvancedRequest(payload("groups.create",["participants":.array([first,.string("+15555550123")])])) )
    }
    func testMultipartBoundsAndEffectsValidateBeforeResolvingUploads() throws {
        let chat = BBCJSONValue.string("iMessage;+;fixture"), media = BBCJSONValue.string(UUID().uuidString)
        XCTAssertThrowsError(try AdvancedRequest(payload("messages.multipart",["chat_guid":chat])))
        XCTAssertThrowsError(try AdvancedRequest(payload("messages.multipart",["chat_guid":chat,"media_ids":.array([media,media])])))
        XCTAssertThrowsError(try AdvancedRequest(payload("messages.multipart",["chat_guid":chat,"media_ids":.array((0..<9).map { _ in .string(UUID().uuidString) })])))
        XCTAssertThrowsError(try AdvancedRequest(payload("messages.multipart",["chat_guid":chat,"text":.string("Hello"),"effect":.string("arbitrary-selector")])))
        XCTAssertNoThrow(try AdvancedRequest(payload("messages.multipart",["chat_guid":chat,"text":.string("Hello"),"media_ids":.array([media]),"effect":.string("com.apple.messages.effect.CKConfettiEffect")])))
    }
    func testPartIndicesAreBoundedIntegers() throws {
        let parameters: [String:BBCJSONValue] = ["chat_guid":.string("iMessage;+;fixture"),"message_guid":.string(UUID().uuidString)]
        for index in [-1.0,0.5,64.0] {
            var fields = parameters; fields["part_index"] = .number(index)
            XCTAssertThrowsError(try AdvancedRequest(payload("messages.unsend",fields)))
        }
        XCTAssertNoThrow(try AdvancedRequest(payload("messages.unsend",parameters)))
    }
    private func fixture(_ body: (MessagesDatabase,OpaquePointer,String,String,Date) throws -> Void) throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:file) }
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(file.path,&connection),SQLITE_OK); defer { sqlite3_close(connection) }
        let chat = "iMessage;+;fixture", message = UUID().uuidString, now = Date(timeIntervalSince1970:1_800_000_000)
        let nativeDate = Int64((now.timeIntervalSince1970-978307200-30)*1_000_000_000)
        XCTAssertEqual(sqlite3_exec(connection,"""
            CREATE TABLE chat(guid TEXT,service_name TEXT);
            CREATE TABLE chat_handle_join(chat_id INTEGER,handle_id INTEGER);
            CREATE TABLE chat_message_join(chat_id INTEGER,message_id INTEGER);
            CREATE TABLE message(guid TEXT,service TEXT,is_from_me INTEGER,is_sent INTEGER,error INTEGER,date INTEGER,text TEXT,attributedBody BLOB,expressive_send_style_id TEXT);
            CREATE TABLE attachment(transfer_name TEXT);
            CREATE TABLE message_attachment_join(message_id INTEGER,attachment_id INTEGER);
            INSERT INTO chat VALUES('\(chat)','iMessage'); INSERT INTO chat_handle_join VALUES(1,1),(1,2);
            INSERT INTO message VALUES('\(message)','iMessage',1,1,0,\(nativeDate),'Fixture',NULL,'');
            INSERT INTO chat_message_join VALUES(1,1);
            """,nil,nil,nil),SQLITE_OK)
        try body(MessagesDatabase(url:file),connection!,chat,message,now)
    }
    func testGroupVerificationRequiresExactIMessageChatAndParticipants() throws {
        try fixture { database,connection,chat,_,_ in
            XCTAssertNoThrow(try database.verifyAdvancedChat(chat,group:true))
            XCTAssertThrowsError(try database.verifyAdvancedChat("iMessage;+;another",group:true))
            XCTAssertEqual(sqlite3_exec(connection,"UPDATE chat SET service_name='SMS'",nil,nil,nil),SQLITE_OK)
            XCTAssertThrowsError(try database.verifyAdvancedChat(chat,group:true))
            XCTAssertEqual(sqlite3_exec(connection,"UPDATE chat SET service_name='iMessage'; DELETE FROM chat_handle_join WHERE handle_id=2",nil,nil,nil),SQLITE_OK)
            XCTAssertThrowsError(try database.verifyAdvancedChat(chat,group:true))
        }
    }
    func testEditAndUnsendDatabaseGuardsOwnershipAndOriginalWindow() throws {
        try fixture { database,connection,chat,message,now in
            XCTAssertNoThrow(try database.verifyOwnChange(chat:chat,message:message,edit:true,now:now))
            XCTAssertNoThrow(try database.verifyOwnChange(chat:chat,message:message,edit:false,now:now))
            XCTAssertThrowsError(try database.verifyOwnChange(chat:chat,message:message,edit:false,now:now.addingTimeInterval(100)))
            XCTAssertThrowsError(try database.verifyOwnChange(chat:chat,message:message,edit:true,now:now.addingTimeInterval(900)))
            XCTAssertEqual(sqlite3_exec(connection,"UPDATE message SET is_from_me=0",nil,nil,nil),SQLITE_OK)
            XCTAssertThrowsError(try database.verifyOwnChange(chat:chat,message:message,edit:true,now:now))
        }
    }
    func testMultipartConfirmationRequiresExactGuidBodyAttachmentsAndEffect() throws {
        try fixture { database,connection,chat,message,_ in
            let upload = MediaStore.Upload(id:UUID(),ext:"png",mimeType:"image/png",bytes:4,created:Date())
            let effect = "com.apple.messages.effect.CKConfettiEffect"
            XCTAssertEqual(sqlite3_exec(connection,"UPDATE message SET text='Fixture\u{fffc}',expressive_send_style_id='\(effect)'; INSERT INTO attachment VALUES('\(upload.filename)'); INSERT INTO message_attachment_join VALUES(1,1)",nil,nil,nil),SQLITE_OK)
            XCTAssertTrue(try database.confirmedMultipart(chat:chat,guid:message,text:"Fixture",uploads:[upload],effect:effect,after:0))
            XCTAssertFalse(try database.confirmedMultipart(chat:chat,guid:message,text:"Fixture",uploads:[upload],effect:effect,after:1))
            XCTAssertFalse(try database.confirmedMultipart(chat:chat,guid:UUID().uuidString,text:"Fixture",uploads:[upload],effect:effect,after:0))
            XCTAssertFalse(try database.confirmedMultipart(chat:chat,guid:message,text:"Other",uploads:[upload],effect:effect,after:0))
            XCTAssertFalse(try database.confirmedMultipart(chat:chat,guid:message,text:"Fixture",uploads:[],effect:effect,after:0))
            XCTAssertFalse(try database.confirmedMultipart(chat:chat,guid:message,text:"Fixture",uploads:[upload],effect:"different",after:0))
        }
    }
}
