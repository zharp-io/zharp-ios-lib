import XCTest
@testable import Zharp
import ZharpCore

/// Answers every request with the status code the test sets, and remembers the requests.
final class StubProtocol: URLProtocol {
    static let lock = NSLock()
    static var statusCode = 200
    static var requests: [URLRequest] = []

    static func reset(statusCode: Int) {
        lock.lock()
        self.statusCode = statusCode
        requests = []
        lock.unlock()
    }

    static var recorded: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request)
        let code = Self.statusCode
        Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class UploaderTests: XCTestCase {
    private var directory: URL!
    private var outbox: Outbox!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zharp-uploader-\(UUID().uuidString)", isDirectory: true)
        outbox = Outbox(directory: directory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func makeUploader() -> Uploader {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return Uploader(outbox: outbox, endpoint: Endpoint.base("https://ingest.example.com/api/v1/otlp")!,
                        key: "zpk_test", configuration: configuration)
    }

    private func drain(_ uploader: Uploader) {
        let done = expectation(description: "drained")
        uploader.kick { done.fulfill() }
        wait(for: [done], timeout: 10)
    }

    func testSendsOldestFirstWithAuthAndDeletes() {
        StubProtocol.reset(statusCode: 200)
        outbox.enqueue(kind: .traces, body: Data("one".utf8), gzip: true)
        outbox.enqueue(kind: .logs, body: Data("two".utf8), gzip: false)
        drain(makeUploader())

        let requests = StubProtocol.recorded
        XCTAssertEqual(requests.map { $0.url?.absoluteString },
                       ["https://ingest.example.com/api/v1/otlp/v1/traces", "https://ingest.example.com/api/v1/otlp/v1/logs"])
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer zpk_test")
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "Content-Type"), "application/x-protobuf")
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "Content-Encoding"), "gzip")
        XCTAssertNil(requests.last?.value(forHTTPHeaderField: "Content-Encoding"))
        XCTAssertEqual(outbox.count, 0)
    }

    func testRefusedBatchesAreDropped() {
        StubProtocol.reset(statusCode: 400)
        outbox.enqueue(kind: .logs, body: Data("bad".utf8), gzip: false)
        drain(makeUploader())
        XCTAssertEqual(outbox.count, 0)
    }

    func testServerTroubleKeepsTheBatchForLater() {
        StubProtocol.reset(statusCode: 503)
        outbox.enqueue(kind: .logs, body: Data("later".utf8), gzip: false)
        drain(makeUploader())
        XCTAssertEqual(StubProtocol.recorded.count, 1)
        XCTAssertEqual(outbox.count, 1)
    }

    func testRejectedKeyStopsSendingAndKeepsNothing() {
        StubProtocol.reset(statusCode: 401)
        outbox.enqueue(kind: .logs, body: Data("a".utf8), gzip: false)
        outbox.enqueue(kind: .logs, body: Data("b".utf8), gzip: false)
        let uploader = makeUploader()
        drain(uploader)
        XCTAssertEqual(StubProtocol.recorded.count, 1)
        XCTAssertEqual(outbox.count, 0)

        outbox.enqueue(kind: .logs, body: Data("c".utf8), gzip: false)
        drain(uploader)
        XCTAssertEqual(StubProtocol.recorded.count, 1, "paused: nothing more is sent")
        XCTAssertEqual(outbox.count, 0)
    }

    func testOutboxIsCapped() {
        let body = Data(repeating: 7, count: 1024)
        for _ in 0..<(OutboxPolicy.maxFiles + 20) {
            outbox.enqueue(kind: .logs, body: body, gzip: false)
        }
        XCTAssertEqual(outbox.count, OutboxPolicy.maxFiles)
    }

    func testOutboxHTTPClientStoresTheBodyAndAnswersOK() {
        let client = OutboxHTTPClient(kind: .traces, outbox: outbox)
        var request = URLRequest(url: URL(string: "https://ingest.example.com/v1/traces")!)
        request.httpBody = Data("spans".utf8)
        request.setValue("gzip", forHTTPHeaderField: "Content-Encoding")
        var status: Int?
        client.send(request: request) { result in status = try? result.get().statusCode }
        XCTAssertEqual(status, 200)
        let item = outbox.oldest()
        XCTAssertEqual(item?.kind, .traces)
        XCTAssertEqual(item?.gzip, true)
        XCTAssertEqual(item.flatMap { try? Data(contentsOf: $0.url) }, Data("spans".utf8))
    }
}
