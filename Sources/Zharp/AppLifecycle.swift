import Foundation

#if canImport(UIKit) && !os(watchOS)
import UIKit

/// Background and foreground: session timing, hang-detector pause, and sending everything that
/// is waiting before iOS suspends the app (inside a background task, so it gets the time).
enum AppLifecycle {
    private static var observers: [NSObjectProtocol] = []

    static func install(runtime: ZharpRuntime) {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                            object: nil, queue: nil) { [weak runtime] _ in
            guard let runtime = runtime else { return }
            runtime.didEnterBackground()
            guard runtime.settings.flushOnBackground else { return }
            let task = BackgroundTask()
            task.begin()
            runtime.flush(timeout: 10) { task.end() }
        })
        observers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification,
                                            object: nil, queue: nil) { [weak runtime] _ in
            runtime?.willEnterForeground()
        })
    }
}

/// A UIKit background task that is ended exactly once, by the flush or by iOS's expiry.
private final class BackgroundTask: @unchecked Sendable {
    private let lock = NSLock()
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    func begin() {
        let id = UIApplication.shared.beginBackgroundTask(withName: "io.zharp.flush") { [weak self] in
            self?.end()
        }
        lock.lock()
        identifier = id
        lock.unlock()
    }

    func end() {
        lock.lock()
        let id = identifier
        identifier = .invalid
        lock.unlock()
        guard id != .invalid else { return }
        DispatchQueue.main.async { UIApplication.shared.endBackgroundTask(id) }
    }
}

#else

enum AppLifecycle {
    static func install(runtime: ZharpRuntime) {}
}

#endif
