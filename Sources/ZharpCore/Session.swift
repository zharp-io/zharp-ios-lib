import Foundation

/// The session rules every Zharp client SDK follows: a session lasts while the app is used, and a
/// new one starts after 30 minutes in the background, or when the user signs out (`clearUser`).
/// A cold launch starts a new session.
public struct SessionRules: Equatable {
    public static let backgroundTimeout: TimeInterval = 30 * 60

    public private(set) var id: String
    /// When the app went to the background; nil while it is in the foreground.
    public private(set) var backgroundedAt: Date?

    public init(id: String = SessionRules.newId()) {
        self.id = id
    }

    public static func newId() -> String {
        UUID().uuidString.lowercased()
    }

    public mutating func didEnterBackground(at now: Date) {
        if backgroundedAt == nil { backgroundedAt = now }
    }

    /// The session for telemetry recorded now. While the app has been in the background for the
    /// timeout or longer, a new session starts (and counts as backgrounded from now on).
    /// Returns true when the id changed.
    @discardableResult
    public mutating func current(at now: Date, newId: () -> String = SessionRules.newId) -> Bool {
        guard let since = backgroundedAt, now.timeIntervalSince(since) >= Self.backgroundTimeout else { return false }
        id = newId()
        backgroundedAt = now
        return true
    }

    /// Back in the foreground. Returns true when the time away started a new session.
    @discardableResult
    public mutating func willEnterForeground(at now: Date, newId: () -> String = SessionRules.newId) -> Bool {
        let changed = current(at: now, newId: newId)
        backgroundedAt = nil
        return changed
    }

    /// A new session regardless of time, for `clearUser()`.
    public mutating func restart(newId: () -> String = SessionRules.newId) {
        id = newId()
    }
}

public struct UserInfo: Codable, Equatable {
    public var id: String
    public var email: String?
    public var name: String?

    public init(id: String, email: String? = nil, name: String? = nil) {
        self.id = id
        self.email = email
        self.name = name
    }
}

/// What is true right now about the app's use: session, user, screen, tags. Added to every span
/// and log record, and saved to disk so a crash reported on the next launch carries the context
/// it happened in.
public struct ContextSnapshot: Codable, Equatable {
    public var sessionId: String
    public var user: UserInfo?
    public var screen: String?
    public var tags: [String: String]
    /// The release that was running, so a crash sent after an update keeps its own release.
    public var release: String?

    public init(sessionId: String, user: UserInfo? = nil, screen: String? = nil,
                tags: [String: String] = [:], release: String? = nil) {
        self.sessionId = sessionId
        self.user = user
        self.screen = screen
        self.tags = tags
        self.release = release
    }

    /// Tags first, so a tag can never replace the session or user.
    public func attributes() -> [String: AttrValue] {
        var out: [String: AttrValue] = [:]
        for (key, value) in tags where !key.isEmpty { out[key] = .string(value) }
        out[Keys.sessionId] = .string(sessionId)
        if let user = user {
            out[Keys.userId] = .string(user.id)
            if let email = user.email, !email.isEmpty { out[Keys.userEmail] = .string(email) }
            if let name = user.name, !name.isEmpty { out[Keys.userName] = .string(name) }
        }
        if let screen = screen, !screen.isEmpty { out[Keys.screenName] = .string(screen) }
        return out
    }
}

/// Screen names and screen-view spans.
public enum ScreenNaming {
    /// A view controller's class name as a screen name: no module prefix, no generic arguments.
    /// "MyApp.CheckoutViewController" → "CheckoutViewController".
    public static func name(fromClassName raw: String) -> String {
        var name = raw
        if let generic = name.firstIndex(of: "<") { name = String(name[..<generic]) }
        if let dot = name.lastIndex(of: ".") { name = String(name[name.index(after: dot)...]) }
        name = name.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? raw : name
    }

    /// The root span for a screen view.
    public static func spanName(_ screen: String) -> String {
        "screen \(screen)"
    }

    /// SwiftUI can call `onAppear` more than once for one appearance; the same screen again
    /// within the window is the same view.
    public static func isRepeat(previous: String?, previousAt: Date?, name: String, now: Date,
                                window: TimeInterval = 1) -> Bool {
        guard let previous = previous, let previousAt = previousAt else { return false }
        return previous == name && now.timeIntervalSince(previousAt) < window
    }
}
