import Darwin
import Foundation
import XCTest
import SQLite3
@testable import BBCMessagesActions

final class DatabaseTests: XCTestCase {
    let guid = "11111111-1111-4111-8111-111111111111"
    let chat = "any;-;owner@example.test"
    private func fixture(_ body: (MessagesDatabase, OpaquePointer) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db); try? FileManager.default.removeItem(at: url) }
        let setup = """
        CREATE TABLE message(guid TEXT, service TEXT, is_from_me INTEGER, is_read INTEGER, associated_message_type INTEGER, associated_message_guid TEXT,item_type INTEGER DEFAULT 0);
        CREATE TABLE chat(guid TEXT, chat_identifier TEXT);
        CREATE TABLE chat_message_join(chat_id INTEGER,message_id INTEGER);
        CREATE TABLE chat_handle_join(chat_id INTEGER,handle_id INTEGER);
        INSERT INTO chat VALUES('\(chat)','owner@example.test');
        INSERT INTO chat_handle_join VALUES(1,1);
        INSERT INTO message(guid,service,is_from_me,is_read,associated_message_type,associated_message_guid) VALUES('\(guid)','iMessage',0,0,0,NULL);
        INSERT INTO chat_message_join VALUES(1,1);
        """
        XCTAssertEqual(sqlite3_exec(db, setup, nil, nil, nil), SQLITE_OK)
        try body(MessagesDatabase(url: url), db!)
    }
    func testNativeReplyConfirmationRequiresExactChatRootTextAndNewSentRow() throws {
        try fixture { database, db in
            XCTAssertEqual(sqlite3_exec(db,"ALTER TABLE message ADD COLUMN thread_originator_guid TEXT; ALTER TABLE message ADD COLUMN text TEXT; ALTER TABLE message ADD COLUMN is_sent INTEGER; ALTER TABLE message ADD COLUMN error INTEGER",nil,nil,nil),SQLITE_OK)
            XCTAssertEqual(try database.threadRoot(chat:chat,message:guid),guid)
            let before = try database.maximumRowID()
            let sent = "22222222-2222-4222-8222-222222222222"
            func insert(_ root: String, _ text: String, _ sentFlag: Int) {
                XCTAssertEqual(sqlite3_exec(db,"INSERT INTO message(guid,service,is_from_me,is_read,thread_originator_guid,text,is_sent,error) VALUES('\(sent)','iMessage',1,1,'\(root)','\(text)',\(sentFlag),0); INSERT INTO chat_message_join VALUES(1,last_insert_rowid())",nil,nil,nil),SQLITE_OK)
            }
            insert("33333333-3333-4333-8333-333333333333","answer",1)
            insert(guid,"another answer",1);insert(guid,"answer",0)
            XCTAssertNil(try database.confirmedReply(chat:chat,root:guid,text:"answer",after:before))
            insert(guid,"answer",1)
            XCTAssertEqual(try database.confirmedReply(chat:chat,root:guid,text:"answer",after:before),sent)
            insert(guid,"answer",1)
            XCTAssertThrowsError(try database.confirmedReply(chat:chat,root:guid,text:"answer",after:before))
        }
    }

    func testNativeThreadRootAcceptsNonzeroPartWithoutCrossThreadConfirmation() throws {
        try fixture { database, db in
            XCTAssertEqual(sqlite3_exec(db,"ALTER TABLE message ADD COLUMN thread_originator_guid TEXT; ALTER TABLE message ADD COLUMN text TEXT; ALTER TABLE message ADD COLUMN is_sent INTEGER; ALTER TABLE message ADD COLUMN error INTEGER",nil,nil,nil),SQLITE_OK)
            sqlite3_exec(db,"UPDATE message SET thread_originator_guid='p:3/\(guid)'",nil,nil,nil)
            XCTAssertEqual(try database.threadRoot(chat:chat,message:guid),guid)
            let before = try database.maximumRowID()
            let sent = "22222222-2222-4222-8222-222222222222"
            sqlite3_exec(db,"INSERT INTO message(guid,service,is_from_me,is_read,thread_originator_guid,text,is_sent,error) VALUES('\(sent)','iMessage',1,1,'p:3/\(guid)','part reply',1,0); INSERT INTO chat_message_join VALUES(1,last_insert_rowid())",nil,nil,nil)
            XCTAssertEqual(try database.confirmedReply(chat:chat,root:guid,text:"part reply",after:before),sent)
            XCTAssertNil(try database.confirmedReply(chat:chat,root:UUID().uuidString,text:"part reply",after:before))
        }
    }

    func testExactChatAndMessageRequired() throws {
        try fixture { database, _ in
            XCTAssertNoThrow(try database.verify(chat: chat, message: guid))
            XCTAssertThrowsError(try database.verify(chat: "any;-;stranger@example.test", message: guid))
            XCTAssertThrowsError(try database.verify(chat: chat, message: "latest"))
            XCTAssertThrowsError(try database.verify(chat: chat, message: guid + "' OR 1=1--"))
        }
    }
    func testSMSAndGroupRejected() throws {
        try fixture { database, db in
            sqlite3_exec(db,"UPDATE message SET service='SMS'",nil,nil,nil)
            XCTAssertThrowsError(try database.verify(chat: chat, message: guid))
            sqlite3_exec(db,"UPDATE message SET service='iMessage'; INSERT INTO chat_handle_join VALUES(1,2)",nil,nil,nil)
            XCTAssertThrowsError(try database.verify(chat: chat, message: guid))
        }
    }
    func testReactionTracksExactPartOwnSenderAndRemoval() throws {
        try fixture { database, db in
            func event(_ type: Int, _ target: String, own: Int = 1) {
                sqlite3_exec(db,"INSERT INTO message(guid,service,is_from_me,is_read,associated_message_type,associated_message_guid) VALUES('event','iMessage',\(own),1,\(type),'\(target)'); INSERT INTO chat_message_join VALUES(1,last_insert_rowid())",nil,nil,nil)
            }
            XCTAssertNil(try database.reaction(chat: chat, message: guid))
            event(2001,"p:1/" + guid)
            event(2000,"p:0/" + guid, own: 0)
            XCTAssertNil(try database.reaction(chat: chat, message: guid))
            event(2001,"p:0/" + guid)
            XCTAssertEqual(try database.reaction(chat: chat, message: guid),1)
            XCTAssertTrue(NativeRequest.isDesired(current: 1,reaction: 1,remove: false))
            XCTAssertTrue(NativeRequest.isDesired(current: 1,reaction: 0,remove: true))
            event(3001,"p:0/" + guid)
            XCTAssertNil(try database.reaction(chat: chat, message: guid))
            XCTAssertTrue(NativeRequest.isDesired(current: nil,reaction: 1,remove: true))
        }
    }
    func testReadSnapshotDetectsAdditionalUnreadMessage() throws {
        try fixture { database, db in
            XCTAssertEqual(try database.unread(chat: chat),[guid])
            sqlite3_exec(db,"INSERT INTO message(guid,service,is_from_me,is_read,associated_message_type,associated_message_guid) VALUES('newer','iMessage',0,0,0,NULL); INSERT INTO chat_message_join VALUES(1,last_insert_rowid())",nil,nil,nil)
            XCTAssertFalse(Set(try database.unread(chat: chat)).isSubset(of: [guid]))
        }
    }
    func testConversationActionIsNotAnUnreadChatMessage() throws {
        try fixture { database, db in
            let sql = """
            INSERT INTO message(guid,service,is_from_me,is_read,associated_message_type,item_type)
              VALUES('background','iMessage',0,0,0,3);
            INSERT INTO chat_message_join VALUES(1,last_insert_rowid());
            """
            XCTAssertEqual(sqlite3_exec(db,sql,nil,nil,nil),SQLITE_OK)
            XCTAssertEqual(try database.unread(chat: chat),[guid])
            XCTAssertEqual(try database.unreadOutsideScope(chat: chat,consumed:[guid]),[])
            XCTAssertEqual(sqlite3_exec(db,"UPDATE message SET is_read=1 WHERE guid='\(guid)'",nil,nil,nil),SQLITE_OK)
            XCTAssertTrue(try database.unread(chat: chat).isEmpty)
            // No plain text is required for a genuine incoming message to block.
            XCTAssertEqual(sqlite3_exec(db,"UPDATE message SET is_read=0 WHERE guid='\(guid)'",nil,nil,nil),SQLITE_OK)
            XCTAssertEqual(try database.unread(chat: chat),[guid])
        }
    }
    func testReadRequestMustIncludeConfirmedTarget() throws {
        let missing = "{\"method\":\"read\",\"params\":{\"chat_guid\":\"\(chat)\",\"message_guid\":\"\(guid)\",\"read_guids\":[]}}"
        XCTAssertThrowsError(try JSONDecoder().decode(NativeRequest.self,from:Data(missing.utf8)).validated())
        let valid = missing.replacingOccurrences(of:"\"read_guids\":[]",with:"\"read_guids\":[\"\(guid)\"]")
        XCTAssertNoThrow(try JSONDecoder().decode(NativeRequest.self,from:Data(valid.utf8)).validated())
    }
    func testAudioAttachmentRequiresExactIncomingMessageAssociation() throws {
        try fixture { database, db in
            let sql = """
            CREATE TABLE attachment(guid TEXT,filename TEXT,mime_type TEXT,uti TEXT,total_bytes INTEGER);
            CREATE TABLE message_attachment_join(message_id INTEGER,attachment_id INTEGER);
            INSERT INTO attachment VALUES('audio-opaque-id','~/Library/Messages/Attachments/aa/voice.caf','audio/x-caf','com.apple.coreaudio-format',1024);
            INSERT INTO message_attachment_join VALUES(1,1);
            INSERT INTO attachment VALUES('unassociated','/private/unrelated','audio/x-caf','com.apple.coreaudio-format',1024);
            """
            XCTAssertEqual(sqlite3_exec(db,sql,nil,nil,nil),SQLITE_OK)
            let target = try database.audioAttachment(chat: chat, message: guid, attachment: "audio-opaque-id")
            XCTAssertEqual(target.declaredBytes, 1024)
            XCTAssertThrowsError(try database.audioAttachment(chat: chat, message: guid, attachment: "unassociated"))
            XCTAssertThrowsError(try database.audioAttachment(chat: "any;-;other@example.test", message: guid, attachment: "audio-opaque-id"))
            XCTAssertEqual(sqlite3_exec(db,"UPDATE message SET is_from_me=1",nil,nil,nil),SQLITE_OK)
            XCTAssertThrowsError(try database.audioAttachment(chat: chat, message: guid, attachment: "audio-opaque-id"))
            XCTAssertEqual(sqlite3_exec(db,"UPDATE message SET is_from_me=0; UPDATE attachment SET mime_type='image/png',uti='public.png'",nil,nil,nil),SQLITE_OK)
            XCTAssertThrowsError(try database.audioAttachment(chat: chat, message: guid, attachment: "audio-opaque-id"))
        }
    }
    func testVisualAttachmentRequiresExactIncomingMessageAndBoundedMediaKind() throws {
        try fixture { database, db in
            let sql = """
            CREATE TABLE attachment(guid TEXT,filename TEXT,mime_type TEXT,uti TEXT,total_bytes INTEGER);
            CREATE TABLE message_attachment_join(message_id INTEGER,attachment_id INTEGER);
            INSERT INTO attachment VALUES('selected-photo','~/Library/Messages/Attachments/aa/photo.heic','image/heic','public.heic',1024);
            INSERT INTO message_attachment_join VALUES(1,1);
            INSERT INTO attachment VALUES('unassociated-video','~/Library/Messages/Attachments/bb/movie.mov','video/quicktime','com.apple.quicktime-movie',1024);
            """
            XCTAssertEqual(sqlite3_exec(db,sql,nil,nil,nil),SQLITE_OK)
            let photo = try database.visualAttachment(chat: chat, message: guid, attachment: "selected-photo")
            XCTAssertEqual(photo.kind, .image); XCTAssertEqual(photo.maximumBytes, LocalVisualMedia.maximumImageBytes)
            for target in ["unassociated-video", "selected-photo' OR 1=1--"] {
                XCTAssertThrowsError(try database.visualAttachment(chat: chat, message: guid, attachment: target))
            }
            XCTAssertThrowsError(try database.visualAttachment(chat: "any;-;other@example.test", message: guid, attachment: "selected-photo"))
            func update(_ sql: String) { XCTAssertEqual(sqlite3_exec(db,sql,nil,nil,nil),SQLITE_OK) }
            update("UPDATE attachment SET total_bytes=\(LocalVisualMedia.maximumImageBytes+1) WHERE guid='selected-photo'")
            XCTAssertThrowsError(try database.visualAttachment(chat: chat, message: guid, attachment: "selected-photo"))
            update("UPDATE attachment SET mime_type='',uti='com.apple.quicktime-movie',total_bytes=\(LocalVisualMedia.maximumVideoBytes) WHERE guid='selected-photo'")
            let video = try database.visualAttachment(chat: chat, message: guid, attachment: "selected-photo")
            XCTAssertEqual(video.kind, .video); XCTAssertEqual(video.maximumBytes, LocalVisualMedia.maximumVideoBytes)
            update("UPDATE attachment SET total_bytes=\(LocalVisualMedia.maximumVideoBytes+1) WHERE guid='selected-photo'")
            XCTAssertThrowsError(try database.visualAttachment(chat: chat, message: guid, attachment: "selected-photo"))
            update("UPDATE attachment SET mime_type='audio/x-caf',uti='com.apple.coreaudio-format',total_bytes=1024 WHERE guid='selected-photo'")
            XCTAssertThrowsError(try database.visualAttachment(chat: chat, message: guid, attachment: "selected-photo"))
            update("UPDATE attachment SET mime_type='image/png',uti='public.png' WHERE guid='selected-photo'; UPDATE message SET is_from_me=1")
            XCTAssertThrowsError(try database.visualAttachment(chat: chat, message: guid, attachment: "selected-photo"))
            update("UPDATE message SET is_from_me=0,item_type=3")
            XCTAssertThrowsError(try database.visualAttachment(chat: chat, message: guid, attachment: "selected-photo"))
            update("UPDATE message SET item_type=0,service='SMS'")
            XCTAssertThrowsError(try database.visualAttachment(chat: chat, message: guid, attachment: "selected-photo"))
        }
    }
    func testVisualRequestAcceptsOnlyExactMessageAndAttachmentIdentity() throws {
        let request: [String: Any] = ["method": "media.visual", "params": ["chat_guid": chat, "message_guid": guid, "attachment_guid": "selected-photo"]]
        let decoded = try JSONDecoder().decode(NativeRequest.self, from: JSONSerialization.data(withJSONObject: request))
        XCTAssertEqual(try decoded.validated().attachment_guid, "selected-photo")
        for attachment in ["", String(repeating: "a", count: 257), "invalid\0attachment"] {
            let invalid: [String: Any] = ["method": "media.visual", "params": ["chat_guid": chat, "message_guid": guid, "attachment_guid": attachment]]
            XCTAssertThrowsError(try JSONDecoder().decode(NativeRequest.self, from: JSONSerialization.data(withJSONObject: invalid)).validated())
        }
    }
    func testUnreadDiagnosticsAreScopedMetadataAndExcludeConsumedIdentities() throws {
        try fixture { database, db in
            sqlite3_exec(db,"INSERT INTO message(guid,service,is_from_me,is_read,associated_message_type,associated_message_guid) VALUES('missing','iMessage',0,0,2001,'p:0/target'); INSERT INTO chat_message_join VALUES(1,last_insert_rowid())",nil,nil,nil)
            let rows = try database.unreadOutsideScope(chat: chat, consumed: [guid])
            XCTAssertEqual(rows, [["guid": "missing", "service": "iMessage", "associated_type": "2001", "system": "0", "item_type": "0"]])
            XCTAssertEqual(try database.unreadOutsideScope(chat: "other", consumed: []), [])
            XCTAssertEqual(try database.unreadOutsideScope(chat: chat, consumed: [guid, "missing"]), [])
            sqlite3_exec(db,"ALTER TABLE message ADD COLUMN text TEXT; UPDATE message SET text='PRIVATE_MESSAGE_TEXT'",nil,nil,nil)
            let bounded = try database.unreadOutsideScope(chat: chat, consumed: [guid])
            XCTAssertEqual(bounded.first?["text_length"], "20")
            XCTAssertFalse(bounded.description.contains("PRIVATE_MESSAGE_TEXT"))
        }
    }
}
