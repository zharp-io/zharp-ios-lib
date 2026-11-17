import Logging
import XCTest
@testable import Zharp
@testable import ZharpLogging
import ZharpCore

/// The output capture without touching the test process's own stdout and stderr: the collector
/// is fed bytes directly, and the redirect is tried on a pipe of the test's own.
final class OutputCaptureTests: XCTestCase {
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

    /// A collector whose records land in an array.
    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var _lines: [(CapturedLine, OutputStreamName)] = []
        var lines: [(CapturedLine, OutputStreamName)] { lock.lock(); defer { lock.unlock() }; return _lines }
        func add(_ line: CapturedLine, _ stream: OutputStreamName) { lock.lock(); _lines.append((line, stream)); lock.unlock() }
    }

    private func makeCollector(_ recent: RecentLines = RecentLines()) -> (OutputCollector, Sink) {
        let sink = Sink()
        return (OutputCollector(recent: recent) { sink.add($0, $1) }, sink)
    }

    func testLinesAreReadPerStream() {
        let (collector, sink) = makeCollector()
        collector.ingest(Data("Cart loaded\nERROR pay".utf8), from: .stdout)
        collector.ingest(Data("2026-11-17 09:11:22.123456+0000 Shop[1:a] Hello from NSLog\n".utf8), from: .stderr)
        collector.ingest(Data("ment failed\n".utf8), from: .stdout)
        collector.drain()

        let lines = sink.lines
        XCTAssertEqual(lines.map { $0.0.body }, ["Cart loaded", "Hello from NSLog", "ERROR payment failed"])
        XCTAssertEqual(lines.map { $0.0.level }, [.info, .info, .error])
        XCTAssertEqual(lines.map { $0.1 }, [.stdout, .stderr, .stdout])
    }

    func testAnUnfinishedLineIsSentAfterAMoment() {
        let (collector, sink) = makeCollector()
        collector.ingest(Data("Loading…".utf8), from: .stdout)
        let sent = expectation(description: "flushed")
        DispatchQueue.global().asyncAfter(deadline: .now() + OutputCollector.flushDelay + 0.3) { sent.fulfill() }
        wait(for: [sent], timeout: 2)
        XCTAssertEqual(sink.lines.map { $0.0.body }, ["Loading…"])
    }

    func testLinesAnExactCaptureSentAreNotSentAgain() {
        let recent = RecentLines()
        let (collector, sink) = makeCollector(recent)
        recent.remember("Payment failed for order 7")
        collector.ingest(Data("2026-11-17T09:11:22+0000 error shop : Payment failed for order 7\nSomething else\n".utf8),
                         from: .stdout)
        collector.drain()
        XCTAssertEqual(sink.lines.map { $0.0.body }, ["Something else"])
    }

    func testTheSDKsOwnLinesAreNotSent() {
        let (collector, sink) = makeCollector()
        collector.ingest(Data("2026-11-17 09:11:22.123456+0000 Shop[1:a] [Zharp] Active: service \"shop\"\n".utf8), from: .stderr)
        collector.drain()
        XCTAssertTrue(sink.lines.isEmpty)
    }

    /// The real thing on a pipe standing in for stdout: what's written still reaches the original
    /// destination, byte for byte, and a copy reaches the collector.
    func testTheRedirectTeesToTheOriginalDestination() throws {
        var destination: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&destination), 0)
        _ = fcntl(destination[0], F_SETFL, fcntl(destination[0], F_GETFL) | O_NONBLOCK)
        let fakeStdout = destination[1]

        let copied = Sink()
        let redirect = try XCTUnwrap(OutputRedirect(fd: fakeStdout) { bytes in
            copied.add(CapturedLine(level: .info, body: String(decoding: bytes, as: UTF8.self)), .stdout)
        })
        XCTAssertEqual(redirect.fd, fakeStdout)

        let text = "hello from print\n"
        XCTAssertEqual(text.withCString { write(fakeStdout, $0, strlen($0)) }, text.utf8.count)

        var received = [UInt8]()
        let deadline = Date().addingTimeInterval(3)
        var buffer = [UInt8](repeating: 0, count: 256)
        while received.count < text.utf8.count && Date() < deadline {
            let count = read(destination[0], &buffer, buffer.count)
            if count > 0 { received += buffer.prefix(count) } else { Thread.sleep(forTimeInterval: 0.01) }
        }
        XCTAssertEqual(String(decoding: received, as: UTF8.self), text)
        while copied.lines.isEmpty && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertEqual(copied.lines.map { $0.0.body }.joined(), text)
    }

    func testOutputReachesTheOutboxWithItsStreamAndContext() throws {
        let options = ZharpOptions()
        options.key = "zpk_00000000000000000000000000000000"
        options.service = "ios-tests"
        let settings = try XCTUnwrap(Settings.resolve(options))
        XCTAssertTrue(settings.captureOutput)
        XCTAssertFalse(settings.captureOSLog)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "zharp-tests-\(UUID().uuidString)"))
        let runtime = ZharpRuntime(settings: settings, environment: RuntimeEnvironment(
            directory: directory, defaults: defaults, installsHooks: false, uploads: false))
        runtime.activate()
        runtime.context.setUser(UserInfo(id: "user-42"))

        runtime.log(.info, "Sent by Zharp.log once", attributes: [:])
        let collector = runtime.makeOutputCollector()
        collector.ingest(Data("Printed with print\nSent by Zharp.log once\n".utf8), from: .stdout)
        collector.ingest(Data("WARNING printed to stderr\n".utf8), from: .stderr)
        collector.drain()

        let done = expectation(description: "flushed")
        runtime.flush(timeout: 5) { done.fulfill() }
        wait(for: [done], timeout: 15)

        let outbox = directory.appendingPathComponent("outbox")
        let all = try FileManager.default.contentsOfDirectory(atPath: outbox.path).reduce(Data()) { data, name in
            guard let parsed = OutboxPolicy.parse(name), parsed.kind == .logs,
                  let file = try? Data(contentsOf: outbox.appendingPathComponent(name))
            else { return data }
            return data + (parsed.gzip ? gunzip(file) : file)
        }
        for text in ["Printed with print", "WARNING printed to stderr", "log.source", "log.iostream",
                     "stdout", "stderr", "enduser.id", "user-42"] {
            XCTAssertNotNil(all.range(of: Data(text.utf8)), "missing \(text)")
        }
        XCTAssertEqual(occurrences(of: "Sent by Zharp.log once", in: all), 1)
    }

    func testSwiftLogLevels() {
        XCTAssertEqual(ZharpLogHandler.level(.trace), .debug)
        XCTAssertEqual(ZharpLogHandler.level(.notice), .info)
        XCTAssertEqual(ZharpLogHandler.level(.warning), .warn)
        XCTAssertEqual(ZharpLogHandler.level(.error), .error)
        XCTAssertEqual(ZharpLogHandler.level(.critical), .fatal)
        XCTAssertEqual(ZharpLogHandler.text(.string("a")), "a")
        XCTAssertEqual(ZharpLogHandler.text(.stringConvertible(42)), "42")
    }

    /// OpenTelemetry's gzip: a 10-byte header, raw DEFLATE, an 8-byte trailer.
    private func gunzip(_ data: Data) -> Data {
        guard data.count > 18 else { return Data() }
        let deflated = data.subdata(in: 10..<(data.count - 8))
        return ((try? (deflated as NSData).decompressed(using: .zlib)) as Data?) ?? Data()
    }

    private func occurrences(of text: String, in data: Data) -> Int {
        let needle = Data(text.utf8)
        var count = 0
        var start = data.startIndex
        while let range = data.range(of: needle, in: start..<data.endIndex) {
            count += 1
            start = range.upperBound
        }
        return count
    }
}
