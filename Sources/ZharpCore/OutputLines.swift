import Foundation

/// Which of the process's outputs a line was printed to.
public enum OutputStreamName: String {
    case stdout
    case stderr
}

/// A printed line as a log record: its level, its message and what else the line said.
public struct CapturedLine: Equatable {
    public let level: LogLevel
    public let body: String
    public let attributes: [String: String]

    public init(level: LogLevel, body: String, attributes: [String: String] = [:]) {
        self.level = level
        self.body = body
        self.attributes = attributes
    }
}

/// Reads a line the app printed (`print`, `NSLog`, a logging library writing to stdout or
/// stderr) for its level and message.
///
/// The level comes from the line itself: a JSON record's `level`/`severity` (a word, or a pino
/// style number), or the first level word near its start (`ERROR`, `[warn]`, `level=error`,
/// `Fatal error:`). Failing that, stdout is info and stderr a warning, except `NSLog`, which
/// writes everything to stderr: its lines are info. `NSLog`'s own prefix (date, process, pid and
/// thread) is dropped from the message.
public enum OutputLineParser {
    /// The longest line kept, in UTF-8 bytes; longer lines are cut.
    public static let maxLineBytes = 32 * 1024

    /// The prefix the SDK's own console lines start with. They describe the reporting, not the
    /// app, so they are never sent.
    public static let ownPrefix = "[Zharp]"

    private static let levels: [String: LogLevel] = [
        "trace": .debug, "verbose": .debug, "debug": .debug,
        "log": .info, "info": .info, "notice": .info, "default": .info,
        "warn": .warn, "warning": .warn,
        "err": .error, "error": .error,
        "crit": .fatal, "critical": .fatal, "fatal": .fatal, "fault": .fatal, "emerg": .fatal, "alert": .fatal,
    ]

    private static let ansi = try! NSRegularExpression(pattern: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]")
    /// `2026-11-17 09:11:22.123456+0000 MyApp[1234:56789] ` — what NSLog puts before a message.
    private static let nslog = try! NSRegularExpression(
        pattern: "^\\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2}:\\d{2}(?:\\.\\d+)?[+-]\\d{4} .+?\\[\\d+:[0-9a-fA-Fx]+\\] ?")
    /// The first level word in the opening of a line: `ERROR`, `[warn]`, `level=error`, `<Info>`.
    private static let word = try! NSRegularExpression(
        pattern: "(?:^|[\\s\\[(|:=<])(trace|verbose|debug|info|notice|warn(?:ing)?|err(?:or)?|crit(?:ical)?|fatal|fault|emerg|alert)(?=$|[\\s\\]):|,>])",
        options: [.caseInsensitive])

    /// The line as a record, or nil when there is nothing to send (blank, or the SDK's own).
    public static func parse(_ raw: String, stream: OutputStreamName) -> CapturedLine? {
        var line = stripANSI(cap(raw))
        while let last = line.unicodeScalars.last, CharacterSet.whitespacesAndNewlines.contains(last) {
            line.unicodeScalars.removeLast()
        }
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty, !line.contains(ownPrefix) else { return nil }

        var fromNSLog = false
        if stream == .stderr, let match = first(nslog, in: line) {
            line = String(line[match.upperBound...])
            fromNSLog = true
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        }
        let fallback: LogLevel = stream == .stdout || fromNSLog ? .info : .warn

        if line.hasPrefix("{"), line.hasSuffix("}"), let record = json(line) {
            let message = record["msg"] ?? record["message"] ?? record["event"]
            let found = OutputLineParser.level(of: record["level"] ?? record["severity"] ?? record["lvl"])
            return CapturedLine(level: found ?? fallback, body: (message as? String) ?? line)
        }

        let opening = String(line.prefix(120))
        var found: LogLevel?
        if let match = word.firstMatch(in: opening, range: NSRange(opening.startIndex..., in: opening)),
           let range = Range(match.range(at: 1), in: opening) {
            found = levels[opening[range].lowercased()]
        }
        return CapturedLine(level: found ?? fallback, body: line)
    }

