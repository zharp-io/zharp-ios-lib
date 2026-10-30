import XCTest
@testable import ZharpCore

private enum PaymentError: Error {
    case declined(code: Int)
}

private struct FriendlyError: LocalizedError {
    var errorDescription: String? { "The card was declined" }
}

final class ErrorFormattingTests: XCTestCase {
    private let stack = [
        "0   ZharpCoreTests   0x0000000100001000 $s9ZharpCore15ErrorFormattingO8describe + 40",
        "1   ZharpCoreTests   0x0000000100002000 $s5Zharp0A0O12captureError + 52",
        "2   MyApp            0x0000000100003000 $s5MyApp8CheckoutC3payyyF + 120",
        "3   UIKitCore        0x0000000180004000 -[UIApplication sendAction:to:from:forEvent:] + 96",
    ]

    func testSwiftErrorTypeAndMessage() {
        let description = ErrorFormatting.describe(PaymentError.declined(code: 51), callStack: stack)
        XCTAssertEqual(description.type, "ZharpCoreTests.PaymentError")
        XCTAssertEqual(description.message, "declined(code: 51)")
        let lines = description.stacktrace.components(separatedBy: "\n")
        XCTAssertEqual(lines.first, "\(description.type): declined(code: 51)")
        XCTAssertEqual(lines.count, 3, "the SDK's frames are dropped")
        XCTAssertTrue(lines[1].hasPrefix("0   MyApp"), lines[1])
        XCTAssertTrue(lines[2].hasPrefix("1   UIKitCore"), lines[2])
    }

    func testLocalizedErrorMessage() {
        let description = ErrorFormatting.describe(FriendlyError(), callStack: [])
        XCTAssertEqual(description.message, "The card was declined")
        XCTAssertEqual(description.stacktrace, "\(description.type): The card was declined")
    }

    func testCocoaErrorType() {
        let error = NSError(domain: NSURLErrorDomain, code: -1009,
                            userInfo: [NSLocalizedDescriptionKey: "The Internet connection appears to be offline."])
        let description = ErrorFormatting.describe(error, callStack: [])
        XCTAssertEqual(description.type, "NSURLErrorDomain(-1009)")
        XCTAssertEqual(description.message, "The Internet connection appears to be offline.")
    }

    func testCleanTypeName() {
        XCTAssertEqual(ErrorFormatting.cleanTypeName("MyApp.(unknown context at $1029a4b2c).LocalError"), "MyApp.LocalError")
        XCTAssertEqual(ErrorFormatting.cleanTypeName("MyApp.(PaymentError in _3B8C8D6A0F93B0AE3F3E1E1A5F86A9C1)"), "MyApp.PaymentError")
        XCTAssertEqual(ErrorFormatting.cleanTypeName("MyApp.Outer.Inner"), "MyApp.Outer.Inner")
    }

    func testHeadline() {
        XCTAssertEqual(ErrorFormatting.headline(type: "AppHang", message: ""), "AppHang")
        XCTAssertEqual(ErrorFormatting.headline(type: "T", message: "m"), "T: m")
    }

    func testStackFramesMatchTheServersAppleFramePattern() throws {
        // zharp-backend src/ingest/errors/fingerprint.ts: /^\d+\s+\S+\s+0x[0-9a-f]+/i
        let pattern = try NSRegularExpression(pattern: "^\\d+\\s+\\S+\\s+0x[0-9a-f]+", options: [.caseInsensitive])
        let image = BinaryImage(loadAddress: 0x1_0000_0000, uuid: "UUID-1", path: "/var/containers/MyApp.app/MyApp")
        let line = CrashFormat.frameLine(index: 3, address: 0x1_0000_1234, image: image)
        XCTAssertEqual(line, "3   MyApp                            0x0000000100001234 0x100000000 + 4660")
        XCTAssertNotNil(pattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)))
    }
}
