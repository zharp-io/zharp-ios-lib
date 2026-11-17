import Foundation
import OSLog
import ZharpCore

/// `os_log` and `Logger` as logs, read back from the app's own entries in the unified log
/// (`OSLogStore`, iOS 15). Opt in with `options.captureOSLog`.
///
/// Unlike `print` and `NSLog`, the unified log can't be tapped as it is written, so this catches
/// up instead: every 30 seconds and when the app goes to the background it reads the entries
/// written since the last read — never older ones — and sends those from the app itself (its
/// executable, or a subsystem that isn't Apple's). Each keeps the time it was written, but not
/// its span. Values logged without `privacy: .public` read back as `<private>`, exactly as in
/// Console.app.
///
/// Off by default: opening the store and walking it costs real CPU time on a device (tens to
/// hundreds of milliseconds per read, on a background queue), and Apple's own frameworks write
/// far more to it than most apps do.
final class OSLogReader: @unchecked Sendable {
    static let interval: TimeInterval = 30

    private let queue = DispatchQueue(label: "io.zharp.oslog", qos: .background)
    private let executable: String?
    private let emit: (CapturedLine, Date) -> Void
    private var timer: DispatchSourceTimer?
    // On `queue`.
    private var store: OSLogStore?
    private var since = Date()

    init(emit: @escaping (CapturedLine, Date) -> Void) {
        executable = Bundle.main.executableURL?.lastPathComponent
        self.emit = emit
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + OSLogReader.interval, repeating: OSLogReader.interval, leeway: .seconds(5))
        timer.setEventHandler { [weak self] in self?.read() }
        self.timer = timer
        timer.resume()
    }

    /// Reads what's new now (the app is going to the background).
    func catchUp() {
        queue.async { [weak self] in self?.read() }
    }

    private func read() {
        if store == nil { store = try? OSLogStore(scope: .currentProcessIdentifier) }
        guard let store = store else { return }
        let start = since
        guard let entries = try? store.getEntries(at: store.position(date: start)) else { return }
        var latest = start
        for case let entry as OSLogEntryLog in entries where entry.date > start {
            if entry.date > latest { latest = entry.date }
            guard OSLogFilter.isApps(subsystem: entry.subsystem, sender: entry.sender, executable: executable) else { continue }
            let body = entry.composedMessage
            guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !body.contains(OutputLineParser.ownPrefix)
            else { continue }
            var attributes = ["log.source": "oslog"]
            if !entry.category.isEmpty { attributes["log.logger"] = entry.category }
            if !entry.subsystem.isEmpty { attributes["oslog.subsystem"] = entry.subsystem }
            emit(CapturedLine(level: OSLogReader.level(entry.level), body: body, attributes: attributes), entry.date)
        }
        since = latest
    }

    static func level(_ level: OSLogEntryLog.Level) -> LogLevel {
        switch level {
        case .debug: return .debug
        case .info, .notice, .undefined: return .info
        case .error: return .error
        case .fault: return .fatal
        @unknown default: return .info
        }
    }
}
