import Foundation
import OpenTelemetryApi
import URLSessionInstrumentation
import ZharpCore

/// URLSession requests as CLIENT spans (`http.request.method`, `url.full`,
/// `http.response.status_code`), using OpenTelemetry's URLSession instrumentation.
///
/// - Zharp's own uploads are not traced.
/// - Only requests to `tracingOrigins` get `traceparent` and `baggage` (`enduser.id`,
///   `session.id`); the header values come from ZharpCore's `TracePropagation`, set in
///   `injectCustomHeaders`, which the instrumentation applies over its own propagators' values.
/// - Secret-looking query values in `url.full` (`token`, `key`, `sig`, …) are `[Filtered]`.
/// - With `captureBodies`, the request and response bodies go on the span (see `BodyAttributes`).
///   The instrumentation hands over the response data just before it ends the span, so the
///   span keeps the time the response arrived; what the app receives is never touched.
enum NetworkTracing {
    private static let lock = NSLock()
    private static var instrumentation: URLSessionInstrumentation?

    static func install(runtime: ZharpRuntime) {
        lock.lock()
        defer { lock.unlock() }
        guard instrumentation == nil else { return }

        let origins = runtime.settings.tracingOrigins
        let endpointPrefix = runtime.settings.endpoint.absoluteString
        let bodies = runtime.settings.bodies
        let bodyURLs = runtime.settings.bodyURLs
        let pending = PendingRequests()
        // Delegate and async tasks only hand over their data when asked to record it.
        var recordPayload: ((URLSession) -> Bool?)?
        if bodies != nil { recordPayload = { _ in true } }

        let configuration = URLSessionInstrumentationConfiguration(
            shouldRecordPayload: recordPayload,
            shouldInstrument: { request in
                guard let url = request.url?.absoluteString else { return false }
                return !url.hasPrefix(endpointPrefix)
            },
            shouldInjectTracingHeaders: { request in
                guard let url = request.url, !url.absoluteString.hasPrefix(endpointPrefix) else { return false }
                return origins.matches(url)
            },
            injectCustomHeaders: { [weak runtime] request, span in
                runtime?.injectTraceHeaders(into: &request, span: span)
            },
            createdRequest: { request, span in
                if let full = request.url?.absoluteString {
                    let redacted = BodyAttributes.redactURL(full)
                    if redacted != full { span.setAttribute(key: "url.full", value: AttributeValue.string(redacted)) }
                }
                guard bodies != nil, let url = request.url, bodyURLs?.matches(url) ?? true else { return }
                pending.store(request, for: span)
            },
            receivedResponse: { response, dataOrFile, span in
                guard let settings = bodies, let request = pending.take(for: span) else { return }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard settings.wanted(status: status) else { return }
                var attributes = NetworkBodies.request(request, settings: settings)
                attributes.merge(NetworkBodies.response(response, dataOrFile: dataOrFile, settings: settings)) { _, new in new }
                NetworkBodies.set(attributes, on: span)
            },
            receivedError: { _, dataOrFile, status, span in
                guard let settings = bodies, let request = pending.take(for: span) else { return }
                guard settings.wanted(status: status) else { return }
                var attributes = NetworkBodies.request(request, settings: settings)
                if let data = dataOrFile as? Data, !data.isEmpty {
                    attributes.merge(BodyAttributes.attributes(.response, data: data, contentType: nil, settings: settings)) { _, new in new }
                }
                NetworkBodies.set(attributes, on: span)
            },
            tracer: runtime.tracer,
            semanticConvention: .stable
        )
        instrumentation = URLSessionInstrumentation(configuration: configuration)
    }
}

/// Requests whose bodies may be captured, from the span's start until its response.
final class PendingRequests {
    /// Requests that never finish (a task the app abandons) must not pile up.
    private static let limit = 500
    private let lock = NSLock()
    private var requests: [String: URLRequest] = [:]
    private var order: [String] = []

    func store(_ request: URLRequest, for span: Span) {
        let id = span.context.spanId.hexString
        lock.lock()
        defer { lock.unlock() }
        if requests[id] == nil { order.append(id) }
        requests[id] = request
        while order.count > PendingRequests.limit {
            requests[order.removeFirst()] = nil
        }
    }

    func take(for span: Span) -> URLRequest? {
        let id = span.context.spanId.hexString
        lock.lock()
        defer { lock.unlock() }
        guard let request = requests.removeValue(forKey: id) else { return nil }
        if let index = order.firstIndex(of: id) { order.remove(at: index) }
        return request
    }
}

/// Bodies as span attributes, from what URLSession has: `httpBody` (a stream is described, never
/// read), and the response's data or downloaded file.
enum NetworkBodies {
    static func request(_ request: URLRequest, settings: BodySettings) -> [String: AttrValue] {
        let type = request.value(forHTTPHeaderField: "Content-Type")
        if let body = request.httpBody, !body.isEmpty {
            return BodyAttributes.attributes(.request, data: body, contentType: type, settings: settings)
        }
        if request.httpBodyStream != nil {
            let length = request.value(forHTTPHeaderField: "Content-Length").flatMap { Int($0) }
            return BodyAttributes.described(.request, contentType: type, size: length)
        }
        return [:]
    }

    static func response(_ response: URLResponse, dataOrFile: Any?, settings: BodySettings) -> [String: AttrValue] {
        let http = response as? HTTPURLResponse
        let type = http?.value(forHTTPHeaderField: "Content-Type") ?? response.mimeType
        let status = http?.statusCode ?? 0
        if let data = dataOrFile as? Data, !data.isEmpty {
            return BodyAttributes.attributes(.response, data: data, contentType: type, settings: settings)
        }
        if let file = dataOrFile as? URL, file.isFileURL {
            let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? NSNumber
            guard BodyAttributes.isTextual(type), let handle = try? FileHandle(forReadingFrom: file) else {
                return BodyAttributes.described(.response, contentType: type, size: size?.intValue)
            }
            defer { try? handle.close() }
            let data = handle.readData(ofLength: settings.rawLimit + 1)
            return BodyAttributes.attributes(.response, data: data, contentType: type, settings: settings)
        }
        // No data handed over: a body that isn't text is still described from its headers.
        if status != 204, status != 304, !BodyAttributes.isTextual(type), response.expectedContentLength != 0 {
            let length = response.expectedContentLength > 0 ? Int(response.expectedContentLength) : nil
            return BodyAttributes.described(.response, contentType: type, size: length)
        }
        return [:]
    }

    static func set(_ attributes: [String: AttrValue], on span: Span) {
        for (key, value) in attributes {
            span.setAttribute(key: key, value: OTelBridge.value(value))
        }
    }
}
