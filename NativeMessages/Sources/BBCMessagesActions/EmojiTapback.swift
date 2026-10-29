import Foundation

enum EmojiTapback {
    /// A single extended grapheme, including flags, skin tones and ZWJ families.
    static func valid(_ value: String) -> Bool {
        guard value.count == 1, value.utf8.count <= 128 else { return false }
        let scalars = value.unicodeScalars
        guard scalars.contains(where: { $0.properties.isEmoji && ($0.value > 127 || scalars.contains("\u{20e3}")) }),
              !scalars.allSatisfy({ (0x1f3fb...0x1f3ff).contains($0.value) }) else { return false }
        return scalars.allSatisfy {
            $0.properties.isEmoji || [0x200d, 0xfe0f, 0x20e3].contains($0.value) || (0xe0020...0xe007f).contains($0.value)
        }
    }
    static func isDesired(current: String?, reaction: String, remove: Bool) -> Bool {
        remove ? current != reaction : current == reaction
    }
}