    /// A JSON record's level: a word, or a number as pino and bunyan write it.
    static func level(of value: Any?) -> LogLevel? {
        if let text = value as? String { return levels[text.lowercased()] }
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            switch number.doubleValue {
            case 60...: return .fatal
            case 50..<60: return .error
            case 40..<50: return .warn
            case 30..<40: return .info
            default: return .debug
            }
        }
        return nil
    }

    public static func stripANSI(_ text: String) -> String {
        guard text.contains("\u{1B}") else { return text }
        return ansi.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
    }

    private static func cap(_ text: String) -> String {
        guard text.utf8.count > maxLineBytes else { return text }
        return String(decoding: text.utf8.prefix(maxLineBytes), as: UTF8.self)
    }

    private static func first(_ regex: NSRegularExpression, in text: String) -> Range<String.Index>? {
        guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return Range(match.range, in: text)
    }

    private static func json(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

/// Bytes read from an output, cut into lines. A line is at most `maxLineBytes`; a longer one is
/// sent in pieces. What's left without a newline waits for the rest (or for `flush`).
public struct LineBuffer {
    public let maxLineBytes: Int
    private var pending: [UInt8] = []

    public init(maxLineBytes: Int = OutputLineParser.maxLineBytes) {
        self.maxLineBytes = max(maxLineBytes, 1)
    }

    /// Whether an unfinished line is waiting.
    public var hasPending: Bool { !pending.isEmpty }

    /// Adds bytes; returns the lines they complete, without their newline (or `\r\n`).
    public mutating func append<Bytes: Sequence>(_ bytes: Bytes) -> [String] where Bytes.Element == UInt8 {
        var lines: [String] = []
        for byte in bytes {
            if byte == 0x0A {
                lines.append(take())
            } else {
                pending.append(byte)
                if pending.count >= maxLineBytes { lines.append(take()) }
            }
        }
        return lines
    }

    /// The unfinished line, if any, as a line of its own.
    public mutating func flush() -> String? {
        pending.isEmpty ? nil : take()
    }

    private mutating func take() -> String {
        var bytes = pending
        pending.removeAll(keepingCapacity: true)
        if bytes.last == 0x0D { bytes.removeLast() }
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// What the exact captures (`Zharp.log`, the swift-log handler, errors) sent in the last few
/// seconds, so the same text reaching stdout or stderr a moment later isn't sent again — a
/// swift-log `MultiplexLogHandler` that also prints, CocoaLumberjack's TTY logger, and so on.
public final class RecentLines: @unchecked Sendable {
    private let window: TimeInterval
    private let capacity: Int
    private let now: () -> Date
    private let lock = NSLock()
    private var recent: [(at: Date, text: String)] = []

    public init(window: TimeInterval = 3, capacity: Int = 500, now: @escaping () -> Date = Date.init) {
        self.window = window
        self.capacity = capacity
        self.now = now
    }

    /// A body an exact capture just sent.
    public func remember(_ body: String) {
        let text = RecentLines.normalise(body)
        guard text.count >= 4 else { return }
        let at = now()
        lock.lock()
        recent.append((at: at, text: text))
        if recent.count > capacity { recent.removeFirst(recent.count - capacity) }
        lock.unlock()
    }

    /// Whether a printed line is one already sent: its text contains a recent body. A match is
    /// used up, so the same text printed twice on purpose is still sent the second time.
    public func alreadySent(_ line: String) -> Bool {
        let at = now()
        lock.lock()
        defer { lock.unlock() }
        if let firstFresh = recent.firstIndex(where: { at.timeIntervalSince($0.at) <= window }) {
            if firstFresh > 0 { recent.removeFirst(firstFresh) }
        } else {
            recent.removeAll()
        }
        guard !recent.isEmpty else { return false }
        let text = RecentLines.normalise(line)
        for index in recent.indices.reversed() where text.contains(recent[index].text) {
            recent.remove(at: index)
            return true
        }
        return false
    }

    static func normalise(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

/// Which unified-log entries are the app's own: those from its executable, or under a subsystem
/// that isn't Apple's (the app's, or a library it ships) — never Zharp's.
public enum OSLogFilter {
    public static func isApps(subsystem: String, sender: String, executable: String?) -> Bool {
        if subsystem.hasPrefix("io.zharp") { return false }
        if !subsystem.isEmpty { return !subsystem.hasPrefix("com.apple.") }
        return executable.map { !$0.isEmpty && sender == $0 } ?? false
    }
}
