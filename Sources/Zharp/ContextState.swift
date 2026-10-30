import Foundation
import ZharpCore

/// The live session, user, screen and tags, shared by every thread. Changes are reported through
/// `onChange` (outside the lock) so they can be saved for crash reports.
final class ContextState: @unchecked Sendable {
    private let lock = NSLock()
    private var session: SessionRules
    private var user: UserInfo?
    private var screen: String?
    private var tags: [String: String] = [:]
    private let release: String?

    var onChange: ((ContextSnapshot) -> Void)?

    init(release: String?, sessionId: String = SessionRules.newId()) {
        self.release = release
        session = SessionRules(id: sessionId)
    }

    /// The context for telemetry recorded now (this also rolls the session over after 30 minutes
    /// in the background).
    func snapshot(now: Date = Date()) -> ContextSnapshot {
        lock.lock()
        let changed = session.current(at: now)
        let snapshot = makeSnapshot()
        lock.unlock()
        if changed { notify(snapshot) }
        return snapshot
    }

    func setUser(_ newUser: UserInfo) {
        update { $0.user = newUser }
    }

    /// Signs the user out and starts a new session.
    func clearUser() {
        update {
            $0.user = nil
            $0.session.restart()
        }
    }

    func setScreen(_ name: String) {
        update { $0.screen = name }
    }

    func setTag(_ key: String, _ value: String?) {
        update { $0.tags[key] = value }
    }

    func didEnterBackground(now: Date = Date()) {
        lock.lock()
        session.didEnterBackground(at: now)
        lock.unlock()
    }

    func willEnterForeground(now: Date = Date()) {
        lock.lock()
        let changed = session.willEnterForeground(at: now)
        let snapshot = makeSnapshot()
        lock.unlock()
        if changed { notify(snapshot) }
    }

    private func update(_ change: (ContextState) -> Void) {
        lock.lock()
        change(self)
        let snapshot = makeSnapshot()
        lock.unlock()
        notify(snapshot)
    }

    private func makeSnapshot() -> ContextSnapshot {
        ContextSnapshot(sessionId: session.id, user: user, screen: screen, tags: tags, release: release)
    }

    private func notify(_ snapshot: ContextSnapshot) {
        onChange?(snapshot)
    }
}

/// The last context, saved to disk so a crash sent on the next launch says which session, user,
/// screen and release it happened in.
final class RunContextStore: @unchecked Sendable {
    private let url: URL
    private let queue = DispatchQueue(label: "io.zharp.context", qos: .utility)

    init(directory: URL) {
        url = directory.appendingPathComponent("run-context.json")
    }

    func load() -> ContextSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ContextSnapshot.self, from: data)
    }

    func save(_ snapshot: ContextSnapshot) {
        queue.async { [url] in
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
}
