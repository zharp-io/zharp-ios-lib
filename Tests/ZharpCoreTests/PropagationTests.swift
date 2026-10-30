import XCTest
@testable import ZharpCore

final class PropagationTests: XCTestCase {
    private let traceId = "4bf92f3577b34da6a3ce929d0e0e4736"
    private let spanId = "00f067aa0ba902b7"

    func testTraceparent() {
        XCTAssertEqual(TracePropagation.traceparent(traceId: traceId, spanId: spanId, sampled: true),
                       "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01")
        XCTAssertEqual(TracePropagation.traceparent(traceId: traceId.uppercased(), spanId: spanId, sampled: false),
                       "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-00")
    }

    func testInvalidIdsGiveNoTraceparent() {
        XCTAssertNil(TracePropagation.traceparent(traceId: String(repeating: "0", count: 32), spanId: spanId, sampled: true))
        XCTAssertNil(TracePropagation.traceparent(traceId: traceId, spanId: String(repeating: "0", count: 16), sampled: true))
        XCTAssertNil(TracePropagation.traceparent(traceId: "abc", spanId: spanId, sampled: true))
        XCTAssertNil(TracePropagation.traceparent(traceId: traceId, spanId: "zzzzzzzzzzzzzzzz", sampled: true))
    }

    func testBaggage() {
        let header = TracePropagation.baggage([(key: "enduser.id", value: "ada@example.com"),
                                               (key: "session.id", value: "s-1")], existing: nil)
        XCTAssertEqual(header, "enduser.id=ada@example.com,session.id=s-1")
    }

    func testBaggageLeavesOutMissingValues() {
        XCTAssertEqual(TracePropagation.baggage([(key: "enduser.id", value: nil),
                                                 (key: "session.id", value: "s-1")], existing: nil),
                       "session.id=s-1")
        XCTAssertNil(TracePropagation.baggage([(key: "enduser.id", value: "")], existing: nil))
    }

    func testBaggageKeepsTheAppsEntriesAndReplacesOurs() {
        let header = TracePropagation.baggage([(key: "session.id", value: "new")],
                                              existing: "tenant=acme, session.id=old;prop=1,flag")
        XCTAssertEqual(header, "tenant=acme,flag,session.id=new")
    }

    func testBaggageValuesArePercentEncoded() {
        XCTAssertEqual(TracePropagation.percentEncode("Ada Lovelace, \"PhD\"; 100%"),
                       "Ada%20Lovelace%2C%20%22PhD%22%3B%20100%25")
        XCTAssertEqual(TracePropagation.percentEncode("zoë"), "zo%C3%AB")
        XCTAssertEqual(TracePropagation.percentEncode("a-b_c.d@e+f"), "a-b_c.d@e+f")
    }

    func testTracingOriginsByHost() {
        let origins = TracingOrigins(["api.example.com", "API.shop.io"])
        XCTAssertTrue(origins.matches(URL(string: "https://api.example.com/v1/cart")!))
        XCTAssertTrue(origins.matches(URL(string: "http://api.example.com:8080/x")!))
        XCTAssertTrue(origins.matches(URL(string: "https://api.shop.io")!))
        XCTAssertFalse(origins.matches(URL(string: "https://example.com/")!))
        XCTAssertFalse(origins.matches(URL(string: "https://evil-api.example.com/")!))
        XCTAssertFalse(origins.matches(URL(string: "https://api.example.com.evil.io/")!))
        XCTAssertFalse(origins.matches(URL(string: "https://www.google-analytics.com/collect")!))
    }

    func testTracingOriginsWildcardAndPort() {
        let origins = TracingOrigins(["*.example.com", "localhost:3000"])
        XCTAssertTrue(origins.matches(URL(string: "https://api.example.com/")!))
        XCTAssertTrue(origins.matches(URL(string: "https://a.b.example.com/")!))
        XCTAssertFalse(origins.matches(URL(string: "https://example.com/")!))
        XCTAssertTrue(origins.matches(URL(string: "http://localhost:3000/api")!))
        XCTAssertFalse(origins.matches(URL(string: "http://localhost:4000/api")!))
    }

    func testTracingOriginsByOrigin() {
        let origins = TracingOrigins(["https://api.example.com"])
        XCTAssertTrue(origins.matches(URL(string: "https://api.example.com/v1")!))
        XCTAssertTrue(origins.matches(URL(string: "https://api.example.com:443/v1")!))
        XCTAssertFalse(origins.matches(URL(string: "http://api.example.com/v1")!))
        XCTAssertFalse(origins.matches(URL(string: "https://api.example.com:8443/v1")!))
    }

    func testNoOriginsMatchNothing() {
        let origins = TracingOrigins([])
        XCTAssertTrue(origins.isEmpty)
        XCTAssertFalse(origins.matches(URL(string: "https://api.example.com/")!))
        XCTAssertTrue(TracingOrigins(["", "  ", "*"]).isEmpty)
    }

    func testSamplingRate() {
        XCTAssertEqual(Sampling.clampRate(2), 1)
        XCTAssertEqual(Sampling.clampRate(-1), 0)
        XCTAssertEqual(Sampling.clampRate(.nan), 1)
        XCTAssertTrue(Sampling.decide(parentSampled: nil, traceIdLow: .max, rate: 1))
        XCTAssertFalse(Sampling.decide(parentSampled: nil, traceIdLow: 0, rate: 0))
        XCTAssertTrue(Sampling.decide(parentSampled: nil, traceIdLow: 10, rate: 0.5))
        XCTAssertFalse(Sampling.decide(parentSampled: nil, traceIdLow: .max - 10, rate: 0.5))
    }

    func testSamplingFollowsTheParent() {
        XCTAssertTrue(Sampling.decide(parentSampled: true, traceIdLow: .max, rate: 0))
        XCTAssertFalse(Sampling.decide(parentSampled: false, traceIdLow: 0, rate: 1))
    }

    func testSamplingKeepsRoughlyTheRate() {
        var generator = SystemRandomNumberGenerator()
        let kept = (0..<10_000).filter { _ in
            Sampling.decide(parentSampled: nil, traceIdLow: generator.next(), rate: 0.25)
        }.count
        XCTAssertGreaterThan(kept, 2_200)
        XCTAssertLessThan(kept, 2_800)
    }
}
