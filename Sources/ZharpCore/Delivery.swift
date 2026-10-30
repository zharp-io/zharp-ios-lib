import Foundation

/// What to do with a batch after trying to send it (wire contract: 400 drop, 401/403 bad key,
/// 429/503 retry with backoff).
public enum UploadOutcome: Equatable {
    case sent
    /// The server will never accept this batch; delete it.
    case drop
    /// The key was rejected. Stop sending for `RetryPolicy.rejectedKeyPause` and say so once.
    case rejectedKey
    /// Try again later; `after` is the server's Retry-After, if it gave one.
    case retry(after: TimeInterval?)
}

public enum RetryPolicy {
    public static let rejectedKeyPause: TimeInterval = 60 * 60
    public static let firstBackoff: TimeInterval = 5
    public static let maxBackoff: TimeInterval = 5 * 60

    /// `statusCode` nil means the request didn't get a response (offline, timeout, DNS…).
    public static func outcome(statusCode: Int?, retryAfter: String? = nil, now: Date = Date()) -> UploadOutcome {
        guard let code = statusCode else { return .retry(after: nil) }
        switch code {
        case 200..<300:
            return .sent
        case 401, 403:
            return .rejectedKey
        case 408, 429, 500, 502, 503, 504:
            return .retry(after: retryAfterSeconds(retryAfter, now: now))
        default:
            return .drop
        }
    }

    /// Exponential backoff for the nth consecutive failure (1-based): 5 s, 10 s, 20 s … 5 min.
    public static func backoff(attempt: Int) -> TimeInterval {
        let exponent = min(max(attempt - 1, 0), 16)
        return min(firstBackoff * pow(2, Double(exponent)), maxBackoff)
    }

    /// A Retry-After header (seconds, or an HTTP date) as seconds from now, kept between 1 s and
    /// the maximum backoff.
    public static func retryAfterSeconds(_ header: String?, now: Date) -> TimeInterval? {
        guard let header = header?.trimmingCharacters(in: .whitespaces), !header.isEmpty else { return nil }
        var seconds: TimeInterval?
        if let value = Double(header) {
            seconds = value
        } else if let date = httpDateFormatter.date(from: header) {
            seconds = date.timeIntervalSince(now)
        }
        guard let found = seconds, found.isFinite else { return nil }
        return min(max(found, 1), maxBackoff)
    }

    private static let httpDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()
}

/// The offline buffer: each exported batch is one file, named so that names sort oldest first.
public enum OutboxPolicy {
    public static let maxBytes = 5 * 1024 * 1024
    public static let maxFiles = 300

    public struct Entry: Equatable {
        public var name: String
        public var size: Int

        public init(name: String, size: Int) {
            self.name = name
            self.size = size
        }
    }

    /// "001730000000000-000042.traces.gz"
    public static func fileName(kind: SignalKind, gzip: Bool, timestampMs: Int64, sequence: Int) -> String {
        let time = pad(String(max(timestampMs, 0)), to: 15)
        let seq = pad(String(abs(sequence) % 1_000_000), to: 6)
        return "\(time)-\(seq).\(kind.rawValue).\(gzip ? "gz" : "pb")"
    }

    /// The kind and encoding of an outbox file, or nil for anything else in the folder.
    public static func parse(_ name: String) -> (kind: SignalKind, gzip: Bool)? {
        let parts = name.split(separator: ".")
        guard parts.count == 3, let kind = SignalKind(rawValue: String(parts[1])) else { return nil }
        switch parts[2] {
        case "gz": return (kind, true)
        case "pb": return (kind, false)
        default: return nil
        }
    }

    /// Outbox files, oldest first.
    public static func ordered(_ names: [String]) -> [String] {
        names.filter { parse($0) != nil }.sorted()
    }

    /// The files to delete, oldest first, so that what is left is within both caps.
    public static func overflow(_ entries: [Entry], maxBytes: Int = maxBytes, maxFiles: Int = maxFiles) -> [String] {
        let sorted = entries.filter { parse($0.name) != nil }.sorted { $0.name < $1.name }
        var count = sorted.count
        var bytes = sorted.reduce(0) { $0 + max($1.size, 0) }
        var drop: [String] = []
        for entry in sorted where count > maxFiles || bytes > maxBytes {
            drop.append(entry.name)
            count -= 1
            bytes -= max(entry.size, 0)
        }
        return drop
    }

    private static func pad(_ text: String, to length: Int) -> String {
        text.count >= length ? text : String(repeating: "0", count: length - text.count) + text
    }
}
