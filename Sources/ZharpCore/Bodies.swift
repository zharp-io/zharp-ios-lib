import Foundation

/// Request and response bodies on request spans (`captureBodies`), and secrets in URLs. The same
/// rules as every other Zharp SDK:
///
/// - Field names always stay; values under keys that look secret (`password`, `token`,
///   `authorization`, `card`, …) become `[Filtered]` before anything leaves the device. Under a
///   secret object every value is filtered and its keys kept.
/// - An inline image or other long base64 value becomes `[image/png · 24 KB]`, a file in a form
///   upload `[file photo.png · image/png · 240 KB]`, and a body that is not text a description
///   (`[binary · application/pdf · 1.2 MB]`, `[event stream]`).
/// - Text is capped (32 KB by default, at most 128 KB) and `http.*.body.truncated` says so.
///
/// They travel as `http.request.body` and `http.response.body`, which the trace view shows as a
/// formatted payload.
public struct BodySettings: Equatable {
    public enum Mode: Equatable { case errors, all }

    public static let defaultMaxSize = 32 * 1024
    public static let largestMaxSize = 128 * 1024

    public let mode: Mode
    /// Characters kept per body.
    public let maxSize: Int
    /// More keys filtered: compared ignoring case, `-` and `_`.
    public let redactKeys: [String]
    /// More keys filtered: tested against the key as it is.
    public let redactPatterns: [NSRegularExpression]

    public init(mode: Mode, maxSize: Int? = nil, redactKeys: [String] = [], redactPatterns: [NSRegularExpression] = []) {
        self.mode = mode
        if let size = maxSize, size > 0 {
            self.maxSize = min(size, BodySettings.largestMaxSize)
        } else {
            self.maxSize = BodySettings.defaultMaxSize
        }
        self.redactKeys = redactKeys
        self.redactPatterns = redactPatterns
    }

    /// Raw text read before shortening and capping: inline images shrink to a few words, so more
    /// is read than is kept.
    public var rawLimit: Int { max(64 * 1024, maxSize * 2) }

    /// Whether a request with this outcome has its bodies kept. 0 means no response.
    public func wanted(status: Int) -> Bool {
        mode == .all || status <= 0 || status >= 400
    }
}

public enum BodyAttributes {
    public static let filtered = "[Filtered]"

    public static let request = "http.request.body"
    public static let requestTruncated = "http.request.body.truncated"
    public static let requestType = "http.request.header.content-type"
    public static let response = "http.response.body"
    public static let responseTruncated = "http.response.body.truncated"
    public static let responseType = "http.response.header.content-type"

    public enum Side { case request, response }

    // MARK: Content types

    static func mime(_ contentType: String?) -> String {
        guard let contentType = contentType else { return "" }
        let first = contentType.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        return first.trimmingCharacters(in: .whitespaces).lowercased()
    }

    public static func isEventStream(_ contentType: String?) -> Bool { mime(contentType) == "text/event-stream" }

    public static func isMultipart(_ contentType: String?) -> Bool { mime(contentType) == "multipart/form-data" }

    static func isForm(_ contentType: String?) -> Bool { mime(contentType) == "application/x-www-form-urlencoded" }

    private static let textualApplication: Set<String> = [
        "application/json", "application/xml", "application/x-www-form-urlencoded", "application/graphql",
        "application/javascript", "application/x-ndjson", "application/ld+json",
    ]

    /// Whether a body of this type is text worth showing. An unknown type is given the benefit of the doubt.
    public static func isTextual(_ contentType: String?) -> Bool {
        let type = mime(contentType)
        if type.isEmpty { return true }
        if type == "text/event-stream" { return false }
        return type.hasPrefix("text/") || type.hasSuffix("+json") || type.hasSuffix("+xml") || textualApplication.contains(type)
    }

