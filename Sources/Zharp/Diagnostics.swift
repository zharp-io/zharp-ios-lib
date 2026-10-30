import Foundation

/// The SDK's own console output. Quiet by default: one line when it starts, one warning for a
/// rejected key or a setup mistake. `options.debug = true` adds the details.
enum Diagnostics {
    private static let lock = NSLock()
    private static var _verbose = false

    static var verbose: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _verbose }
        set { lock.lock(); _verbose = newValue; lock.unlock() }
    }

    static func info(_ message: String) {
        NSLog("[Zharp] %@", message)
    }

    static func warn(_ message: String) {
        NSLog("[Zharp] Warning: %@", message)
    }

    static func debug(_ message: @autoclosure () -> String) {
        guard verbose else { return }
        NSLog("[Zharp] %@", message())
    }
}
