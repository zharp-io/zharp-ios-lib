import Foundation

/// W3C Trace Context and Baggage headers for outgoing requests to the app's own back end.
public enum TracePropagation {
    public static let traceparentHeader = "traceparent"
    public static let baggageHeader = "baggage"

    /// `00-<trace id>-<span id>-<flags>`, or nil for ids that aren't valid W3C ids.
    public static func traceparent(traceId: String, spanId: String, sampled: Bool) -> String? {
        let trace = traceId.lowercased()
        let span = spanId.lowercased()
        guard isHex(trace, length: 32), isHex(span, length: 16),
              trace.contains(where: { $0 != "0" }), span.contains(where: { $0 != "0" })
        else { return nil }
        return "00-\(trace)-\(span)-\(sampled ? "01" : "00")"
    }

    /// The `baggage` header with Zharp's entries (`enduser.id`, `session.id`) added to whatever the
    /// request already carries; an existing entry with one of these keys is replaced. Entries with
    /// no value are left out. Nil when there is nothing to send.
    public static func baggage(_ entries: [(key: String, value: String?)], existing: String?) -> String? {
        let ours = entries.compactMap { entry -> (String, String)? in
            guard let value = entry.value, !value.isEmpty else { return nil }
            return (entry.key, value)
        }
        let ourKeys = Set(ours.map { $0.0 })
        var members: [String] = []
        for member in (existing ?? "").split(separator: ",") {
            let trimmed = member.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.split(separator: "=", maxSplits: 1).first.map {
                $0.trimmingCharacters(in: .whitespaces)
            } ?? ""
            if !ourKeys.contains(key) { members.append(trimmed) }
        }
        for (key, value) in ours { members.append("\(key)=\(percentEncode(value))") }
        return members.isEmpty ? nil : members.joined(separator: ",")
    }

    /// Percent-encodes everything outside the W3C baggage-octet range, and `%` itself.
    public static func percentEncode(_ value: String) -> String {
        let hex = Array("0123456789ABCDEF")
        var out = ""
        for byte in value.utf8 {
            if isBaggageOctet(byte) {
                out.append(Character(Unicode.Scalar(byte)))
            } else {
                out.append("%")
                out.append(hex[Int(byte >> 4)])
                out.append(hex[Int(byte & 0x0F)])
            }
        }
        return out
    }

    static func isBaggageOctet(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x25: return false // "%" starts an escape
        case 0x21, 0x23...0x2B, 0x2D...0x3A, 0x3C...0x5B, 0x5D...0x7E: return true
        default: return false
        }
    }

    static func isHex(_ text: String, length: Int) -> Bool {
        text.utf8.count == length && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

/// The `tracingOrigins` option: which hosts get `traceparent` and `baggage`. Never third parties
/// unless listed.
///
/// - `"api.example.com"` matches that host on any scheme and port.
/// - `"api.example.com:8443"` matches that host and port.
/// - `"*.example.com"` matches any subdomain of example.com (not example.com itself).
/// - `"https://api.example.com"` matches that origin: scheme, host and port.
public struct TracingOrigins: Equatable {
    struct Rule: Equatable {
        var scheme: String?
        var host: String
        var wildcard: Bool
        var port: Int?
    }

    let rules: [Rule]

    public init(_ patterns: [String]) {
        rules = patterns.compactMap(TracingOrigins.rule)
    }

    public var isEmpty: Bool { rules.isEmpty }

    public func matches(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased(), !host.isEmpty else { return false }
        let scheme = url.scheme?.lowercased()
        let port = url.port ?? TracingOrigins.defaultPort(scheme)
        return rules.contains { rule in
            if let ruleScheme = rule.scheme, ruleScheme != scheme { return false }
            if let rulePort = rule.port, rulePort != port { return false }
            if rule.wildcard { return host.hasSuffix("." + rule.host) }
            return host == rule.host
        }
    }

    static func rule(_ pattern: String) -> Rule? {
        var text = pattern.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { return nil }
        if text.contains("://") {
            guard let url = URL(string: text), let host = url.host, !host.isEmpty else { return nil }
            let scheme = url.scheme
            return Rule(scheme: scheme, host: host, wildcard: false, port: url.port ?? defaultPort(scheme))
        }
        if let slash = text.firstIndex(of: "/") { text = String(text[..<slash]) }
        var port: Int?
        if let colon = text.lastIndex(of: ":") {
            port = Int(text[text.index(after: colon)...])
            text = String(text[..<colon])
            if port == nil { return nil }
        }
        var wildcard = false
        if text.hasPrefix("*.") {
            wildcard = true
            text.removeFirst(2)
        }
        guard !text.isEmpty, !text.contains("*") else { return nil }
        return Rule(scheme: nil, host: text, wildcard: wildcard, port: port)
    }

    static func defaultPort(_ scheme: String?) -> Int? {
        switch scheme {
        case "https"?: return 443
        case "http"?: return 80
        default: return nil
        }
    }
}

/// Head sampling for traces (`sampleRate`). Errors, crashes and logs are never sampled.
public enum Sampling {
    public static func clampRate(_ rate: Double) -> Double {
        guard rate.isFinite else { return 1 }
        return min(max(rate, 0), 1)
    }

    /// A child follows its parent's decision; a root span is kept when the low 64 bits of its
    /// trace id fall under `rate` of the range — the same rule as OpenTelemetry's
    /// TraceIdRatioBased sampler, so every service sampling by trace id agrees.
    public static func decide(parentSampled: Bool?, traceIdLow: UInt64, rate: Double) -> Bool {
        if let parentSampled = parentSampled { return parentSampled }
        let rate = clampRate(rate)
        if rate >= 1 { return true }
        if rate <= 0 { return false }
        let bound = rate * Double(UInt64.max)
        if bound >= Double(UInt64.max) { return true }
        return traceIdLow < UInt64(bound)
    }
}
