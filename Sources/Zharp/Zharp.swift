import Foundation
import OpenTelemetryApi
import ZharpCore

/// Zharp Application Monitoring for iOS.
///
/// ```swift
/// Zharp.start { options in
///     options.key = "zpk_…"
///     options.service = "shop-ios"
///     options.environment = "production"
/// }
/// Zharp.setUser(id: user.id, email: user.email)
/// ```
///
/// Every call is safe before `start` (it does nothing) and from any thread, and none of them
/// throws or crashes the app.
public enum Zharp {
    /// `Zharp.log.info("Checkout started", ["items": 3])`
    public static let log = ZharpLog()

    /// Starts the SDK. Call it once, as early as possible — in `application(_:didFinishLaunchingWithOptions:)`
    /// or your SwiftUI `App`'s `init()` — so crashes and the first screens are captured.
    public static func start(_ configure: (ZharpOptions) -> Void) {
        let options = ZharpOptions()
        configure(options)
        ZharpRuntime.start(options: options)
    }

    /// Whether `start` succeeded.
    public static var isStarted: Bool {
        ZharpRuntime.shared != nil
    }

    /// The current session id (`session.id`), or nil before `start`.
    public static var sessionId: String? {
        ZharpRuntime.shared?.context.snapshot().sessionId
    }

    /// Who is using the app, from now on (`enduser.id`, `enduser.email`, `enduser.name`). Pass
    /// whatever identifies the user to you: an id or an email.
    public static func setUser(id: String, email: String? = nil, name: String? = nil) {
        guard !id.isEmpty else { return }
        ZharpRuntime.shared?.context.setUser(UserInfo(id: id, email: email, name: name))
    }

    /// Signs the user out of Zharp's context and starts a new session.
    public static func clearUser() {
        ZharpRuntime.shared?.context.clearUser()
    }

    /// An attribute on everything recorded from now on: `Zharp.setTag("plan", "pro")`.
    /// `nil` removes it.
    public static func setTag(_ key: String, _ value: String?) {
        guard !key.isEmpty else { return }
        ZharpRuntime.shared?.context.setTag(key, value)
    }

    /// Reports an error you caught (`zharp.handled = true`), with the stack of the place you
    /// report it from.
    ///
    /// ```swift
    /// do { try checkout() } catch { Zharp.captureError(error, ["orderId": order.id]) }
    /// ```
    public static func captureError(_ error: Error, _ attributes: [String: Any] = [:]) {
        ZharpRuntime.shared?.captureError(error, attributes: attributes, callStack: Thread.callStackSymbols)
    }

    /// Records a screen view by name. SwiftUI: prefer `.zharpScreen("Name")`.
    public static func trackScreen(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        ZharpRuntime.shared?.screenDidAppear(trimmed)
    }

    /// Runs `operation` inside a span named `name`. Requests and spans started inside it become
    /// its children; a thrown error marks it failed and is rethrown. With `options.tracing = false`
    /// it only runs `operation`.
    ///
    /// ```swift
    /// let receipt = try Zharp.startSpan("checkout") { try checkout(cart) }
    /// ```
    @discardableResult
    public static func startSpan<T>(_ name: String, attributes: [String: Any] = [:],
                                    _ operation: () throws -> T) rethrows -> T {
        guard let runtime = ZharpRuntime.shared, runtime.settings.tracing else { return try operation() }
        let span = runtime.beginSpan(name, attributes: attributes)
        defer { span.end() }
        do {
            return try OpenTelemetry.instance.contextProvider.withActiveSpan(span) { try operation() }
        } catch {
            runtime.markFailed(span, error: error)
            throw error
        }
    }

    /// The async version of `startSpan`.
    @discardableResult
    public static func startSpan<T>(_ name: String, attributes: [String: Any] = [:],
                                    _ operation: () async throws -> T) async rethrows -> T {
        guard let runtime = ZharpRuntime.shared, runtime.settings.tracing else { return try await operation() }
        let span = runtime.beginSpan(name, attributes: attributes)
        defer { span.end() }
        do {
            return try await OpenTelemetry.instance.contextProvider.withActiveSpan(span) { try await operation() }
        } catch {
            runtime.markFailed(span, error: error)
            throw error
        }
    }

    /// Sends everything recorded so far now, instead of with the next batch. It happens on a
    /// background queue; `completion` runs when it is done or sending has to wait (offline).
    public static func flush(completion: (() -> Void)? = nil) {
        guard let runtime = ZharpRuntime.shared else {
            completion?()
            return
        }
        runtime.flush(completion: completion)
    }
}

/// `Zharp.log`: logs with a level, a message and optional attributes, tied to the session,
/// the user and the active span.
public struct ZharpLog {
    public func debug(_ message: String, _ attributes: [String: Any] = [:]) {
        write(.debug, message, attributes)
    }

    public func info(_ message: String, _ attributes: [String: Any] = [:]) {
        write(.info, message, attributes)
    }

    public func warn(_ message: String, _ attributes: [String: Any] = [:]) {
        write(.warn, message, attributes)
    }

    public func error(_ message: String, _ attributes: [String: Any] = [:]) {
        write(.error, message, attributes)
    }

    private func write(_ level: LogLevel, _ message: String, _ attributes: [String: Any]) {
        ZharpRuntime.shared?.log(level, message, attributes: AttributeMapping.map(attributes))
    }
}
