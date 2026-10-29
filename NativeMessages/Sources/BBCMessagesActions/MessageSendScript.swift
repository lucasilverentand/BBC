import Foundation

/// Keep script variables outside Messages' scripting dictionary vocabulary.
enum MessageSendScript {
    static func text(to: String, text: String) -> String {
        source(to: to, content: literal(text))
    }
    static func file(to: String, file: URL) -> String {
        source(to: to, content: "(POSIX file " + literal(file.path) + " as alias)")
    }
    private static func source(to: String, content: String) -> String {
        """
        tell application id "com.apple.MobileSMS"
          set bbcSelectedService to first service whose service type is iMessage
          set bbcSelectedBuddy to buddy \(literal(to)) of bbcSelectedService
          send \(content) to bbcSelectedBuddy
        end tell
        """
    }
    private static func literal(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\r", with: "\\r").replacingOccurrences(of: "\n", with: "\\n") + "\""
    }
}
