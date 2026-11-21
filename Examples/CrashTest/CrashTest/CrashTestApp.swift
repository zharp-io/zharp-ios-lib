import SwiftUI
import Zharp

@main
struct CrashTestApp: App {
    init() {
        let environment = ProcessInfo.processInfo.environment
        Zharp.start { options in
            options.key = environment["ZHARP_KEY"] ?? "zpk_e2e"
            options.service = "ios-crash-e2e"
            options.endpoint = environment["ZHARP_ENDPOINT"]
            options.debug = true
        }
        // A request the collector fails (503), for header capture.
        // Not Zharp's own address (those requests are never traced): the same collector as localhost.
        if let base = environment["ZHARP_ENDPOINT"]?.replacingOccurrences(of: "127.0.0.1", with: "localhost"),
           let url = URL(string: base + "/api/orders") {
            var request = URLRequest(url: url)
            request.setValue("Bearer user-token", forHTTPHeaderField: "Authorization")
            request.setValue("ios", forHTTPHeaderField: "X-Client")
            URLSession.shared.dataTask(with: request) { _, _, _ in }.resume()
        }
        if environment["CRASH"] == "1" {
            // The bug, on its own: a cart line without a quantity.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                _ = Cart(lines: [Cart.Line(cents: 500, quantity: 2), Cart.Line(cents: 300, quantity: nil)]).total()
            }
        }
    }

    var body: some Scene {
        WindowGroup { Text("Cart") }
    }
}
