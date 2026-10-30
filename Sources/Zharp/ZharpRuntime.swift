import Foundation
import OpenTelemetryApi
import OpenTelemetrySdk
import OpenTelemetryProtocolExporterHttp
import ZharpCore

/// Where the runtime keeps its files and which process-wide hooks it installs. Tests use a
/// temporary folder and no hooks.
struct RuntimeEnvironment {
    var directory: URL
    var defaults: UserDefaults
    /// Crash handlers, app lifecycle, screen tracking, network tracing, hang detection.
    var installsHooks: Bool
    /// Send the outbox. Off in tests, which read the outbox instead.
    var uploads: Bool

    static func live() -> RuntimeEnvironment? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        return RuntimeEnvironment(directory: caches.appendingPathComponent("io.zharp", isDirectory: true),
                                  defaults: .standard, installsHooks: true, uploads: true)
    }
}

/// The started SDK: OpenTelemetry tracer and logger providers whose exporters write to the
/// outbox, the context every span and log record carries, and the hooks that feed them.
final class ZharpRuntime: @unchecked Sendable {
    // MARK: Shared instance

    private static let sharedLock = NSLock()
    private static var _shared: ZharpRuntime?

    static var shared: ZharpRuntime? {
        sharedLock.lock()
        defer { sharedLock.unlock() }
        return _shared
    }

    static func start(options: ZharpOptions) {
        Diagnostics.verbose = options.debug
        guard let environment = RuntimeEnvironment.live() else {
            Diagnostics.warn("No caches folder, so Zharp can't start.")
            return
        }
        sharedLock.lock()
        guard _shared == nil else {
            sharedLock.unlock()
            Diagnostics.warn("Zharp.start was called more than once; the first call's settings stay.")
            return
        }
        guard let settings = Settings.resolve(options) else {
            sharedLock.unlock()
            return
        }
        let runtime = ZharpRuntime(settings: settings, environment: environment)
        _shared = runtime
        sharedLock.unlock()

        runtime.activate()
        var line = "Active: service \"" + settings.service + "\""
        if let name = settings.environment { line += ", environment \"" + name + "\"" }
        Diagnostics.info(line)
    }

    // MARK: State

    let settings: Settings
    let context: ContextState
    let outbox: Outbox
    let uploader: Uploader?
    let tracerProvider: TracerProviderSdk
    let logProcessor: BatchLogRecordProcessor
    let tracer: Tracer
    let logger: OpenTelemetryApi.Logger

    private let environment: RuntimeEnvironment
    private let runContext: RunContextStore
    let crashDirectory: URL
    private let workQueue = DispatchQueue(label: "io.zharp.work", qos: .utility)
    private var hangDetector: HangDetector?

    private let screenLock = NSLock()
    private var lastScreen: String?
    private var lastScreenAt: Date?

    private let flushLock = NSLock()
    private var errorFlushPending = false

    init(settings: Settings, environment: RuntimeEnvironment) {
        self.settings = settings
        self.environment = environment
        try? FileManager.default.createDirectory(at: environment.directory, withIntermediateDirectories: true)
        crashDirectory = environment.directory.appendingPathComponent("crashes", isDirectory: true)
        let runContext = RunContextStore(directory: environment.directory)
        self.runContext = runContext
        let context = ContextState(release: settings.release)
        self.context = context

        let outbox = Outbox(directory: environment.directory.appendingPathComponent("outbox", isDirectory: true))
        self.outbox = outbox
        let uploader = environment.uploads ? Uploader(outbox: outbox, endpoint: settings.endpoint, key: settings.key) : nil
        self.uploader = uploader
        outbox.onEnqueue = { [weak uploader] in uploader?.kick() }

        let resourceInfo = ResourceInfo(service: settings.service,
                                        release: settings.release,
                                        environment: settings.environment,
                                        deviceId: DeviceInfo.deviceId(in: environment.defaults),
                                        deviceModel: DeviceInfo.modelIdentifier(),
                                        osName: DeviceInfo.osName,
                                        osVersion: DeviceInfo.osVersion)
        let resource = Resource(attributes: OTelBridge.attributes(resourceInfo.attributes()))

        // Spans: context on start, batched (5 s or 100), exported as OTLP protobuf into the outbox.
        let spanExporter = OtlpHttpTraceExporter(endpoint: Endpoint.url(base: settings.endpoint, kind: .traces),
                                                 httpClient: OutboxHTTPClient(kind: .traces, outbox: outbox),
                                                 envVarHeaders: nil,
                                                 requeueOnFailure: false)
        let spanProcessor = BatchSpanProcessor(spanExporter: spanExporter,
                                               scheduleDelay: 5,
                                               exportTimeout: 10,
                                               maxQueueSize: 1000,
                                               maxExportBatchSize: 100)
        let tracerProvider = TracerProviderBuilder()
            .with(resource: resource)
            .with(sampler: ZharpSampler(rate: settings.sampleRate))
            .add(spanProcessor: ContextSpanProcessor(context: context))
            .add(spanProcessor: spanProcessor)
            .build()
        self.tracerProvider = tracerProvider

        // Logs: the same, through the log exporter.
        let logExporter = OtlpHttpLogExporter(endpoint: Endpoint.url(base: settings.endpoint, kind: .logs),
                                              httpClient: OutboxHTTPClient(kind: .logs, outbox: outbox),
                                              envVarHeaders: nil,
                                              requeueOnFailure: false)
        let logProcessor = BatchLogRecordProcessor(logRecordExporter: logExporter,
                                                   scheduleDelay: 5,
                                                   exportTimeout: 10,
                                                   maxQueueSize: 1000,
                                                   maxExportBatchSize: 100)
        self.logProcessor = logProcessor
        let loggerProvider = LoggerProviderBuilder()
            .with(resource: resource)
            .with(processors: [logProcessor])
            .build()

        // Registered globally too, so spans an app makes with the OpenTelemetry API go to Zharp.
        OpenTelemetry.registerTracerProvider(tracerProvider: tracerProvider)
        OpenTelemetry.registerLoggerProvider(loggerProvider: loggerProvider)
        let verbose = Diagnostics.verbose
        OpenTelemetry.registerFeedbackHandler { message in
            if verbose { NSLog("[Zharp] OpenTelemetry: %@", message) }
        }

        tracer = tracerProvider.get(instrumentationName: "io.zharp.ios",
                                    instrumentationVersion: ZharpVersion.current,
                                    schemaUrl: nil,
                                    attributes: nil)
        logger = loggerProvider.get(instrumentationScopeName: "io.zharp.ios")

        context.onChange = { snapshot in runContext.save(snapshot) }
    }