    /// `240 KB`, `1.4 MB`.
    public static func formatSize(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return "\(Int((Double(bytes) / 1024).rounded())) KB" }
        return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
    }

    /// How a file in a form upload is shown: `[file photo.png · image/png · 240 KB]`.
    public static func fileLabel(name: String?, type: String?, size: Int?, partial: Bool = false) -> String {
        var parts = ["file \((name?.isEmpty ?? true) ? "blob" : name!)"]
        if let type = type, !type.isEmpty { parts.append(type) }
        if let size = size { parts.append(formatSize(size) + (partial ? "+" : "")) }
        return "[\(parts.joined(separator: " · "))]"
    }

    /// What a body that is not text says instead: `[binary · image/png · 24 KB]`, `[event stream]`.
    public static func describe(contentType: String?, size: Int? = nil, partial: Bool = false) -> String {
        if isEventStream(contentType) { return "[event stream]" }
        var parts = ["binary"]
        let type = mime(contentType)
        if !type.isEmpty { parts.append(type) }
        if let size = size, size > 0 { parts.append(formatSize(size) + (partial ? "+" : "")) }
        return "[\(parts.joined(separator: " · "))]"
    }

    // MARK: Redaction

    /// Built-in keys whose values never leave the device, compared without case, `-` or `_`.
    static let secretFragments = [
        "password", "passwd", "passphrase", "secret", "token", "apikey", "accesskey", "privatekey",
        "authorization", "cookie", "creditcard", "cardnumber", "cvv", "cvc", "ssn", "iban", "sessionid",
        "signature", "credential",
    ]
    static let exact: Set<String> = ["auth", "pin", "pwd", "otp", "card", "pan", "jwt", "sid", "codeverifier"]
    /// Also secret in a query string, where they are API keys and signed-URL signatures.
    static let urlExact: Set<String> = ["key", "sig", "code", "state", "session"]

    static func normalize(_ key: String) -> String {
        String(key.lowercased().unicodeScalars.filter { ("a"..."z").contains($0) || ("0"..."9").contains($0) })
    }

    public static func isSecretKey(_ key: String, settings: BodySettings? = nil) -> Bool {
        let k = normalize(key)
        if k.isEmpty { return false }
        if exact.contains(k) || secretFragments.contains(where: { k.contains($0) }) { return true }
        guard let settings = settings else { return false }
        if settings.redactKeys.contains(where: { normalize($0) == k }) { return true }
        let range = NSRange(key.startIndex..., in: key)
        return settings.redactPatterns.contains { $0.firstMatch(in: key, options: [], range: range) != nil }
    }

    private static let dataURI = try! NSRegularExpression(pattern: "^data:([\\w.+-]+/[\\w.+-]+)?(?:;[\\w=.+-]+)*;base64,([A-Za-z0-9+/=\\s]*)$")
    private static let base64 = try! NSRegularExpression(pattern: "^[A-Za-z0-9+/_-]{256,}={0,2}$")
    private static let base64Hint = try! NSRegularExpression(pattern: "[0-9+/]")

    private static func utf16Length(_ s: String) -> Int { (s as NSString).length }

    /// A long base64 value as a short description; other strings as they are.
    static func shorten(_ value: String) -> String {
        let length = utf16Length(value)
        if length < 256 { return value }
        let range = NSRange(location: 0, length: length)
        if let m = dataURI.firstMatch(in: value, options: [], range: range) {
            let ns = value as NSString
            let type = m.range(at: 1).location != NSNotFound ? ns.substring(with: m.range(at: 1)) : "data"
            let payload = m.range(at: 2).location != NSNotFound ? m.range(at: 2).length : 0
            return "[\(type) · \(formatSize(payload * 3 / 4))]"
        }
        if base64.firstMatch(in: value, options: [], range: range) != nil,
           base64Hint.firstMatch(in: value, options: [], range: range) != nil {
            return "[base64 · \(formatSize(length * 3 / 4))]"
        }
        return value
    }

    /// Every value under `value` filtered, its keys kept.
    static func filterAll(_ value: Any, depth: Int) -> Any {
        if depth > 20 { return filtered }
        if value is NSNull { return value }
        if let s = value as? String, s.isEmpty { return value }
        if let array = value as? [Any] { return array.map { filterAll($0, depth: depth + 1) } }
        if let object = value as? [String: Any] { return object.mapValues { filterAll($0, depth: depth + 1) } }
        return filtered
    }

    static func redact(_ value: Any, settings: BodySettings, depth: Int = 0) -> Any {
        if let s = value as? String { return shorten(s) }
        if depth > 20 { return value }
        if let array = value as? [Any] { return array.map { redact($0, settings: settings, depth: depth + 1) } }
        if let object = value as? [String: Any] {
            var out: [String: Any] = [:]
            for (k, v) in object {
                out[k] = isSecretKey(k, settings: settings) ? filterAll(v, depth: depth + 1) : redact(v, settings: settings, depth: depth + 1)
            }
            return out
        }
        return value
    }

    /// Each match replaced by what `transform` returns for it (nil keeps the match).
    static func replacing(_ regex: NSRegularExpression, in text: String, _ transform: (NSTextCheckingResult, NSString) -> String?) -> String {
        let ns = text as NSString
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length))
        if matches.isEmpty { return text }
        let out = NSMutableString(string: ns)
        for m in matches.reversed() {
            if let replacement = transform(m, ns) { out.replaceCharacters(in: m.range, with: replacement) }
        }
        return out as String
    }

    private static let runs = try! NSRegularExpression(
        pattern: "\"((?:data:[\\w.+-]+/[\\w.+-]+(?:;[\\w=.+-]+)*;base64,)?[A-Za-z0-9+/_=-]{256,})(\"?)")
    private static let pairs = try! NSRegularExpression(
        pattern: "(\"([^\"\\\\]{1,100})\"\\s*:\\s*)(\"(?:[^\"\\\\]|\\\\.)*\"?|-?\\d[\\d.eE+-]*|true|false)")

    /// Text that did not parse (cut-off JSON, a body that only looks like JSON): `"key": value`
    /// pairs under secret keys are filtered where they appear, and long base64 runs shortened.
    static func redactLoose(_ text: String, settings: BodySettings) -> String {
        let shortened = replacing(runs, in: text) { m, ns in
            let run = ns.substring(with: m.range(at: 1))
            let closed = m.range(at: 2).length > 0
            let short = shorten(run)
            if short == run { return nil }
            return closed ? "\"\(short)\"" : "\"\(short.dropLast())+]\""
        }
        return replacing(pairs, in: shortened) { m, ns in
            let key = ns.substring(with: m.range(at: 2))
            guard isSecretKey(key, settings: settings) else { return nil }
            return "\(ns.substring(with: m.range(at: 1)))\"\(filtered)\""
        }
    }

    private static func decodeComponent(_ s: String) -> String {
        s.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? s
    }

    static func redactForm(_ text: String, settings: BodySettings) -> String {
        text.components(separatedBy: "&").map { pair -> String in
            guard let eq = pair.firstIndex(of: "=") else { return pair }
            let rawKey = String(pair[..<eq])
            let value = String(pair[pair.index(after: eq)...])
            if isSecretKey(decodeComponent(rawKey), settings: settings) { return "\(rawKey)=\(filtered)" }
            if utf16Length(value) >= 256 {
                let decoded = decodeComponent(value)
                let short = shorten(decoded)
                if short != decoded { return "\(rawKey)=\(short)" }
            }
            return pair
        }.joined(separator: "&")
    }

    // MARK: The attribute value

    /// JSON as the other SDKs write it: no escaped slashes. Keys are sorted (JSONSerialization
    /// keeps no order).
    static func json(_ value: Any) -> String? {
        let options: JSONSerialization.WritingOptions = [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes]
        guard JSONSerialization.isValidJSONObject(value) || value is String || value is NSNumber || value is NSNull,
              let data = try? JSONSerialization.data(withJSONObject: value, options: options)
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// A body as it is sent: redacted, then cut to `maxSize`. `cut` says the text was already cut
    /// short where it was read. Nil for an empty body.
    public static func format(_ text: String?, contentType: String?, settings: BodySettings, cut: Bool = false) -> (value: String, truncated: Bool)? {
        guard let text = text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        var body = text
        if isForm(contentType) {
            body = redactForm(body, settings: settings)
        } else {
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            var parsed: Any?
            if !cut, trimmed.hasPrefix("{") || trimmed.hasPrefix("["), let data = trimmed.data(using: .utf8) {
                parsed = try? JSONSerialization.jsonObject(with: data, options: [])
            }
            if let parsed = parsed, let out = json(redact(parsed, settings: settings)) {
                body = out
            } else {
                body = redactLoose(body, settings: settings)
            }
        }
        let length = utf16Length(body)
        let truncated = cut || length > settings.maxSize
        if length > settings.maxSize { body = (body as NSString).substring(to: settings.maxSize) }
        return (body, truncated)
    }

    private static func keys(_ side: Side) -> (body: String, truncated: String, type: String) {
        side == .request ? (request, requestTruncated, requestType) : (response, responseTruncated, responseType)
    }

    /// The span attributes for one side of a request. Empty when there is nothing to show, or the
    /// type is not text (use `described` for those).
    public static func attributes(_ side: Side, text: String?, contentType: String?, settings: BodySettings, cut: Bool = false) -> [String: AttrValue] {
        guard isTextual(contentType) || isMultipart(contentType),
              let formatted = format(text, contentType: contentType, settings: settings, cut: cut)
        else { return [:] }
        let k = keys(side)
        var out: [String: AttrValue] = [k.body: .string(formatted.value)]
        if formatted.truncated { out[k.truncated] = .bool(true) }
        if let type = contentType, !type.isEmpty { out[k.type] = .string(type) }
        return out
    }

    /// The attributes for a body already redacted, capped here.
    static func attributes(_ side: Side, formatted body: String, contentType: String?, settings: BodySettings, cut: Bool) -> [String: AttrValue] {
        let k = keys(side)
        let length = utf16Length(body)
        let value = length > settings.maxSize ? (body as NSString).substring(to: settings.maxSize) : body
        var out: [String: AttrValue] = [k.body: .string(value)]
        if cut || length > settings.maxSize { out[k.truncated] = .bool(true) }
        if let type = contentType, !type.isEmpty { out[k.type] = .string(type) }
        return out
    }

    /// The attributes for a body that is not text: what it was, not what it said.
    public static func described(_ side: Side, contentType: String?, size: Int? = nil, partial: Bool = false) -> [String: AttrValue] {
        let k = keys(side)
        var out: [String: AttrValue] = [k.body: .string(describe(contentType: contentType, size: size, partial: partial))]
        if let type = contentType, !type.isEmpty { out[k.type] = .string(type) }
        return out
    }

    /// A body held in memory: text kept, a form upload as its fields, anything else described.
    public static func attributes(_ side: Side, data: Data, contentType: String?, settings: BodySettings) -> [String: AttrValue] {
        if data.isEmpty { return [:] }
        if isMultipart(contentType), let boundary = boundary(of: contentType) {
            // Redacted field by field, in the order sent (a JSON round trip would sort them).
            let summary = Multipart.summarize(data, boundary: boundary, maxText: settings.maxSize)
            let fields: [(String, Any)] = summary.fields.map { field in
                let (key, value) = field
                let shown: Any = isSecretKey(key, settings: settings) ? filterAll(value, depth: 1) : redact(value, settings: settings, depth: 1)
                return (key, shown)
            }
            return attributes(side, formatted: Multipart.orderedJSON(fields), contentType: contentType, settings: settings, cut: summary.cut)
        }
        guard isTextual(contentType) else { return described(side, contentType: contentType, size: data.count) }
        let limit = settings.rawLimit
        let slice = data.count > limit ? data.prefix(limit) : data
        guard let text = decodeUTF8(slice) else { return described(side, contentType: contentType, size: data.count) }
        return attributes(side, text: text, contentType: contentType, settings: settings, cut: data.count > limit)
    }

    /// UTF-8 text, tolerating a character split at the cut.
    static func decodeUTF8(_ data: Data) -> String? {
        if let s = String(data: data, encoding: .utf8) { return s }
        for drop in 1...3 where data.count > drop {
            if let s = String(data: data.dropLast(drop), encoding: .utf8) { return s }
        }
        return nil
    }

    static func boundary(of contentType: String?) -> String? {
        guard let contentType = contentType,
              let regex = try? NSRegularExpression(pattern: "boundary=(?:\"([^\"]+)\"|([^;\\s]+))", options: [.caseInsensitive])
        else { return nil }
        let ns = contentType as NSString
        guard let m = regex.firstMatch(in: contentType, options: [], range: NSRange(location: 0, length: ns.length)) else { return nil }
        if m.range(at: 1).location != NSNotFound { return ns.substring(with: m.range(at: 1)) }
        if m.range(at: 2).location != NSNotFound { return ns.substring(with: m.range(at: 2)) }
        return nil
    }

    // MARK: URLs

    /// A URL as it is recorded: query values under secret-looking keys (`token`, `key`, `sig`,
    /// `password`, …) become `[Filtered]`, and `user:password@` is dropped.
    public static func redactURL(_ url: String) -> String {
        if url.isEmpty { return url }
        var out = url
        if let userInfo = try? NSRegularExpression(pattern: "^([a-z][a-z0-9+.-]*://)[^/?#@]*@", options: [.caseInsensitive]) {
            let ns = out as NSString
            out = userInfo.stringByReplacingMatches(in: out, options: [], range: NSRange(location: 0, length: ns.length), withTemplate: "$1")
        }
        guard let q = out.firstIndex(of: "?") else { return out }
        let afterQ = out.index(after: q)
        let hash = out[afterQ...].firstIndex(of: "#")
        let query = String(out[afterQ..<(hash ?? out.endIndex)])
        let redacted = redactQuery(query)
        if redacted == query { return out }
        return String(out[..<afterQ]) + redacted + (hash.map { String(out[$0...]) } ?? "")
    }

    /// A query string (without `?`) with secret-looking values filtered.
    public static func redactQuery(_ query: String) -> String {
        if query.isEmpty { return query }
        return query.components(separatedBy: "&").map { pair -> String in
            guard let eq = pair.firstIndex(of: "=") else { return pair }
            let rawKey = String(pair[..<eq])
            let key = decodeComponent(rawKey)
            let secret = isSecretKey(key) || urlExact.contains(normalize(key))
            let hasValue = pair.index(after: eq) < pair.endIndex
            return secret && hasValue ? "\(rawKey)=\(filtered)" : pair
        }.joined(separator: "&")
    }
}

