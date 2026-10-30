import Foundation
import OpenTelemetryProtocolExporterHttp
import ZharpCore

/// The HTTP client handed to OpenTelemetry's OTLP/HTTP exporters. The exporters still do what
/// they are good at — encoding spans and log records as OTLP protobuf and gzipping it — but
/// instead of posting the request, this stores its body in the `Outbox`. The `Uploader` sends
/// it from there, which gives the SDK what the exporters don't have: a buffer on disk that
/// survives going offline and app restarts, a cap on it, retries that respect 429/503 and
/// Retry-After, and a pause when the key is rejected.
///
/// It always answers 200, so the exporters never keep their own unbounded retry queue.
final class OutboxHTTPClient: HTTPClient, @unchecked Sendable {
    private let kind: SignalKind
    private let outbox: Outbox

    init(kind: SignalKind, outbox: Outbox) {
        self.kind = kind
        self.outbox = outbox
    }

    func send(request: URLRequest, completion: @escaping (Result<HTTPURLResponse, Error>) -> Void) {
        store(request)
        completion(Self.accepted(request.url))
    }

    func send(request: URLRequest) async throws -> HTTPURLResponse {
        store(request)
        return try Self.accepted(request.url).get()
    }

    private func store(_ request: URLRequest) {
        guard let body = request.httpBody else { return }
        let gzip = request.value(forHTTPHeaderField: "Content-Encoding")?.lowercased() == "gzip"
        outbox.enqueue(kind: kind, body: body, gzip: gzip)
    }

    private static func accepted(_ url: URL?) -> Result<HTTPURLResponse, Error> {
        let target = url ?? URL(fileURLWithPath: "/")
        guard let response = HTTPURLResponse(url: target, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil) else {
            return .failure(OutboxError.noResponse)
        }
        return .success(response)
    }
}

enum OutboxError: Error {
    case noResponse
}
