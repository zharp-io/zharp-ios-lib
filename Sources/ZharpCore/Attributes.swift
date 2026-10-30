import Foundation

/// An attribute value as OTLP carries it. The OpenTelemetry glue converts these one to one.
public enum AttrValue: Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case stringArray([String])
}

/// Turns the `[String: Any]` an app passes (`Zharp.log.info("…", ["orderId": 42])`) into OTLP
/// attribute values: strings, integers, doubles and booleans as themselves, string arrays as
/// arrays, dates as ISO 8601, anything else as its description.
public enum AttributeMapping {
    public static let maxAttributes = 64
    public static let maxStringLength = 4096

    public static func map(_ attributes: [String: Any]) -> [String: AttrValue] {
        var out: [String: AttrValue] = [:]
        // Sorted, so which attributes survive the cap doesn't depend on dictionary order.
        for key in attributes.keys.sorted() {
            guard !key.isEmpty, out.count < maxAttributes,
                  let raw = attributes[key], let value = value(raw)
            else { continue }
            out[key] = value
        }
        return out
    }

    public static func value(_ raw: Any) -> AttrValue? {
        if let string = raw as? String { return .string(truncate(string)) }
        if let number = raw as? NSNumber {
            // Swift Bool, Int and Double all bridge to NSNumber; CoreFoundation tells them apart.
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            if CFNumberIsFloatType(number as CFNumber) { return .double(number.doubleValue) }
            return .int(number.intValue)
        }
        if let strings = raw as? [String] { return .stringArray(strings.map(truncate)) }
        if let date = raw as? Date { return .string(iso8601(date)) }
        if let url = raw as? URL { return .string(truncate(url.absoluteString)) }
        if let uuid = raw as? UUID { return .string(uuid.uuidString.lowercased()) }
        if raw is NSNull { return nil }
        let mirror = Mirror(reflecting: raw)
        if mirror.displayStyle == .optional {
            // An Optional inside Any: nil is dropped, a value is mapped as itself.
            guard let wrapped = mirror.children.first?.value else { return nil }
            return value(wrapped)
        }
        return .string(truncate(String(describing: raw)))
    }

    public static func truncate(_ text: String) -> String {
        text.count > maxStringLength ? String(text.prefix(maxStringLength)) : text
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func iso8601(_ date: Date) -> String {
        isoFormatter.string(from: date)
    }
}

/// The resource: who is sending. Set once at start.
public struct ResourceInfo: Equatable {
    public var service: String
    public var release: String?
    public var environment: String?
    public var deviceId: String
    public var deviceModel: String
    public var osName: String
    public var osVersion: String

    public init(service: String, release: String?, environment: String?, deviceId: String,
                deviceModel: String, osName: String, osVersion: String) {
        self.service = service
        self.release = release
        self.environment = environment
        self.deviceId = deviceId
        self.deviceModel = deviceModel
        self.osName = osName
        self.osVersion = osVersion
    }

    public func attributes() -> [String: AttrValue] {
        var out: [String: AttrValue] = [
            Keys.serviceName: .string(service),
            Keys.sdkName: .string("zharp"),
            Keys.sdkLanguage: .string("swift"),
            Keys.sdkVersion: .string(ZharpVersion.current),
            Keys.deviceId: .string(deviceId),
            Keys.deviceModelName: .string(deviceModel),
            Keys.deviceModelIdentifier: .string(deviceModel),
            Keys.deviceManufacturer: .string("Apple"),
            Keys.osName: .string(osName),
            Keys.osVersion: .string(osVersion),
        ]
        if let release = release, !release.isEmpty { out[Keys.serviceVersion] = .string(release) }
        if let environment = environment, !environment.isEmpty { out[Keys.environment] = .string(environment) }
        return out
    }

    /// The default `service`: the app's bundle identifier.
    public static func defaultService(explicit: String?, bundleIdentifier: String?) -> String {
        if let explicit = explicit?.trimmingCharacters(in: .whitespaces), !explicit.isEmpty { return explicit }
        if let bundleIdentifier = bundleIdentifier, !bundleIdentifier.isEmpty { return bundleIdentifier }
        return "ios-app"
    }

    /// The default `release`: "1.4.0 (212)" from the bundle's version and build.
    public static func defaultRelease(explicit: String?, shortVersion: String?, build: String?) -> String? {
        if let explicit = explicit?.trimmingCharacters(in: .whitespaces), !explicit.isEmpty { return explicit }
        switch (shortVersion, build) {
        case let (version?, build?) where !version.isEmpty && !build.isEmpty && version != build:
            return "\(version) (\(build))"
        case let (version?, _) where !version.isEmpty:
            return version
        case let (_, build?) where !build.isEmpty:
            return build
        default:
            return nil
        }
    }

    /// "17.4.1", or "17.4" when there is no patch version.
    public static func osVersionString(major: Int, minor: Int, patch: Int) -> String {
        patch > 0 ? "\(major).\(minor).\(patch)" : "\(major).\(minor)"
    }
}
