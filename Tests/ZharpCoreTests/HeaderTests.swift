import XCTest
@testable import ZharpCore

final class HeaderTests: XCTestCase {
    func testWhatWentOutAndCameBackWithSecretsFiltered() {
        let sent = HeaderAttributes.attributes(side: "request", headers: [
            ("Authorization", "Bearer user-token"), ("X-Client", "ios"), ("X-Tenant", "acme"), ("Cookie", "sid=1"),
        ], redact: ["x-tenant"])
        XCTAssertEqual(sent["http.request.header.authorization"], .string("[Filtered]"))
        XCTAssertEqual(sent["http.request.header.x-client"], .string("ios"))
        XCTAssertEqual(sent["http.request.header.x-tenant"], .string("[Filtered]"), "redactHeaders")
        XCTAssertEqual(sent["http.request.header.cookie"], .string("[Filtered]"))

        let back = HeaderAttributes.attributes(side: "response", headers: [
            ("X-Request-Id", "req-7"), ("Vary", "Accept"), ("vary", "Origin"), ("X-Session-Token", "t"),
        ])
        XCTAssertEqual(back["http.response.header.x-request-id"], .string("req-7"))
        XCTAssertEqual(back["http.response.header.vary"], .string("Accept, Origin"), "repeats joined")
        XCTAssertEqual(back["http.response.header.x-session-token"], .string("[Filtered]"), "secret-looking names too")
    }

    func testCapsKeepASpanSmall() {
        let many = (0..<60).map { ("x-h\($0)", "v") }
        XCTAssertEqual(HeaderAttributes.attributes(side: "request", headers: many).count, 40)
        let long = HeaderAttributes.attributes(side: "request", headers: [("x-long", String(repeating: "a", count: 2000))])
        guard case .string(let text)? = long["http.request.header.x-long"] else { return XCTFail("missing") }
        XCTAssertEqual(text.count, 513)
        XCTAssertTrue(text.hasSuffix("…"))
    }
}
