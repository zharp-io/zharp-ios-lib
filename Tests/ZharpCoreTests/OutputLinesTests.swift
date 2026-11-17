import XCTest
@testable import ZharpCore

final class OutputLineParserTests: XCTestCase {
    private func parse(_ line: String, _ stream: OutputStreamName = .stdout) -> CapturedLine? {
        OutputLineParser.parse(line, stream: stream)
    }

    func testPlainLinesFallBackToTheirStream() {
        XCTAssertEqual(parse("Cart loaded"), CapturedLine(level: .info, body: "Cart loaded"))
        XCTAssertEqual(parse("Cart loaded", .stderr), CapturedLine(level: .warn, body: "Cart loaded"))
    }

    func testLevelWordsNearTheStart() {
        XCTAssertEqual(parse("ERROR Payment failed")?.level, .error)
        XCTAssertEqual(parse("[warn] Slow response")?.level, .warn)
        XCTAssertEqual(parse("ts=1 level=error msg=boom")?.level, .error)
        XCTAssertEqual(parse("2026-11-17T09:11:22+0000 debug shop : cache miss")?.level, .debug)
        XCTAssertEqual(parse("Fatal error: Unexpectedly found nil", .stderr)?.level, .fatal)
        XCTAssertEqual(parse("Error: no network", .stderr)?.level, .error)
        // Inside another word, it's not a level.
        XCTAssertEqual(parse("Errors so far: 0")?.level, .info)
        XCTAssertEqual(parse("informational", .stderr)?.level, .warn)
    }

    func testOnlyTheOpeningIsSearched() {
        let line = String(repeating: "x", count: 130) + " ERROR"
        XCTAssertEqual(parse(line)?.level, .info)
    }

