import Foundation
import ZharpCore

/// Device and OS context for the resource.
enum DeviceInfo {
    static let deviceIdKey = "io.zharp.device.id"

    /// A random id for this installation, kept in UserDefaults. Not the IDFA or IDFV: it says
    /// "the same install" and nothing else, and it goes away when the app is deleted.
    static func deviceId(in defaults: UserDefaults) -> String {
        if let existing = defaults.string(forKey: deviceIdKey), !existing.isEmpty { return existing }
        let id = UUID().uuidString.lowercased()
        defaults.set(id, forKey: deviceIdKey)
        return id
    }

    /// The hardware model, e.g. "iPhone15,2" (the simulator reports the model it simulates).
    static func modelIdentifier() -> String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"], !simulated.isEmpty {
            return simulated
        }
        var size = 0
        guard sysctlbyname("hw.machine", nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.machine", &buffer, &size, nil, 0) == 0 else { return "unknown" }
        return buffer.withUnsafeBufferPointer { pointer in
            pointer.baseAddress.map { String(cString: $0) } ?? "unknown"
        }
    }

    static var osName: String {
        #if os(iOS)
        return "iOS"
        #elseif os(tvOS)
        return "tvOS"
        #elseif os(visionOS)
        return "visionOS"
        #elseif os(macOS)
        return "macOS"
        #else
        return "unknown"
        #endif
    }

    static var osVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return ResourceInfo.osVersionString(major: version.majorVersion, minor: version.minorVersion,
                                            patch: version.patchVersion)
    }
}