    /// Reports a crash from the previous run, then installs the hooks.
    func activate() {
        let previousRun = runContext.load()
        runContext.save(context.snapshot())

        if settings.captureCrashes {
            reportPendingCrash(previousRun: previousRun)
            if environment.installsHooks { CrashReporter.install(directory: crashDirectory) }
        }
        if environment.installsHooks {
            AppLifecycle.install(runtime: self)
            if settings.trackScreens { ScreenTracking.installUIKit() }
            if settings.traceNetwork { NetworkTracing.install(runtime: self) }
            if settings.detectHangs {
                let detector = HangDetector(threshold: settings.hangThreshold) { [weak self] threshold in
                    self?.reportHang(threshold: threshold)
                }
                hangDetector = detector
                detector.start()
            }
        }
        uploader?.kick()
    }

    // MARK: Logs and errors

    func log(_ level: LogLevel, _ message: String, attributes: [String: AttrValue],
             timestamp: Date? = nil, context previous: ContextSnapshot? = nil) {
        var all = attributes
        let snapshot = previous ?? context.snapshot()
        for (key, value) in snapshot.attributes() { all[key] = value }
        if let previous = previous, let release = previous.release, !release.isEmpty {
            all[Keys.serviceVersion] = .string(release)
        }
        var builder = logger.logRecordBuilder()
            .setSeverity(OTelBridge.severity(level))
            .setBody(AttributeValue.string(message))
            .setAttributes(OTelBridge.attributes(all))
        if let timestamp = timestamp {
            builder = builder.setTimestamp(timestamp)
        }
        builder.emit()
        if level.rawValue >= LogLevel.error.rawValue { flushErrorsSoon() }
    }

    func captureError(_ error: Error, attributes: [String: Any], callStack: [String]) {
        let description = ErrorFormatting.describe(error, callStack: callStack)
        record(description, handled: true, kind: nil, attributes: AttributeMapping.map(attributes))
        // Mark the span the error happened in, if any; the error itself goes as a log record,
        // which sampling never drops.
        if let span = OpenTelemetry.instance.contextProvider.activeSpan {
            span.status = .error(description: description.message)
        }
    }

    func record(_ error: ErrorDescription, handled: Bool, kind: String?, attributes: [String: AttrValue],
                level: LogLevel = .error, timestamp: Date? = nil, context previous: ContextSnapshot? = nil) {
        var all = attributes
        all[Keys.exceptionType] = .string(error.type)
        all[Keys.exceptionMessage] = .string(error.message)
        all[Keys.exceptionStacktrace] = .string(error.stacktrace)
        all[Keys.handled] = .string(handled ? "true" : "false")
        if let kind = kind { all[Keys.errorKind] = .string(kind) }
        log(level, ErrorFormatting.headline(type: error.type, message: error.message),
            attributes: all, timestamp: timestamp, context: previous)
    }

