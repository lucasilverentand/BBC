import Foundation
import XCTest
import SQLite3
import BBCClient
@testable import BBCMessagesActions

final class LocalReaderTests: XCTestCase {
    func testCursorPagesKeepExactNativeThreadsAttachmentsAndReactions() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &connection), SQLITE_OK); defer { sqlite3_close(connection) }
        let root = "11111111-1111-4111-8111-111111111111", reply = "22222222-2222-4222-8222-222222222222"
        let setup = """
        CREATE TABLE message(guid TEXT,text TEXT,handle_id INTEGER,is_from_me INTEGER,date INTEGER,service TEXT,thread_originator_guid TEXT,associated_message_type INTEGER,associated_message_guid TEXT,attributedBody BLOB);
        CREATE TABLE chat(guid TEXT,chat_identifier TEXT);
        CREATE TABLE handle(id TEXT);
        CREATE TABLE chat_message_join(chat_id INTEGER,message_id INTEGER);
        CREATE TABLE chat_handle_join(chat_id INTEGER,handle_id INTEGER);
        CREATE TABLE attachment(guid TEXT,mime_type TEXT,uti TEXT,total_bytes INTEGER,is_sticker INTEGER);
        CREATE TABLE message_attachment_join(message_id INTEGER,attachment_id INTEGER);
        INSERT INTO handle VALUES('fixture@example.test');
        INSERT INTO chat VALUES('any;-;fixture@example.test','fixture@example.test');
        INSERT INTO chat_handle_join VALUES(1,1);
        INSERT INTO message VALUES('\(root)','root',1,0,1,'iMessage',NULL,0,NULL,NULL);
        INSERT INTO message VALUES('\(reply)','reply',1,0,2,'iMessage','p:3/\(root)',0,NULL,NULL);
        INSERT INTO message VALUES('reaction','',1,0,3,'iMessage',NULL,2001,'p:0/\(reply)',NULL);
        INSERT INTO chat_message_join VALUES(1,1),(1,2),(1,3);
        INSERT INTO attachment VALUES('attachment','image/png','public.png',42,0);
        INSERT INTO message_attachment_join VALUES(2,1);
        """
        XCTAssertEqual(sqlite3_exec(connection, setup, nil, nil, nil), SQLITE_OK)
        let database = try MessagesDatabase(url: url)
        let first = try database.page(["limit": .number(2)])
        guard case .array(let rows) = first.object?["messages"] else { return XCTFail("Expected messages") }
        XCTAssertEqual(rows.count, 2); XCTAssertEqual(first.object?["next_rowid"]?.numberValue, 2)
        XCTAssertEqual(rows[0].object?["thread_root_guid"]?.string, root)
        XCTAssertEqual(rows[1].object?["reply_to_guid"]?.string, root)
        XCTAssertEqual(rows[1].object?["service"]?.string, "iMessage")
        XCTAssertEqual(rows[1].object?["is_group"]?.bool, false)
        guard case .array(let attachments) = rows[1].object?["attachments"] else { return XCTFail("Expected attachment metadata") }
        XCTAssertEqual(attachments[0].object?["guid"]?.string, "attachment")
        let second = try database.page(["since_rowid": .number(2)])
        guard case .array(let events) = second.object?["messages"] else { return XCTFail("Expected reaction") }
        XCTAssertEqual(events.count, 1); XCTAssertEqual(events[0].object?["reacted_to_guid"]?.string, reply)
        XCTAssertEqual(events[0].object?["is_reaction"]?.bool, true)
        XCTAssertThrowsError(try database.page(["since_rowid": .number(-1)]))
        XCTAssertThrowsError(try database.page(["limit": .number(201)]))
    }
}
