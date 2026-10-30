import XCTest
@testable import ZharpCore

final class DeliveryTests: XCTestCase {
    func testOutcomes() {
        XCTAssertEqual(RetryPolicy.outcome(statusCode: 200), .sent)
        XCTAssertEqual(RetryPolicy.outcome(statusCode: 204), .sent)
        XCTAssertEqual(RetryPolicy.outcome(statusCode: 400), .drop)
        XCTAssertEqual(RetryPolicy.outcome(statusCode: 413), .drop)
        XCTAssertEqual(RetryPolicy.outcome(statusCode: 401), .rejectedKey)
        XCTAssertEqual(RetryPolicy.outcome(statusCode: 403), .rejectedKey)
        XCTAssertEqual(RetryPolicy.outcome(statusCode: 429), .retry(after: nil))
        XCTAssertEqual(RetryPolicy.outcome(statusCode: 503), .retry(after: nil))
        XCTAssertEqual(RetryPolicy.outcome(statusCode: 500), .retry(after: nil))
        XCTAssertEqual(RetryPolicy.outcome(statusCode: nil), .retry(after: nil))
    }

    func testRetryAfter() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(RetryPolicy.outcome(statusCode: 429, retryAfter: "30", now: now), .retry(after: 30))
        XCTAssertEqual(RetryPolicy.retryAfterSeconds("0", now: now), 1)
        XCTAssertEqual(RetryPolicy.retryAfterSeconds("86400", now: now), RetryPolicy.maxBackoff)
        XCTAssertNil(RetryPolicy.retryAfterSeconds("soon", now: now))
        XCTAssertNil(RetryPolicy.retryAfterSeconds(nil, now: now))
        // Tue, 14 Nov 2023 22:14:20 GMT is 1_700_000_060.
        XCTAssertEqual(RetryPolicy.retryAfterSeconds("Tue, 14 Nov 2023 22:14:20 GMT", now: now), 60)
    }

    func testBackoffDoublesUpToTheCap() {
        XCTAssertEqual(RetryPolicy.backoff(attempt: 1), 5)
        XCTAssertEqual(RetryPolicy.backoff(attempt: 2), 10)
        XCTAssertEqual(RetryPolicy.backoff(attempt: 3), 20)
        XCTAssertEqual(RetryPolicy.backoff(attempt: 7), 300)
        XCTAssertEqual(RetryPolicy.backoff(attempt: 1_000), 300)
        XCTAssertEqual(RetryPolicy.backoff(attempt: 0), 5)
    }

    func testOutboxFileNamesSortOldestFirst() {
        let early = OutboxPolicy.fileName(kind: .traces, gzip: true, timestampMs: 1_700_000_000_000, sequence: 2)
        let late = OutboxPolicy.fileName(kind: .logs, gzip: false, timestampMs: 1_700_000_000_001, sequence: 1)
        XCTAssertEqual(early, "001700000000000-000002.traces.gz")
        XCTAssertEqual(late, "001700000000001-000001.logs.pb")
        XCTAssertEqual(OutboxPolicy.ordered([late, "run-context.json", early, ".DS_Store"]), [early, late])
    }

    func testOutboxFileNamesParse() {
        XCTAssertEqual(OutboxPolicy.parse("001700000000000-000002.traces.gz")?.kind, .traces)
        XCTAssertEqual(OutboxPolicy.parse("001700000000000-000002.traces.gz")?.gzip, true)
        XCTAssertEqual(OutboxPolicy.parse("001700000000000-000002.logs.pb")?.gzip, false)
        XCTAssertNil(OutboxPolicy.parse("001700000000000-000002.metrics.pb"))
        XCTAssertNil(OutboxPolicy.parse("notes.txt"))
    }

    func testOverflowDropsTheOldest() {
        let entries = (1...5).map { OutboxPolicy.Entry(name: OutboxPolicy.fileName(kind: .logs, gzip: true, timestampMs: Int64($0), sequence: $0), size: 100) }
        XCTAssertEqual(OutboxPolicy.overflow(entries, maxBytes: 1_000, maxFiles: 3), [entries[0].name, entries[1].name])
        XCTAssertEqual(OutboxPolicy.overflow(entries, maxBytes: 250, maxFiles: 100), [entries[0].name, entries[1].name, entries[2].name])
        XCTAssertEqual(OutboxPolicy.overflow(entries.reversed(), maxBytes: 1_000, maxFiles: 4), [entries[0].name])
        XCTAssertEqual(OutboxPolicy.overflow(entries, maxBytes: 1_000, maxFiles: 10), [])
    }
}
