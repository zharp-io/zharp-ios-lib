import Foundation
import ZharpCore

/// The offline buffer: every batch the exporters produce is written here first, and the
/// `Uploader` sends and deletes them oldest first. Capped by `OutboxPolicy` (oldest dropped).
final class Outbox: @unchecked Sendable {
    struct Item: Equatable {
        let url: URL
        let kind: SignalKind
        let gzip: Bool
    }

    private let directory: URL
    private let lock = NSLock()
    private var sequence = 0
    private let fileManager = FileManager.default

    /// Called after a batch is stored.
    var onEnqueue: (() -> Void)?

    init(directory: URL) {
        self.directory = directory
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func enqueue(kind: SignalKind, body: Data, gzip: Bool) {
        guard !body.isEmpty else { return }
        lock.lock()
        sequence += 1
        let name = OutboxPolicy.fileName(kind: kind, gzip: gzip,
                                         timestampMs: Int64(Date().timeIntervalSince1970 * 1000),
                                         sequence: sequence)
        do {
            try body.write(to: directory.appendingPathComponent(name), options: .atomic)
        } catch {
            Diagnostics.debug("Couldn't store a batch: \(error)")
        }
        enforceCaps()
        lock.unlock()
        onEnqueue?()
    }

    func oldest() -> Item? {
        lock.lock()
        defer { lock.unlock() }
        guard let name = OutboxPolicy.ordered(names()).first, let parsed = OutboxPolicy.parse(name) else { return nil }
        return Item(url: directory.appendingPathComponent(name), kind: parsed.kind, gzip: parsed.gzip)
    }

    func remove(_ item: Item) {
        lock.lock()
        try? fileManager.removeItem(at: item.url)
        lock.unlock()
    }

    func removeAll() {
        lock.lock()
        for name in OutboxPolicy.ordered(names()) {
            try? fileManager.removeItem(at: directory.appendingPathComponent(name))
        }
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return OutboxPolicy.ordered(names()).count
    }

    private func names() -> [String] {
        (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
    }

    private func enforceCaps() {
        let entries = OutboxPolicy.ordered(names()).map { name -> OutboxPolicy.Entry in
            let path = directory.appendingPathComponent(name).path
            let size = (try? fileManager.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue ?? 0
            return OutboxPolicy.Entry(name: name, size: size)
        }
        let overflow = OutboxPolicy.overflow(entries)
        for name in overflow {
            try? fileManager.removeItem(at: directory.appendingPathComponent(name))
        }
        if !overflow.isEmpty { Diagnostics.debug("Outbox full: dropped the \(overflow.count) oldest batch(es).") }
    }
}
