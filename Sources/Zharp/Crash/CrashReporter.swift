import Foundation
import ZharpCore
import ZharpCxx

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
/// - Uncaught C++ exceptions: a `std::terminate` handler (ZharpCxx) writes the exception's type and
///   `what()`; the SIGABRT that follows is reported as that exception, with the throw site's frames
///   (libc++abi calls terminate before unwinding anything).
///
/// Handlers that were installed before Zharp (another crash reporter) are called afterwards, and
/// the app then crashes exactly as it would have.
enum CrashReporter {
    static let signalFileName = "crash-signal.txt"
    static let exceptionFileName = "crash-exception.json"
    static let cxxFileName = "crash-cxx.txt"

    private static let lock = NSLock()
    private static var installed = false
    private static var images: [BinaryImage] = []
    private static var exceptionURL: URL?
    /// `ignoreCrashTypes`: exception names (or their beginnings) another layer already reported.
    private(set) static var ignoredExceptionPrefixes: [String] = []

    static func install(directory: URL, ignoring: [String] = []) {
        lock.lock()
        defer { lock.unlock() }
        guard !installed else { return }
        installed = true
        ignoredExceptionPrefixes = ignoring.filter { !$0.isEmpty }

        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        images = BinaryImages.loaded()
        exceptionURL = directory.appendingPathComponent(exceptionFileName)

        let imageList = images.map(CrashFormat.imageLine).joined(separator: "\n") + "\n"
        let signalPath = directory.appendingPathComponent(signalFileName).path
        SignalHandler.install(reportPath: signalPath, imageList: imageList)
        zharp_cxx_install_terminate_handler(directory.appendingPathComponent(cxxFileName).path)

        previousExceptionHandler = NSGetUncaughtExceptionHandler()
        NSSetUncaughtExceptionHandler(zharpUncaughtExceptionHandler)
    }

    /// Whether another layer already reported this exception (React Native's RCTFatalException,
    /// raised for a fatal JS error @zharp/react-native has saved as the JS error it is).
    static func isIgnored(_ name: String) -> Bool {
        ignoredExceptionPrefixes.contains { name.hasPrefix($0) }
    }

    /// Called from the uncaught-exception handler.
    fileprivate static func writeExceptionReport(_ exception: NSException) {
        guard let url = exceptionURL, !isIgnored(exception.name.rawValue) else { return }
        let type = exception.name.rawValue
        let message = exception.reason ?? ""
        let addresses = exception.callStackReturnAddresses.map { $0.uint64Value }
        let stack = CrashFormat.exceptionStacktrace(
            type: type,
            message: message,
            symbols: exception.callStackSymbols,
            addresses: addresses,
            images: images
        )
        let report = ExceptionCrashReport(type: type, message: message, stacktrace: stack,
                                          time: Date().timeIntervalSince1970,
                                          images: CrashFormat.usedImages(addresses: addresses, images: images))
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
        let cxxFile = directory.appendingPathComponent(cxxFileName)
        let files = [exceptionFile, signalFile, cxxFile].filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !files.isEmpty else { return nil }

        if let data = try? Data(contentsOf: exceptionFile),
           let report = try? JSONDecoder().decode(ExceptionCrashReport.self, from: data) {
            return PendingCrash(error: ErrorDescription(type: report.type, message: report.message,
                                                        stacktrace: report.stacktrace, images: report.images ?? []),
                                time: Date(timeIntervalSince1970: report.time), files: files)
        }
        if let data = try? Data(contentsOf: signalFile),
           let text = String(data: data, encoding: .utf8),
           let report = CrashFormat.parseSignalReport(text) {
            let time = report.time > 0 ? Date(timeIntervalSince1970: report.time) : Date()
            let cxx = (try? String(contentsOf: cxxFile, encoding: .utf8)).flatMap(CrashFormat.parseCxxException)
            return PendingCrash(error: CrashFormat.describe(report, cxxException: cxx), time: time, files: files)
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
