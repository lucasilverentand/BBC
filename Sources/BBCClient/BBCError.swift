import Foundation

public enum BBCError: Error, LocalizedError, Sendable {
    case invalid(String), unavailable(String)
    public var errorDescription: String? {
        switch self { case .invalid(let message), .unavailable(let message): message }
    }
}

enum MessageGUID {
    static func normalize(_ raw: String) -> String? {
        if let id = UUID(uuidString: raw) { return id.uuidString }
        let parts = raw.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].hasPrefix("p:"),
              Int(parts[0].dropFirst(2)).map({ $0 >= 0 }) == true,
              let id = UUID(uuidString: String(parts[1])) else { return nil }
        return id.uuidString
    }
}
