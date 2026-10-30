import Foundation
import OpenTelemetryApi
import OpenTelemetrySdk
import ZharpCore

/// The plain-Swift values from ZharpCore as OpenTelemetry values.
enum OTelBridge {
    static func value(_ value: AttrValue) -> AttributeValue {
        switch value {
        case let .string(string): return AttributeValue.string(string)
        case let .int(int): return AttributeValue.int(int)
        case let .double(double): return AttributeValue.double(double)
        case let .bool(bool): return AttributeValue.bool(bool)
        case let .stringArray(strings):
            return AttributeValue.array(AttributeArray(values: strings.map { AttributeValue.string($0) }))
        }
    }

    static func attributes(_ attributes: [String: AttrValue]) -> [String: AttributeValue] {
        var out: [String: AttributeValue] = [:]
        for (key, value) in attributes { out[key] = self.value(value) }
        return out
    }

    static func severity(_ level: LogLevel) -> Severity {
        Severity(rawValue: level.rawValue) ?? .info
    }
}

/// Puts the current session, user, screen and tags on every span as it starts.
final class ContextSpanProcessor: SpanProcessor {
    private let context: ContextState

    init(context: ContextState) {
        self.context = context
    }

    var isStartRequired: Bool { true }
    var isEndRequired: Bool { false }

    func onStart(parentContext: SpanContext?, span: ReadableSpan) {
        span.setAttributes(OTelBridge.attributes(context.snapshot().attributes()))
    }

    func onEnd(span: ReadableSpan) {}

    func shutdown(explicitTimeout: TimeInterval?) {}

    func forceFlush(timeout: TimeInterval?) {}
}

/// `sampleRate` as an OpenTelemetry sampler; the rule itself is `Sampling.decide` in ZharpCore.
final class ZharpSampler: Sampler {
    private let rate: Double

    init(rate: Double) {
        self.rate = Sampling.clampRate(rate)
    }

    func shouldSample(parentContext: SpanContext?,
                      traceId: TraceId,
                      name: String,
                      kind: SpanKind,
                      attributes: [String: AttributeValue],
                      parentLinks: [SpanData.Link]) -> Decision {
        var parentSampled: Bool?
        if let parent = parentContext, parent.isValid { parentSampled = parent.isSampled }
        return SamplingDecision(isSampled: Sampling.decide(parentSampled: parentSampled,
                                                           traceIdLow: traceId.rawLowerLong,
                                                           rate: rate))
    }

    var description: String { "ZharpSampler{\(rate)}" }
}

private struct SamplingDecision: Decision {
    let isSampled: Bool
    var attributes: [String: AttributeValue] { [:] }
}
