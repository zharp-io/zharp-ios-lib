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
enum NetworkTracing {
    private static let lock = NSLock()
    private static var instrumentation: URLSessionInstrumentation?

    static func install(runtime: ZharpRuntime) {
        lock.lock()
        defer { lock.unlock() }
        guard instrumentation == nil else { return }

        let origins = runtime.settings.tracingOrigins
        let endpointPrefix = runtime.settings.endpoint.absoluteString
        let configuration = URLSessionInstrumentationConfiguration(
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
            tracer: runtime.tracer,
            semanticConvention: .stable
        )
        instrumentation = URLSessionInstrumentation(configuration: configuration)
    }
}
