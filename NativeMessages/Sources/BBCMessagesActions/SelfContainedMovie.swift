import Foundation

/// Restrict AVFoundation input to a bounded, self-contained MP4/MOV container.
/// A local filename alone is insufficient: QuickTime data references can point
/// outside that file, and playlist text must never become a network asset.
enum SelfContainedMovie {
    static func validate(_ data: Data) throws {
        guard data.count >= 24, data.count <= LocalVisualMedia.maximumVideoBytes else { throw ActionFailure.invalid }
        var boxes = 0, movie = false, media = false, references = 0
        func u32(_ offset: Int) throws -> UInt32 {
            guard offset >= 0, offset <= data.count - 4 else { throw ActionFailure.invalid }
            return (0..<4).reduce(UInt32(0)) { ($0 << 8) | UInt32(data[offset + $1]) }
        }
        func header(_ offset: Int, end: Int) throws -> (String, Int, Int) {
            guard offset <= end - 8 else { throw ActionFailure.invalid }
            let short = try u32(offset)
            let type = String(decoding: data[(offset+4)..<(offset+8)], as: UTF8.self)
            let length: Int, prefix: Int
            if short == 1 {
                guard offset <= end - 16 else { throw ActionFailure.invalid }
                let extended = (UInt64(try u32(offset+8)) << 32) | UInt64(try u32(offset+12))
                guard extended <= UInt64(end-offset) else { throw ActionFailure.invalid }
                length = Int(extended); prefix = 16
            } else { length = short == 0 ? end-offset : Int(short); prefix = 8 }
            guard length >= prefix, length <= end-offset else { throw ActionFailure.invalid }
            boxes += 1; guard boxes <= 4096 else { throw ActionFailure.invalid }
            return (type, offset+prefix, offset+length)
        }
        func walk(_ start: Int, _ end: Int, _ depth: Int) throws {
            guard depth <= 12 else { throw ActionFailure.invalid }
            var offset = start
            while offset < end {
                let (type, body, next) = try header(offset, end: end)
                guard !["rmra", "rmda", "rdrf"].contains(type) else { throw ActionFailure.invalid }
                if depth == 0 {
                    if offset == 0 { guard type == "ftyp", next-body >= 8 else { throw ActionFailure.invalid } }
                    if type == "moov" { guard !movie else { throw ActionFailure.invalid }; movie = true }
                    if type == "mdat" { media = true }
                    guard ["ftyp", "moov", "mdat", "free", "wide", "skip"].contains(type) else { throw ActionFailure.invalid }
                }
                if type == "dref" {
                    guard next-body >= 8, try u32(body) == 0 else { throw ActionFailure.invalid }
                    let entries = try u32(body+4)
                    guard entries > 0, entries <= 64 else { throw ActionFailure.invalid }
                    var at = body+8
                    for _ in 0..<entries {
                        let (entry, payload, finish) = try header(at, end: next)
                        guard ["url ", "alis"].contains(entry), finish-payload == 4, try u32(payload) == 1 else { throw ActionFailure.invalid }
                        at = finish
                    }
                    guard at == next else { throw ActionFailure.invalid }
                    references += 1
                } else if ["moov", "trak", "mdia", "minf", "dinf", "stbl"].contains(type) {
                    try walk(body, next, depth+1)
                }
                offset = next
            }
        }
        try walk(0, data.count, 0)
        guard movie, media, references > 0 else { throw ActionFailure.invalid }
    }
}