    private func reportPendingCrash(previousRun: ContextSnapshot?) {
        guard let crash = CrashReporter.pending(in: crashDirectory) else { return }
        Diagnostics.debug("Reporting a crash from the previous run: \(crash.error.type)")
        record(crash.error, handled: false, kind: "crash", attributes: [:], level: .fatal,
               timestamp: crash.time, context: previousRun)
        // Into the outbox before the report files go.
        workQueue.async { [weak self] in
            guard let self = self else { return }
            _ = self.logProcessor.forceFlush(explicitTimeout: 10)
            CrashReporter.remove(crash.files)
            self.uploader?.kick()
        }
    }

    private func reportHang(threshold: TimeInterval) {
        let screen = context.snapshot().screen
        let message = "The main thread was blocked for \(Int(threshold * 1000)) ms or more"
            + (screen.map { " on \($0)" } ?? "")
        let error = ErrorDescription(type: "AppHang", message: message,
                                     stacktrace: ErrorFormatting.headline(type: "AppHang", message: message))
        record(error, handled: true, kind: "hang",
               attributes: ["zharp.hang.threshold_ms": .int(Int(threshold * 1000))])
    }

    // MARK: Spans and screens

    func beginSpan(_ name: String, attributes: [String: Any]) -> Span {
        let builder = tracer.spanBuilder(spanName: name)
        for (key, value) in AttributeMapping.map(attributes) {
            builder.setAttribute(key: key, value: OTelBridge.value(value))
        }
        return builder.startSpan()
    }

    func markFailed(_ span: Span, error: Error) {
        let description = ErrorFormatting.describe(error, callStack: [])
        span.setAttribute(key: "error.type", value: AttributeValue.string(description.type))
        span.status = .error(description: description.message)
    }

    /// A screen view: the current screen for everything that follows, and a root span named
    /// "screen <name>" (from `start` — UIKit's viewWillAppear — to now).
    func screenDidAppear(_ name: String, start: Date? = nil) {
        let now = Date()
        screenLock.lock()
        let repeated = ScreenNaming.isRepeat(previous: lastScreen, previousAt: lastScreenAt, name: name, now: now)
        lastScreen = name
        lastScreenAt = now
        screenLock.unlock()
        guard !repeated else { return }

        context.setScreen(name)
        let span = tracer.spanBuilder(spanName: ScreenNaming.spanName(name))
            .setNoParent()
            .setSpanKind(spanKind: .internal)
            .setStartTime(time: start ?? now)
            .setAttribute(key: Keys.screenName, value: AttributeValue.string(name))
            .startSpan()
        span.end(time: now)
    }

    // MARK: Network

    /// `traceparent` and `baggage` for a request to one of the `tracingOrigins`.
    func injectTraceHeaders(into request: inout URLRequest, span: Span?) {
        guard let span = span else { return }
        let spanContext = span.context
        if let traceparent = TracePropagation.traceparent(traceId: spanContext.traceId.hexString,
                                                          spanId: spanContext.spanId.hexString,
                                                          sampled: spanContext.traceFlags.sampled) {
            request.setValue(traceparent, forHTTPHeaderField: TracePropagation.traceparentHeader)
        }
        let snapshot = context.snapshot()
        let baggage = TracePropagation.baggage([(key: Keys.userId, value: snapshot.user?.id),
                                                (key: Keys.sessionId, value: snapshot.sessionId)],
                                               existing: request.value(forHTTPHeaderField: TracePropagation.baggageHeader))
        if let baggage = baggage {
            request.setValue(baggage, forHTTPHeaderField: TracePropagation.baggageHeader)
        }
    }

    // MARK: Lifecycle and delivery

    func didEnterBackground() {
        context.didEnterBackground()
        hangDetector?.setPaused(true)
    }

    func willEnterForeground() {
        context.willEnterForeground()
        hangDetector?.setPaused(false)
        uploader?.kick()
    }

    /// Exports everything batched so far into the outbox, then sends the outbox.
    func flush(timeout: TimeInterval = 10, completion: (() -> Void)? = nil) {
        workQueue.async { [weak self] in
            guard let self = self else { completion?(); return }
            self.tracerProvider.forceFlush(timeout: timeout)
            _ = self.logProcessor.forceFlush(explicitTimeout: timeout)
            if let uploader = self.uploader {
                uploader.kick(completion: completion)
            } else {
                completion?()
            }
        }
    }

    /// Errors go out within a second instead of waiting for the next batch.
    private func flushErrorsSoon() {
        flushLock.lock()
        let alreadyPending = errorFlushPending
        errorFlushPending = true
        flushLock.unlock()
        guard !alreadyPending else { return }
        workQueue.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self = self else { return }
            self.flushLock.lock()
            self.errorFlushPending = false
            self.flushLock.unlock()
            _ = self.logProcessor.forceFlush(explicitTimeout: 10)
        }
    }
}
