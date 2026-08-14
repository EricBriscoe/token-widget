import Foundation

/// A harness that writes JSONL transcripts we can mine for token usage.
public protocol TranscriptProvider: Sendable {
    var provider: Provider { get }
    /// Directories to walk for `.jsonl` files.
    var roots: [URL] { get }
    /// One parser per file. Some formats (Codex) state the model on a different
    /// line from the token counts, so parsing needs a place to keep state.
    func makeParser(file: URL, resuming state: ParserState?) -> TranscriptLineParser
}

/// Parser state that has to survive between incremental passes over a file
/// that is still being appended to.
public struct ParserState: Codable, Sendable, Equatable {
    public var lastModel: String?
    public init(lastModel: String? = nil) { self.lastModel = lastModel }
}

public protocol TranscriptLineParser: AnyObject {
    /// Cheap byte test run before the JSON decode, so the vast majority of
    /// lines (user turns, file snapshots) never reach the decoder.
    func mayContainUsage(_ line: Data) -> Bool
    /// Decode one line. Returns nil for anything that is not a billable
    /// assistant message.
    func record(from line: Data) -> UsageRecord?
    /// State to carry into the next incremental pass over this file.
    var state: ParserState { get }
}

extension TranscriptProvider {
    /// Roots present on this machine.
    public var presentRoots: [URL] {
        roots.filter { url in
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            return exists && isDirectory.boolValue
        }
    }
}

/// FNV-1a, used to shrink message identities into 8 bytes so the dedup index
/// for hundreds of thousands of messages stays a few megabytes on disk.
@inlinable
public func fnv1a64(_ string: String) -> UInt64 {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in string.utf8 {
        hash ^= UInt64(byte)
        hash &*= 0x0000_0100_0000_01B3
    }
    return hash
}

public enum TimestampParser {
    /// Parses `2026-08-12T21:08:44.391Z` and the same shape without the
    /// fractional part or with a numeric UTC offset. Hand-rolled because this
    /// runs once per assistant message across the whole transcript history.
    public static func parse(_ string: String) -> Date? {
        let bytes = Array(string.utf8)
        guard bytes.count >= 19 else { return nil }

        func number(_ range: Range<Int>) -> Int? {
            var value = 0
            for index in range {
                let byte = bytes[index]
                guard byte >= 48, byte <= 57 else { return nil }
                value = value * 10 + Int(byte - 48)
            }
            return value
        }

        guard bytes[4] == UInt8(ascii: "-"), bytes[7] == UInt8(ascii: "-"),
              bytes[10] == UInt8(ascii: "T") || bytes[10] == UInt8(ascii: " "),
              bytes[13] == UInt8(ascii: ":"), bytes[16] == UInt8(ascii: ":"),
              let year = number(0..<4), let month = number(5..<7), let day = number(8..<10),
              let hour = number(11..<13), let minute = number(14..<16), let second = number(17..<19)
        else { return nil }

        var index = 19
        var fraction = 0.0
        if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
            index += 1
            var scale = 0.1
            while index < bytes.count, bytes[index] >= 48, bytes[index] <= 57 {
                fraction += Double(bytes[index] - 48) * scale
                scale /= 10
                index += 1
            }
        }

        // Trailing zone: `Z`, or `+HH:MM` / `-HHMM`.
        var offsetSeconds = 0
        if index < bytes.count {
            let sign = bytes[index]
            if sign == UInt8(ascii: "+") || sign == UInt8(ascii: "-") {
                let digits = bytes[(index + 1)...].filter { $0 >= 48 && $0 <= 57 }
                if digits.count >= 4 {
                    let hours = Int(digits[0] - 48) * 10 + Int(digits[1] - 48)
                    let minutes = Int(digits[2] - 48) * 10 + Int(digits[3] - 48)
                    offsetSeconds = (hours * 3600 + minutes * 60) * (sign == UInt8(ascii: "-") ? -1 : 1)
                }
            }
        }

        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = calendar.date(from: components) else { return nil }
        return date.addingTimeInterval(fraction - Double(offsetSeconds))
    }
}
