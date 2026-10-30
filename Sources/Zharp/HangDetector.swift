import Foundation

/// Watches the main thread from a background thread: it asks the main queue to run a no-op and
/// reports a hang when that takes `threshold` seconds or more. One report per hang; it waits for
/// the main thread to respond before watching again. Paused in the background and while a
/// debugger is attached (breakpoints would look like hangs).
final class HangDetector: @unchecked Sendable {
    private let threshold: TimeInterval
    private let onHang: (TimeInterval) -> Void
    private let lock = NSLock()
    private var paused = false
    private var started = false

    init(threshold: TimeInterval, onHang: @escaping (TimeInterval) -> Void) {
        self.threshold = threshold
        self.onHang = onHang
    }

    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard !started else { return }
        started = true
        let thread = Thread { [weak self] in self?.run() }
        thread.name = "io.zharp.hang-detector"
        thread.qualityOfService = .utility
        thread.start()
    }

    func setPaused(_ value: Bool) {
        lock.lock()
        paused = value
        lock.unlock()
    }

    private var isPaused: Bool {
        lock.lock()
        defer { lock.unlock() }
        return paused
    }

    private func run() {
        while true {
            if isPaused || HangDetector.isDebuggerAttached() {
                Thread.sleep(forTimeInterval: 1)
                continue
            }
            let responded = DispatchSemaphore(value: 0)
            DispatchQueue.main.async { responded.signal() }
            if responded.wait(timeout: .now() + threshold) == .timedOut {
                // Paused meanwhile (the app went to the background) means it wasn't a hang.
                if !isPaused { onHang(threshold) }
                responded.wait()
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
    }

    static func isDebuggerAttached() -> Bool {
        var info = kinfo_proc()
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        var size = MemoryLayout<kinfo_proc>.stride
        let result = sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0)
        return result == 0 && (info.kp_proc.p_flag & P_TRACED) != 0
    }
}
