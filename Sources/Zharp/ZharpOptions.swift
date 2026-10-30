import Foundation
import ZharpCore

/// Settings for `Zharp.start`. Only `key` is required.
///
/// ```swift
/// Zharp.start { options in
///     options.key = "zpk_…"
///     options.service = "shop-ios"
///     options.environment = "production"
/// }
/// ```
public final class ZharpOptions {
    /// The app key from Zharp (`zpk_…`). It can only send data, so it is safe inside an app.
    public var key: String = ""

    /// The service name the app's data is filed under. Default: the bundle identifier.
    public var service: String?

    /// `production`, `staging`… Default: none.
    public var environment: String?

    /// The release, e.g. "2.3.0". Default: the bundle's version and build, "2.3.0 (412)".
    public var release: String?

    /// Where to send. Default: `https://api.zharp.io/api/v1/otlp`.
    public var endpoint: String?

    /// Hosts of your own back end that should receive `traceparent` and `baggage` headers, so a
    /// request from the app and the server's handling of it form one trace. Nothing else gets them.
    /// `"api.example.com"`, `"*.example.com"`, `"https://api.example.com:8443"`.
    public var tracingOrigins: [String] = []

    /// `false` for logs only: logs, errors, crashes, hangs, the user, session, screen and tags are
    /// still sent, but no spans are made or sent (no screen or URLSession spans, `startSpan` just
    /// runs its closure) and no request gets `traceparent` or `baggage`.
    public var tracing = true

    /// The share of traces to keep, 0…1. Errors, crashes and logs are always sent.
    public var sampleRate: Double = 1.0

    /// Report crashes (uncaught Objective-C exceptions and fatal signals, Swift runtime errors
    /// included). A crash is saved on the device and sent the next time the app starts.
    public var captureCrashes = true

    /// Report when the main thread is blocked for `hangThreshold` seconds or more.
    public var detectHangs = true
    public var hangThreshold: TimeInterval = 2

    /// Record a screen view each time a UIKit view controller appears. SwiftUI views use
    /// `.zharpScreen("Name")` instead.
    public var trackScreens = true

    /// Trace URLSession requests (CLIENT spans) and add trace headers for `tracingOrigins`.
    public var traceNetwork = true

    /// Send everything waiting when the app goes to the background.
    public var flushOnBackground = true

    /// Print what the SDK is doing to the console.
    public var debug = false

    public init() {}
}

/// The options, checked and with defaults filled in.
struct Settings {
    let key: String
    let endpoint: URL
    let service: String
    let environment: String?
    let release: String?
    let tracingOrigins: TracingOrigins
    let tracing: Bool
    let sampleRate: Double
    let captureCrashes: Bool
    let detectHangs: Bool
    let hangThreshold: TimeInterval
    let trackScreens: Bool
    let traceNetwork: Bool
    let flushOnBackground: Bool

    static func resolve(_ options: ZharpOptions, bundle: Bundle = .main) -> Settings? {
        let key = options.key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            Diagnostics.warn("No key, so nothing will be sent. Set it in Zharp.start: options.key = \"zpk_…\"")
            return nil
        }
        guard let endpoint = Endpoint.base(options.endpoint) else {
            Diagnostics.warn("The endpoint \"\(options.endpoint ?? "")\" isn't an http(s) URL, so nothing will be sent.")
            return nil
        }
        let info = bundle.infoDictionary ?? [:]
        let environment = options.environment?.trimmingCharacters(in: .whitespaces)
        return Settings(
            key: key,
            endpoint: endpoint,
            service: ResourceInfo.defaultService(explicit: options.service, bundleIdentifier: bundle.bundleIdentifier),
            environment: (environment?.isEmpty ?? true) ? nil : environment,
            release: ResourceInfo.defaultRelease(explicit: options.release,
                                                 shortVersion: info["CFBundleShortVersionString"] as? String,
                                                 build: info["CFBundleVersion"] as? String),
            tracingOrigins: TracingOrigins(options.tracingOrigins),
            tracing: options.tracing,
            sampleRate: Sampling.clampRate(options.sampleRate),
            captureCrashes: options.captureCrashes,
            detectHangs: options.detectHangs,
            hangThreshold: max(options.hangThreshold, 0.25),
            trackScreens: options.trackScreens,
            traceNetwork: options.traceNetwork,
            flushOnBackground: options.flushOnBackground
        )
    }
}