// MARK: - multipart/form-data

/// A form upload as its fields: text fields kept (up to `maxText` each), each file as its name,
/// type and size. Field order is kept.
enum Multipart {
    static let maxFields = 200

    static func summarize(_ data: Data, boundary: String, maxText: Int) -> (fields: [(String, Any)], cut: Bool) {
        var fields: [(String, Any)] = []
        var cut = false
        let first = Data("--\(boundary)".utf8)
        let delimiter = Data("\r\n--\(boundary)".utf8)
        let headerEnd = Data("\r\n\r\n".utf8)

        guard var position = data.range(of: first)?.upperBound else { return ([], false) }
        while position < data.endIndex {
            // After a delimiter: "--" ends the upload, CRLF starts a part.
            if data.count - (position - data.startIndex) >= 2,
               data[position] == 45, data[data.index(after: position)] == 45 { break }
            if data.count - (position - data.startIndex) >= 2,
               data[position] == 13, data[data.index(after: position)] == 10 { position = data.index(position, offsetBy: 2) }
            guard let headEnd = data.range(of: headerEnd, in: position..<data.endIndex) else { cut = true; break }
            let head = String(decoding: data[position..<headEnd.lowerBound], as: UTF8.self)
            let part = parseHeaders(head)
            let bodyStart = headEnd.upperBound
            let found = data.range(of: delimiter, in: bodyStart..<data.endIndex)
            let bodyEnd = found?.lowerBound ?? data.endIndex
            let size = bodyEnd - bodyStart
            let partial = found == nil
            let value: Any
            if part.filename != nil {
                value = BodyAttributes.fileLabel(name: part.filename, type: part.type, size: size, partial: partial)
            } else {
                let kept = data[bodyStart..<data.index(bodyStart, offsetBy: min(size, maxText))]
                value = BodyAttributes.decodeUTF8(Data(kept)) ?? ""
                if size > maxText { cut = true }
            }
            if partial { cut = true }
            if let index = fields.firstIndex(where: { $0.0 == part.name }) {
                let existing = fields[index].1
                fields[index].1 = (existing as? [Any] ?? [existing]) + [value]
            } else {
                fields.append((part.name, value))
            }
            if fields.count >= maxFields { cut = true; break }
            guard let delimiterRange = found else { break }
            position = delimiterRange.upperBound
        }
        return (fields, cut)
    }

