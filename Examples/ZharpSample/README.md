# Zharp sample app

One SwiftUI file with a button for each kind of data: a log, a caught error, a traced request,
a manual span, a second screen, a hang, and two crashes.

1. In Xcode: **File → New → Project → iOS App**, named `ZharpSample`, interface SwiftUI.
2. **File → Add Package Dependencies → Add Local…** and pick this repository's root folder. Add
   the `Zharp` library to the app target.
3. Replace the generated `ZharpSampleApp.swift` (and delete `ContentView.swift`) with the one in
   this folder.
4. **Product → Scheme → Edit Scheme → Run → Arguments → Environment Variables**:
   - `ZHARP_KEY` — an app key (`zpk_…`) from **Applications → your app → Settings** in Zharp.
   - `ZHARP_ENDPOINT` — only for a local stack, e.g. `http://<your Mac's LAN IP>:3000/api/v1/otlp`
     (a device can't reach `localhost` on your Mac; the simulator can). Plain `http` also needs
     `NSAppTransportSecurity → NSAllowsArbitraryLoads` (or an exception for that host) in the
     app's Info.plist.
5. Run it. The console shows `[Zharp] Active: service "zharp-ios-sample"…` and, with `debug` on,
   what is sent.

Crashes: Xcode's debugger catches the crash first. To see one arrive, stop the app in Xcode,
start it from the home screen, tap a crash button, then open it again from the home screen (or
from Xcode) — the crash is sent on that launch. Hangs aren't reported while the debugger is
attached either; test them the same way.
