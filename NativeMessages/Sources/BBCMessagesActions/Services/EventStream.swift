import Foundation
import BBCClient

/// Saved with the database observer's cursors, so message events and replay are atomic.
struct EventStreamState: Codable, Equatable {
    struct Client: Codable, Equatable {
        let since: Date
        let afterRowID: Int64
        var floor: Int64 = 0
    }
    struct Event: Codable, Equatable {
        let sequence: Int64
        let keyID: UUID
        let body: Data
    }
    var epoch = UUID()
    var sequence: Int64 = 0
    var clients: [UUID:Client] = [:]
    var events: [Event] = []
    static let maximumEvents = 512
    static let maximumBytes = 8 * 1024 * 1024

    mutating func append(_ packet: BBCJSONValue, keyID: UUID) throws {
        guard clients[keyID] != nil else { return }
        let data = try JSONEncoder().encode(packet)
        guard data.count <= 131_072 else { throw ActionFailure.invalid }
        sequence += 1
        events.append(Event(sequence:sequence,keyID:keyID,body:data))
        var bytes = events.reduce(0) { $0 + $1.body.count }
        while events.count > Self.maximumEvents || bytes > Self.maximumBytes {
            let removed = events.removeFirst(); bytes -= removed.body.count
            clients[removed.keyID]?.floor = removed.sequence
        }
    }
    func cursor(_ sequence: Int64) -> String { "\(epoch.uuidString):\(sequence)" }
    func position(_ cursor: String) throws -> Int64 {
        let pieces = cursor.split(separator:":",omittingEmptySubsequences:false)
        guard pieces.count == 2, UUID(uuidString:String(pieces[0])) == epoch,
              let value = Int64(pieces[1]), value >= 0, value <= sequence else { throw ActionFailure.invalid }
        return value
    }
}

struct EventStreamBatch: Sendable {
    let status: Int
    let cursor: String?
    let frames: Data
    var observation = "unavailable"
}
