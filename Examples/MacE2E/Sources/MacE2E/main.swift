import AppKit
import Foundation
import Zharp

// MacE2E <mode>:
//   crash     — a Swift runtime trap a second after launch
//   error     — a handled error, then quit straight away (sent by the quit handler)
//   relaunch  — start, send the crash from the last run, quit after a few seconds

let mode = CommandLine.arguments.dropFirst().first ?? "relaunch"

Zharp.start { options in
    options.key = "zpk_e2e"
    options.service = "macos-e2e"
    options.environment = "ci"
    options.endpoint = ProcessInfo.processInfo.environment["ZHARP_ENDPOINT"]
    options.logs = true
    options.debug = true
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
    switch mode {
    case "crash":
        let empty = [Int]()
        print("crashing")
        _ = empty[CommandLine.arguments.count]   // index out of range: a trap the optimizer can't remove
    case "error":
        Zharp.captureError(NSError(domain: "MacE2E", code: 7, userInfo: [NSLocalizedDescriptionKey: "mac e2e handled error"]))
        Zharp.log.info("mac e2e quitting")
        app.terminate(nil)
    default:
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { app.terminate(nil) }
    }
}

app.run()
