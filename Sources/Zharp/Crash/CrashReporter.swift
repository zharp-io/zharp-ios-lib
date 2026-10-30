import Foundation
import ZharpCore

#if canImport(Darwin)
import Darwin
#endif

/// Crash capture. iOS gives a crashing app no time to send anything, so a crash is written to
/// disk as it happens and reported the next time the app starts.
///
/// - Uncaught Objective-C exceptions: `NSSetUncaughtExceptionHandler`. Runs before the process
///   aborts, so it can use Foundation; it writes the exception's symbolicated call stack.
/// - Fatal signals (SIGSEGV, SIGBUS, SIGILL, SIGTRAP — Swift runtime errors —, SIGFPE, SIGABRT):
///   `sigaction`. A signal handler may only call async-signal-safe functions, so it writes the
///   faulting address and `backtrace()` addresses as numbers with `write()`, followed by the
///   image list prepared at start; the next launch turns that into frames and Binary Images.
///
/// Handlers that were installed before Zharp (another crash reporter) are called afterwards, and
/// the app then crashes exactly as it would have.
enum CrashReporter {
    static let signalFileName = "crash-signal.txt"
    static let exceptionFileName = "crash-exception.json"

    private static let lock = NSLock()
    private static var installed = false
    private static var images: [BinaryImage] = []
    private static var exceptionURL: URL?

    static func install(directory: URL) {
        lock.lock()
        defer { lock.unlock() }
        guard !installed else { return }
        installed = true

        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        images = BinaryImages.loaded()
        exceptionURL = directory.appendingPathComponent(exceptionFileName)

        let imageList = images.map(CrashFormat.imageLine).joined(separator: "\n") + "\n"
        let signalPath = directory.appendingPathComponent(signalFileName).path
        SignalHandler.install(reportPath: signalPath, imageList: imageList)

        previousExceptionHandler = NSGetUncaughtExceptionHandler()
        NSSetUncaughtExceptionHandler(zharpUncaughtExceptionHandler)
    }

    /// Called from the uncaught-exception handler.
    fileprivate static func writeExceptionReport(_ exception: NSException) {
        guard let url = exceptionURL else { return }
        let type = exception.name.rawValue
        let message = exception.reason ?? ""
        let stack = CrashFormat.exceptionStacktrace(
            type: type,
            message: message,
            symbols: exception.callStackSymbols,
            addresses: exception.callStackReturnAddresses.map { $0.uint64Value },
            images: images
        )
        let report = ExceptionCrashReport(type: type, message: message, stacktrace: stack,
                                          time: Date().timeIntervalSince1970)
        guard let data = try? JSONEncoder().encode(report) else { return }
        try? data.write(to: url, options: .atomic)
    }

    struct PendingCrash {
        let error: ErrorDescription
        let time: Date
        let files: [URL]
    }

    /// Crashes saved by a previous run. The exception report wins when there are both (the
    /// exception's abort raises SIGABRT after it); the files are listed so they can be deleted
    /// once the crash is safely in the outbox.
    static func pending(in directory: URL) -> PendingCrash? {
        let exceptionFile = directory.appendingPathComponent(exceptionFileName)
        let signalFile = directory.appendingPathComponent(signalFileName)
        let files = [exceptionFile, signalFile].filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !files.isEmpty else { return nil }

        if let data = try? Data(contentsOf: exceptionFile),
           let report = try? JSONDecoder().decode(ExceptionCrashReport.self, from: data) {
            return PendingCrash(error: ErrorDescription(type: report.type, message: report.message, stacktrace: report.stacktrace),
                                time: Date(timeIntervalSince1970: report.time), files: files)
        }
        if let data = try? Data(contentsOf: signalFile),
           let text = String(data: data, encoding: .utf8),
           let report = CrashFormat.parseSignalReport(text) {
            let time = report.time > 0 ? Date(timeIntervalSince1970: report.time) : Date()
            return PendingCrash(error: CrashFormat.describe(report), time: time, files: files)
        }
        // Unreadable (e.g. cut short): nothing to report, but don't keep it around.
        remove(files)
        return nil
    }

    static func remove(_ files: [URL]) {
        for file in files { try? FileManager.default.removeItem(at: file) }
    }
}

private var previousExceptionHandler: (@convention(c) (NSException) -> Void)?

private func zharpUncaughtExceptionHandler(_ exception: NSException) {
    SignalHandler.markExceptionWritten()
    CrashReporter.writeExceptionReport(exception)
    previousExceptionHandler?(exception)
}