    func testJSONRecordsUseTheirLevelAndMessage() {
        XCTAssertEqual(parse(#"{"level":"error","msg":"Payment failed","orderId":7}"#),
                       CapturedLine(level: .error, body: "Payment failed"))
        XCTAssertEqual(parse(#"{"severity":"WARNING","message":"Slow"}"#), CapturedLine(level: .warn, body: "Slow"))
        XCTAssertEqual(parse(#"{"level":50,"msg":"pino style"}"#)?.level, .error)
        XCTAssertEqual(parse(#"{"level":30,"msg":"pino info"}"#)?.level, .info)
        XCTAssertEqual(parse(#"{"level":60,"msg":"pino fatal"}"#)?.level, .fatal)
        // No message field: the whole line. No level: the stream's.
        XCTAssertEqual(parse(#"{"event_id":1}"#, .stderr), CapturedLine(level: .warn, body: #"{"event_id":1}"#))
        // Not JSON after all: read as text.
        XCTAssertEqual(parse("{not json, error: 1}")?.level, .error)
    }

    func testNSLogPrefixIsDroppedAndItsLinesAreInfo() {
        let line = "2026-11-17 09:11:22.123456+0000 ShopApp[1234:5e6f7] Cart loaded with 3 items"
        XCTAssertEqual(parse(line, .stderr), CapturedLine(level: .info, body: "Cart loaded with 3 items"))
        let error = "2026-11-17 09:11:22.123+0100 My Shop[99:1a] Error: card declined"
        XCTAssertEqual(parse(error, .stderr), CapturedLine(level: .error, body: "Error: card declined"))
        // Only stderr gets NSLog's prefix.
        XCTAssertEqual(parse(line, .stdout)?.body, line)
    }

    func testColourCodesAndTrailingWhitespaceAreDropped() {
        XCTAssertEqual(parse("\u{1B}[31mERROR\u{1B}[0m boom  \r"), CapturedLine(level: .error, body: "ERROR boom"))
    }

    func testBlankAndOwnLinesAreSkipped() {
        XCTAssertNil(parse(""))
        XCTAssertNil(parse("   \t"))
        XCTAssertNil(parse("\u{1B}[0m"))
        XCTAssertNil(parse("[Zharp] Active: service \"shop-ios\""))
        XCTAssertNil(parse("2026-11-17 09:11:22.123456+0000 ShopApp[1234:5e6f7] [Zharp] Warning: no key", .stderr))
        XCTAssertNil(parse("2026-11-17 09:11:22.123456+0000 ShopApp[1234:5e6f7] ", .stderr))
    }

    func testLongLinesAreCut() {
        let long = String(repeating: "a", count: OutputLineParser.maxLineBytes + 500)
        XCTAssertEqual(parse(long)?.body.utf8.count, OutputLineParser.maxLineBytes)
    }
}

final class LineBufferTests: XCTestCase {
    private func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

    func testCompleteLinesComeOutAndTheRestWaits() {
        var buffer = LineBuffer()
        XCTAssertEqual(buffer.append(bytes("one\ntw")), ["one"])
        XCTAssertTrue(buffer.hasPending)
        XCTAssertEqual(buffer.append(bytes("o\r\nthree\n")), ["two", "three"])
        XCTAssertFalse(buffer.hasPending)
        XCTAssertNil(buffer.flush())
    }

    func testAnUnfinishedLineCanBeFlushed() {
        var buffer = LineBuffer()
        XCTAssertEqual(buffer.append(bytes("Loading…")), [])
        XCTAssertEqual(buffer.flush(), "Loading…")
        XCTAssertFalse(buffer.hasPending)
    }

    func testMultibyteCharactersSplitAcrossReads() {
        var buffer = LineBuffer()
        let text = bytes("café ✓\n")
        XCTAssertEqual(buffer.append(text.prefix(4)), [])
        XCTAssertEqual(buffer.append(text.dropFirst(4)), ["café ✓"])
    }

    func testLongLinesAreSentInPieces() {
        var buffer = LineBuffer(maxLineBytes: 4)
        XCTAssertEqual(buffer.append(bytes("abcdefghij\n")), ["abcd", "efgh", "ij"])
    }

    func testEmptyLinesStayLines() {
        var buffer = LineBuffer()
        XCTAssertEqual(buffer.append(bytes("\n\n")), ["", ""])
    }
}

final class RecentLinesTests: XCTestCase {
    private var now = Date(timeIntervalSince1970: 1_700_000_000)

    private func make() -> RecentLines {
        RecentLines(window: 3, capacity: 3, now: { [unowned self] in self.now })
    }

    func testALineContainingARecentBodyIsAlreadySent() {
        let recent = make()
        recent.remember("Payment failed for order 7")
        XCTAssertTrue(recent.alreadySent("2026-11-17T09:11:22+0000 error shop : Payment   failed for order 7"))
    }

    func testAMatchIsUsedUp() {
        let recent = make()
        recent.remember("Payment failed")
        XCTAssertTrue(recent.alreadySent("Payment failed"))
        XCTAssertFalse(recent.alreadySent("Payment failed"))
    }

    func testOtherLinesAreNot() {
        let recent = make()
        recent.remember("Payment failed")
        XCTAssertFalse(recent.alreadySent("Cart loaded"))
    }

    func testBodiesExpire() {
        let recent = make()
        recent.remember("Payment failed")
        now = now.addingTimeInterval(3.5)
        XCTAssertFalse(recent.alreadySent("Payment failed"))
    }

    func testShortBodiesAreNotRemembered() {
        let recent = make()
        recent.remember("ok")
        XCTAssertFalse(recent.alreadySent("ok"))
    }

    func testOnlyTheNewestAreKept() {
        let recent = make()
        for text in ["first line", "second line", "third line", "fourth line"] { recent.remember(text) }
        XCTAssertFalse(recent.alreadySent("first line"))
        XCTAssertTrue(recent.alreadySent("fourth line"))
    }
}

final class OSLogFilterTests: XCTestCase {
    func testTheAppsOwnEntries() {
        XCTAssertTrue(OSLogFilter.isApps(subsystem: "com.shop.app", sender: "ShopKit", executable: "Shop"))
        XCTAssertTrue(OSLogFilter.isApps(subsystem: "", sender: "Shop", executable: "Shop"))
    }

    func testNotApplesOrZharps() {
        XCTAssertFalse(OSLogFilter.isApps(subsystem: "com.apple.UIKit", sender: "UIKitCore", executable: "Shop"))
        XCTAssertFalse(OSLogFilter.isApps(subsystem: "", sender: "Foundation", executable: "Shop"))
        XCTAssertFalse(OSLogFilter.isApps(subsystem: "io.zharp.ios", sender: "Shop", executable: "Shop"))
        XCTAssertFalse(OSLogFilter.isApps(subsystem: "", sender: "Shop", executable: nil))
    }
}