    struct Part { var name: String; var filename: String?; var type: String? }

    static func parseHeaders(_ head: String) -> Part {
        var disposition = ""
        var type: String?
        for line in head.components(separatedBy: "\r\n") {
            let lower = line.lowercased()
            if lower.hasPrefix("content-disposition:") { disposition = String(line.dropFirst("content-disposition:".count)) }
            if lower.hasPrefix("content-type:") { type = line.dropFirst("content-type:".count).trimmingCharacters(in: .whitespaces) }
        }
        let name = match("\\bname=\"([^\"]*)\"", in: disposition) ?? match("\\bname=([^;\\s]+)", in: disposition) ?? ""
        var filename = match("\\bfilename=\"([^\"]*)\"", in: disposition)
        if let star = match("\\bfilename\\*=(?:UTF-8'')?([^;\\s]+)", in: disposition) {
            filename = star.removingPercentEncoding ?? star
        }
        return Part(name: name, filename: filename, type: filename != nil ? type : nil)
    }

    static func match(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = text as NSString
        guard let m = regex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: ns.length)),
              m.range(at: 1).location != NSNotFound
        else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    /// `{"a":…,"b":…}` in the order given (JSONSerialization would sort or shuffle the keys).
    static func orderedJSON(_ fields: [(String, Any)]) -> String {
        let parts: [String] = fields.map { field in
            let (key, value) = field
            return "\(BodyAttributes.json(key) ?? "\"\""):\(BodyAttributes.json(value) ?? "null")"
        }
        return "{\(parts.joined(separator: ","))}"
    }
}
