import Foundation

/// The SDK's version, sent as `telemetry.sdk.version`. Bump it with each release tag.
public enum ZharpVersion {
    public static let current = "0.1.0"
}

/// The two OTLP signals the SDK sends, and the path each goes to under the endpoint.
public enum SignalKind: String, CaseIterable {
    case traces
    case logs
}

/// `Zharp.log` levels, as OTLP severity numbers.
public enum LogLevel: Int, CaseIterable {
    case debug = 5
    case info = 9
    case warn = 13
    case error = 17
    case fatal = 21

    public var text: String {
        switch self {
        case .debug: return "DEBUG"
        case .info: return "INFO"
        case .warn: return "WARN"
        case .error: return "ERROR"
        case .fatal: return "FATAL"
        }
    }
}

/// Attribute names Zharp reads (zharp-backend `src/ingest/otlp/otlp-normalize.ts`).
public enum Keys {
    public static let serviceName = "service.name"
    public static let serviceVersion = "service.version"
    public static let environment = "deployment.environment.name"
    public static let sdkName = "telemetry.sdk.name"
    public static let sdkLanguage = "telemetry.sdk.language"
    public static let sdkVersion = "telemetry.sdk.version"

    public static let sessionId = "session.id"
    public static let userId = "enduser.id"
    public static let userEmail = "enduser.email"
    public static let userName = "enduser.name"
    public static let deviceId = "device.id"
    public static let deviceModelName = "device.model.name"
    public static let deviceModelIdentifier = "device.model.identifier"
    public static let deviceManufacturer = "device.manufacturer"
    public static let osName = "os.name"
    public static let osVersion = "os.version"
    public static let screenName = "app.screen.name"

    public static let exceptionType = "exception.type"
    public static let exceptionMessage = "exception.message"
    public static let exceptionStacktrace = "exception.stacktrace"
    public static let handled = "zharp.handled"
    public static let errorKind = "zharp.error.kind"
    /// JSON `[{name, uuid, loadAddress, arch}]` of the images a stack runs through.
    public static let binaryImages = "zharp.binary_images"
}

/// Where telemetry goes.
public enum Endpoint {
    public static let production = "https://api.zharp.io/api/v1/otlp"

    /// The base endpoint from the `endpoint` option: production when unset, otherwise an http(s)
    /// URL with a host, without trailing slashes. Nil when the option isn't a usable URL.
    public static func base(_ raw: String?) -> URL? {
        var text = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { text = production }
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host, !host.isEmpty
        else { return nil }
        return url
    }

    /// `{base}/v1/traces` or `{base}/v1/logs`.
    public static func url(base: URL, kind: SignalKind) -> URL {
        base.appendingPathComponent("v1").appendingPathComponent(kind.rawValue)
    }
}
