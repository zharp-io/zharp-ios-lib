import OpenTelemetryApi
import XCTest
@testable import Zharp
import ZharpCore

/// End to end through OpenTelemetry: record something, flush, and read the OTLP protobuf the
/// exporters left in the outbox. Protobuf stores strings as plain UTF-8, so attribute keys and
/// values can be found in the bytes without decoding.
final class RuntimeTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zharp-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func makeRuntime(_ configure: (ZharpOptions) -> Void = { _ in }) throws -> ZharpRuntime {
        let options = ZharpOptions()
        options.key = "zpk_00000000000000000000000000000000"
        options.service = "ios-tests"
        options.environment = "test"
        options.release = "1.2.3"
        configure(options)
        let settings = try XCTUnwrap(Settings.resolve(options))
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "zharp-tests-\(UUID().uuidString)"))
        let environment = RuntimeEnvironment(directory: directory, defaults: defaults, installsHooks: false, uploads: false)
        let runtime = ZharpRuntime(settings: settings, environment: environment)
        runtime.activate()
        return runtime
    }

    private func flush(_ runtime: ZharpRuntime) {
        let done = expectation(description: "flushed")
        runtime.flush(timeout: 5) { done.fulfill() }
        wait(for: [done], timeout: 15)
    }

    /// The decoded bodies of the outbox files of one kind.
    private func batches(_ kind: SignalKind) throws -> [Data] {
        let outbox = directory.appendingPathComponent("outbox")
        let names = OutboxPolicy.ordered(try FileManager.default.contentsOfDirectory(atPath: outbox.path))
        return try names.compactMap { name -> Data? in
            guard let parsed = OutboxPolicy.parse(name), parsed.kind == kind else { return nil }
            let data = try Data(contentsOf: outbox.appendingPathComponent(name))
            if parsed.gzip { return try gunzip(data) }
            return data
        }
    }

    /// OpenTelemetry's gzip: a 10-byte header, raw DEFLATE, an 8-byte trailer.
    private func gunzip(_ data: Data) throws -> Data {
        XCTAssertGreaterThan(data.count, 18)
        XCTAssertEqual(Array(data.prefix(2)), [0x1f, 0x8b])
        let deflated = data.subdata(in: 10..<(data.count - 8))
        return try (deflated as NSData).decompressed(using: .zlib) as Data
    }

    private func assertContains(_ data: Data, _ texts: [String], file: StaticString = #filePath, line: UInt = #line) {
        for text in texts {
            XCTAssertNotNil(data.range(of: Data(text.utf8)), "missing \(text)", file: file, line: line)
        }
    }

    func testLogsCarryResourceAndContext() throws {
        let runtime = try makeRuntime()
        runtime.context.setUser(UserInfo(id: "user-42", email: "ada@example.com"))
        runtime.context.setTag("plan", "pro")
        runtime.log(.info, "Checkout started", attributes: AttributeMapping.map(["items": 3]))
        flush(runtime)

        let logs = try batches(.logs)
        XCTAssertFalse(logs.isEmpty)
        let all = logs.reduce(Data(), +)
        assertContains(all, [
            "Checkout started", "items",
            "service.name", "ios-tests", "service.version", "1.2.3",
            "deployment.environment.name", "test",
            "telemetry.sdk.language", "swift", "telemetry.sdk.name", "zharp",
            "device.id", "device.model.name", "os.name", "os.version",
            "session.id", runtime.context.snapshot().sessionId,
            "enduser.id", "user-42", "enduser.email", "ada@example.com",
            "plan", "pro",
        ])
    }

    func testCapturedErrorsAreHandledErrors() throws {
        enum CheckoutError: Error { case cardDeclined }
        let runtime = try makeRuntime()
        runtime.captureError(CheckoutError.cardDeclined, attributes: ["orderId": "o-1"], callStack: Thread.callStackSymbols)
        flush(runtime)

        let all = try batches(.logs).reduce(Data(), +)
        assertContains(all, ["exception.type", "CheckoutError", "exception.message", "cardDeclined",
                             "exception.stacktrace", "zharp.handled", "true", "orderId", "o-1"])
    }

    func testSpansCarryContextAndScreens() throws {
        let runtime = try makeRuntime()
        runtime.screenDidAppear("Checkout")
        let span = runtime.beginSpan("load cart", attributes: ["cart.size": 2])
        span.end()
        flush(runtime)

        let all = try batches(.traces).reduce(Data(), +)
        assertContains(all, ["screen Checkout", "app.screen.name", "Checkout", "load cart", "cart.size",
                             "session.id", "telemetry.sdk.language", "swift"])
    }

    func testSampleRateZeroKeepsLogsAndDropsTraces() throws {
        let runtime = try makeRuntime { $0.sampleRate = 0 }
        runtime.beginSpan("dropped", attributes: [:]).end()
        runtime.log(.warn, "kept", attributes: [:])
        flush(runtime)

        XCTAssertTrue(try batches(.traces).isEmpty)
        assertContains(try batches(.logs).reduce(Data(), +), ["kept"])
    }

    func testCrashFromThePreviousRunIsReportedWithItsContext() throws {
        // What the last run left: its context and a signal crash report.
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("crashes"), withIntermediateDirectories: true)
        let previous = ContextSnapshot(sessionId: "previous-session", user: UserInfo(id: "user-7"),
                                       screen: "Payment", release: "1.2.2")
        try JSONEncoder().encode(previous).write(to: directory.appendingPathComponent("run-context.json"))
        let report = "zharp-crash 1\nsignal \(SIGSEGV)\ntime 1700000000\npc 0x100002000\nframes\n0x100009000\n0x100003000\nimages\n0x100000000 11111111-2222-3333-4444-555555555555 /app/MyApp\n"
        let reportURL = directory.appendingPathComponent("crashes").appendingPathComponent(CrashReporter.signalFileName)
        try report.write(to: reportURL, atomically: true, encoding: .utf8)

        let runtime = try makeRuntime()
        flush(runtime)

        let all = try batches(.logs).reduce(Data(), +)
        assertContains(all, ["EXC_BAD_ACCESS", "exception.stacktrace", "Binary Images:", "MyApp",
                             "zharp.handled", "false", "previous-session", "user-7", "Payment", "1.2.2"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: reportURL.path), "reported crashes are removed")
        XCTAssertNotEqual(runtime.context.snapshot().sessionId, "previous-session")
    }

    func testTraceHeadersForTracingOrigins() throws {
        let runtime = try makeRuntime { $0.tracingOrigins = ["api.example.com"] }
        runtime.context.setUser(UserInfo(id: "ada@example.com"))
        let span = runtime.beginSpan("HTTP GET", attributes: [:])
        var request = URLRequest(url: URL(string: "https://api.example.com/cart")!)
        request.setValue("tenant=acme", forHTTPHeaderField: "baggage")
        runtime.injectTraceHeaders(into: &request, span: span)
        span.end()

        let traceparent = try XCTUnwrap(request.value(forHTTPHeaderField: "traceparent"))
        XCTAssertEqual(traceparent, "00-\(span.context.traceId.hexString)-\(span.context.spanId.hexString)-01")
        let sessionId = runtime.context.snapshot().sessionId
        XCTAssertEqual(request.value(forHTTPHeaderField: "baggage"),
                       "tenant=acme,enduser.id=ada@example.com,session.id=\(sessionId)")
        XCTAssertTrue(runtime.settings.tracingOrigins.matches(request.url!))
        XCTAssertFalse(runtime.settings.tracingOrigins.matches(URL(string: "https://cdn.other.com/x")!))
    }

    func testMissingKeyDoesNotStart() {
        let options = ZharpOptions()
        XCTAssertNil(Settings.resolve(options))
        options.key = "zpk_x"
        options.endpoint = "ftp://nope"
        XCTAssertNil(Settings.resolve(options))
    }

    func testCallsBeforeStartAreHarmless() throws {
        XCTAssertFalse(Zharp.isStarted)
        Zharp.log.info("ignored")
        Zharp.setUser(id: "u")
        Zharp.captureError(NSError(domain: "x", code: 1))
        XCTAssertEqual(Zharp.startSpan("noop") { 41 + 1 }, 42)
        XCTAssertThrowsError(try Zharp.startSpan("throws") { throw NSError(domain: "x", code: 2) })
        let done = expectation(description: "flush completes")
        Zharp.flush { done.fulfill() }
        wait(for: [done], timeout: 1)
    }
}
