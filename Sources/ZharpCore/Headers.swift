import Foundation

/// Request and response headers on HTTP CLIENT spans, as OpenTelemetry names them
/// (`http.request.header.user-agent`, `http.response.header.x-request-id`), so a failed request
/// shows what was sent and what came back — and what wasn't sent (no `authorization`). Secret
/// headers are recorded as `[Filtered]`: sent, but the value never leaves the device. The same
/// rules as every other Zharp SDK (the reference is @zharp/internal/headers in the JS SDK).
public enum HeaderAttributes {
    /// Secret whatever the key rules say.
    static let secret: Set<String> = [
        "authorization", "proxy-authorization", "cookie", "set-cookie", "x-api-key", "x-auth-token", "x-csrf-token", "x-xsrf-token",
    ]
    /// Per side, so a request stuffed with headers can't fill the span.
    static let maxHeaders = 40
    static let maxValue = 512

    /// `http.<side>.header.<name>`: secrets filtered, long values cut, repeats joined.
    /// `side` is "request" or "response"; `redact` adds header names to treat as secret.
    public static func attributes(side: String, headers: [(String, String)], redact: [String] = []) -> [String: AttrValue] {
        var order: [String] = []
        var joined: [String: [String]] = [:]
        for (rawName, value) in headers {
            let name = rawName.lowercased()
            if joined[name] == nil {
                if order.count >= maxHeaders { continue }
                order.append(name)
            }
            joined[name, default: []].append(value)
        }
        let extra = redact.map { BodyAttributes.normalize($0) }
        var out: [String: AttrValue] = [:]
        for name in order {
            let isSecret = secret.contains(name) || BodyAttributes.isSecretKey(name) || extra.contains(BodyAttributes.normalize(name))
            let text = (joined[name] ?? []).joined(separator: ", ")
            out["http.\(side).header.\(name)"] = .string(isSecret ? BodyAttributes.filtered : cut(text))
        }
        return out
    }

    static func cut(_ text: String) -> String {
        text.count > maxValue ? String(text.prefix(maxValue)) + "…" : text
    }
}
