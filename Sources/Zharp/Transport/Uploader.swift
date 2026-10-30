import Foundation
import ZharpCore

/// Sends the outbox to Zharp, one batch at a time, oldest first. What happens after each attempt
/// is `RetryPolicy.outcome`: sent or refused batches are deleted, 429/5xx/offline wait with
/// backoff, and a rejected key stops sending for an hour with one warning.
final class Uploader: @unchecked Sendable {
    private let outbox: Outbox
    private let endpoint: URL
    private let key: String
    private let session: URLSession
    private let queue = DispatchQueue(label: "io.zharp.upload", qos: .utility)

    // Only touched on `queue`.
    private var busy = false
    private var failures = 0
    private var retryAt: Date?
    private var pausedUntil: Date?
    private var keyRejected = false
    private var waiters: [() -> Void] = []

    init(outbox: Outbox, endpoint: URL, key: String,
         configuration: URLSessionConfiguration = URLSessionConfiguration.ephemeral) {
        self.outbox = outbox
        self.endpoint = endpoint
        self.key = key
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    /// Sends whatever is waiting, unless a backoff or a key pause is running. `completion` runs
    /// once the outbox is empty or sending has to wait.
    func kick(completion: (() -> Void)? = nil) {
        queue.async {
            if let completion = completion { self.waiters.append(completion) }
            self.pump()
        }
    }

    /// Requests to Zharp itself, which the network instrumentation must leave alone.
    func isOwnRequest(_ url: URL?) -> Bool {
        guard let url = url?.absoluteString else { return false }
        return url.hasPrefix(endpoint.absoluteString)
    }

    private func pump() {
        guard !busy else { return }
        let now = Date()
        if let until = pausedUntil {
            if now < until {
                // The key doesn't work: keep nothing, so nothing piles up meanwhile.
                outbox.removeAll()
                return finishWaiters()
            }
            pausedUntil = nil
        }
        if let at = retryAt, now < at { return finishWaiters() }
        guard let item = outbox.oldest() else { return finishWaiters() }
        guard let body = try? Data(contentsOf: item.url) else {
            outbox.remove(item)
            return pump()
        }

        busy = true
        var request = URLRequest(url: Endpoint.url(base: endpoint, kind: item.kind))
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/x-protobuf", forHTTPHeaderField: "Content-Type")
        if item.gzip { request.setValue("gzip", forHTTPHeaderField: "Content-Encoding") }
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("zharp-ios/\(ZharpVersion.current)", forHTTPHeaderField: "User-Agent")

        let task = session.dataTask(with: request) { [weak self] _, response, _ in
            let http = response as? HTTPURLResponse
            let status = http?.statusCode
            let retryAfter = http?.value(forHTTPHeaderField: "Retry-After")
            self?.queue.async { self?.handle(RetryPolicy.outcome(statusCode: status, retryAfter: retryAfter), item: item, status: status) }
        }
        task.resume()
    }

    private func handle(_ outcome: UploadOutcome, item: Outbox.Item, status: Int?) {
        busy = false
        switch outcome {
        case .sent, .drop:
            if outcome == .drop { Diagnostics.debug("Zharp refused a batch (HTTP \(status ?? 0)); dropped it.") }
            if keyRejected, outcome == .sent {
                keyRejected = false
                Diagnostics.info("The key works again; sending resumed.")
            }
            outbox.remove(item)
            failures = 0
            retryAt = nil
            pump()
        case .rejectedKey:
            if !keyRejected {
                keyRejected = true
                Diagnostics.warn("Zharp rejected the key (HTTP \(status ?? 0)). Check options.key — sending stops for an hour, the app is unaffected.")
            }
            pausedUntil = Date().addingTimeInterval(RetryPolicy.rejectedKeyPause)
            outbox.removeAll()
            finishWaiters()
        case let .retry(after):
            failures += 1
            let delay = after ?? RetryPolicy.backoff(attempt: failures)
            retryAt = Date().addingTimeInterval(delay)
            Diagnostics.debug("Sending failed (\(status.map { "HTTP \($0)" } ?? "no response")); retrying in \(Int(delay)) s.")
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.pump() }
            finishWaiters()
        }
    }

    private func finishWaiters() {
        guard !waiters.isEmpty else { return }
        let done = waiters
        waiters = []
        for waiter in done { waiter() }
    }
}
