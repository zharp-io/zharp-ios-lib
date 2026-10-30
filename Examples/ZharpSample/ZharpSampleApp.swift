import SwiftUI
import Zharp

// A small app with a button for each thing Zharp records. See Examples/ZharpSample/README.md.

@main
struct ZharpSampleApp: App {
    init() {
        let environment = ProcessInfo.processInfo.environment
        Zharp.start { options in
            // Set ZHARP_KEY (and ZHARP_ENDPOINT for a local stack) in the scheme's environment
            // variables, so no key is ever committed.
            options.key = environment["ZHARP_KEY"] ?? ""
            options.service = "zharp-ios-sample"
            options.environment = "development"
            options.endpoint = environment["ZHARP_ENDPOINT"]
            options.tracingOrigins = ["httpbin.org"]
            options.debug = true
        }
        Zharp.setUser(id: "sample-user", email: "sample@example.com")
    }

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                HomeView()
            }
        }
    }
}

private enum SampleError: Error {
    case somethingFailed(code: Int)
}

struct HomeView: View {
    @State private var status = "Ready"

    var body: some View {
        List {
            Section("Logs and errors") {
                Button("Log info") {
                    Zharp.log.info("Sample button tapped", ["button": "info"])
                    status = "Logged"
                }
                Button("Capture an error") {
                    Zharp.captureError(SampleError.somethingFailed(code: 42), ["screen": "home"])
                    status = "Error captured"
                }
            }
            Section("Traces") {
                Button("Request httpbin.org (traced, with traceparent)") {
                    Task {
                        let url = URL(string: "https://httpbin.org/headers")!
                        let code = (try? await URLSession.shared.data(from: url).1 as? HTTPURLResponse)?.statusCode
                        status = "httpbin answered " + (code.map { String($0) } ?? "nothing")
                    }
                }
                Button("Span around work") {
                    Zharp.startSpan("sample work", attributes: ["items": 3]) {
                        Thread.sleep(forTimeInterval: 0.2)
                    }
                    status = "Span recorded"
                }
                NavigationLink("Open another screen") {
                    DetailView()
                }
            }
            Section("Crashes and hangs (sent on the next launch)") {
                Button("Hang the main thread for 3 s") {
                    Thread.sleep(forTimeInterval: 3)
                }
                Button("Crash: force-unwrap nil", role: .destructive) {
                    let value: Int? = nil
                    print(value!)
                }
                Button("Crash: NSException", role: .destructive) {
                    NSException(name: .invalidArgumentException, reason: "Sample exception", userInfo: nil).raise()
                }
            }
            Section {
                Button("Flush now") {
                    Zharp.flush { DispatchQueue.main.async { status = "Flushed" } }
                }
                Text("Session \(Zharp.sessionId ?? "-")").font(.footnote).foregroundStyle(.secondary)
                Text(status).font(.footnote)
            }
        }
        .navigationTitle("Zharp sample")
        .zharpScreen("Home")
    }
}

struct DetailView: View {
    var body: some View {
        Text("Another screen")
            .navigationTitle("Detail")
            .zharpScreen("Detail")
    }
}
