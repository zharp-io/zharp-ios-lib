import Logging
import Zharp
import ZharpCore

/// swift-log's `Logger` into Zharp. Bootstrap it once, before the first `Logger` is made —
/// alongside the handler that prints, so the console keeps its output:
///
/// ```swift
/// import Logging
/// import ZharpLogging
///
/// LoggingSystem.bootstrap { label in
///     MultiplexLogHandler([StreamLogHandler.standardOutput(label: label), ZharpLogHandler(label: label)])
/// }
/// ```
///
/// Each record keeps the span it was logged in, its level, the logger's label (`log.logger`),
/// its metadata as attributes, and where it was logged (`code.function`, `code.filepath`,
/// `code.lineno`). The line the printing handler writes isn't sent a second time. It sends
/// only with `options.logs = true`; otherwise, and before `Zharp.start`, it does nothing.
public struct ZharpLogHandler: LogHandler {
    public let label: String
    public var logLevel: Logging.Logger.Level
    public var metadata: Logging.Logger.Metadata = [:]
    public var metadataProvider: Logging.Logger.MetadataProvider?

    public init(label: String, logLevel: Logging.Logger.Level = .info,
                metadataProvider: Logging.Logger.MetadataProvider? = LoggingSystem.metadataProvider) {
        self.label = label
        self.logLevel = logLevel
        self.metadataProvider = metadataProvider
    }

    public subscript(metadataKey key: String) -> Logging.Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    public func log(level: Logging.Logger.Level, message: Logging.Logger.Message, metadata explicit: Logging.Logger.Metadata?,
                    source: String, file: String, function: String, line: UInt) {
        var merged = metadata
        if let provided = metadataProvider?.get() { merged.merge(provided) { _, new in new } }
        if let explicit = explicit { merged.merge(explicit) { _, new in new } }

        var attributes: [String: Any] = [:]
        for (key, value) in merged { attributes[key] = ZharpLogHandler.text(value) }
        attributes["log.source"] = "swift-log"
        attributes["log.logger"] = label
        attributes["code.function"] = function
        attributes["code.filepath"] = file
        attributes["code.lineno"] = Int(line)
        Zharp.adapterLog(ZharpLogHandler.level(level), message.description, attributes: attributes)
    }

    static func level(_ level: Logging.Logger.Level) -> LogLevel {
        switch level {
        case .trace, .debug: return .debug
        case .info, .notice: return .info
        case .warning: return .warn
        case .error: return .error
        case .critical: return .fatal
        }
    }

    static func text(_ value: Logging.Logger.Metadata.Value) -> String {
        switch value {
        case let .string(string): return string
        case let .stringConvertible(convertible): return convertible.description
        default: return value.description
        }
    }
}
