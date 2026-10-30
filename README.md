# Zharp for iOS

Application Monitoring for iOS apps: crashes, errors, hangs, screens, network requests and logs,
sent to [Zharp](https://zharp.io) and tied together by session and user. Swift and SwiftUI,
iOS 15 and up, Swift Package Manager. Built on [OpenTelemetry Swift](https://github.com/open-telemetry/opentelemetry-swift).

---

## 1. Install

In Xcode: **File → Add Package Dependencies**, paste

```
https://github.com/zharp-io/zharp-ios
```

and add the **Zharp** library to your app target. Or in `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/zharp-io/zharp-ios", from: "0.1.0"),
],
targets: [
    .target(name: "MyApp", dependencies: [.product(name: "Zharp", package: "zharp-ios")]),
]
```

Xcode 16 or later (OpenTelemetry Swift needs the Swift 6 tools).

## 2. Get your app key

In Zharp, open **Applications**, add your iOS app (or open it), and copy its key — `zpk_…`. An
app key can only send data, so it's safe to ship inside the app.

## 3. Start it

As early as possible, so crashes and the first screens are caught.

**SwiftUI:**

```swift
import SwiftUI
import Zharp

@main
struct ShopApp: App {
    init() {
        Zharp.start { options in
            options.key = "zpk_…"
            options.service = "shop-ios"
            options.environment = "production"
        }
    }

    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
```

**UIKit:**

```swift
import Zharp

func application(_ application: UIApplication,
                 didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
    Zharp.start { options in
        options.key = "zpk_…"
        options.service = "shop-ios"
        options.environment = "production"
    }
    return true
}
```

When it starts it writes one line to the console:

```
[Zharp] Active: service "shop-ios", environment "production"
```

Without a key it says so and sends nothing. Every other call does nothing until `start`, so you
can leave them in place in builds where Zharp is off.

## 4. Say who the user is

Once someone signs in:

```swift
Zharp.setUser(id: user.id, email: user.email)   // name: is optional too
```

Everything from then on carries them, and the Users tab in Zharp shows their sessions. On sign
out, `Zharp.clearUser()` — it also starts a new session.

That's all most apps need. The rest of this page is what happens automatically, and the extras.

---

## Crashes

On by default. Uncaught Objective-C exceptions and fatal signals are captured — Swift runtime
errors (force-unwrapping `nil`, an index out of range, `fatalError()`) arrive as
`EXC_BREAKPOINT`, bad memory access as `EXC_BAD_ACCESS`.

iOS gives a crashing app no time to send anything, so the crash is written to the device as it
happens and **sent the next time the app starts**, with the time it actually happened and the
session, user, screen and release it happened in. The app still crashes exactly as it would
have, and a crash reporter installed before Zharp still sees it.

Each crash carries the crashed thread's stack in Apple's crash-report shape, plus the binary
images (load address and UUID) its frames are in:

```
EXC_BAD_ACCESS: SIGSEGV, the app touched memory it may not use
0   MyApp                            0x0000000100a3c1f4 0x100a30000 + 49652
1   MyApp                            0x0000000100a3b0c8 0x100a30000 + 45256
2   UIKitCore                        0x00000001a8f1d2c4 0x1a8e00000 + 1167044
…

Binary Images:
0x100a30000 6F1D…A1B2 arm64 /private/var/containers/Bundle/Application/…/MyApp.app/MyApp
```

The same images go along as `zharp.binary_images` (`[{name, uuid, loadAddress, arch}]`), on
crashes and on errors you catch.

### Readable stack traces: upload your dSYMs

Release builds are stripped, so your own frames are addresses. Upload each build's dSYMs and
Zharp shows (and groups) those crashes and errors by your functions, files and lines, matching
each image to its dSYM by UUID.

Make sure the build writes dSYMs (Build Settings → Debug Information Format → **DWARF with dSYM
File** for Release), then add a **Run Script** build phase after the others:

```bash
# Upload this build's dSYMs to Zharp (release builds only).
if [ "$CONFIGURATION" = "Release" ] && [ -n "$ZHARP_AUTH_TOKEN" ]; then
  export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"   # Xcode doesn't load your shell's PATH
  npx --yes @zharp/cli dsym upload "$DWARF_DSYM_FOLDER_PATH" --app <application id> || \
    echo "warning: Zharp dSYM upload failed; crashes from this build stay unsymbolicated until it's uploaded"
fi
```

In the phase, add `$(DWARF_DSYM_FOLDER_PATH)/$(DWARF_DSYM_FILE_NAME)` under **Input Files** (so
Xcode runs it after the dSYM is written) and, with User Script Sandboxing on, allow the folder to be
read. `ZHARP_AUTH_TOKEN` is a workspace API key with the `artifacts:write` scope — a secret: set it
in CI (or your shell, for archives from Xcode via `launchctl setenv`), never in the project.
`ZHARP_URL` points at a self-hosted Zharp.

**No Node on the build machine?** The CLI zips and posts each dSYM; the same with curl:

```bash
if [ "$CONFIGURATION" = "Release" ] && [ -n "$ZHARP_AUTH_TOKEN" ]; then
  APP_ID=<application id>
  URL="${ZHARP_URL:-https://api.zharp.io}/api/v1/applications/$APP_ID/artifacts"
  find "$DWARF_DSYM_FOLDER_PATH" -maxdepth 1 -name '*.dSYM' | while read -r dsym; do
    for dwarf in "$dsym"/Contents/Resources/DWARF/*; do
      # One upload per architecture slice, keyed by its Mach-O UUID.
      xcrun dwarfdump --uuid "$dwarf" | while read -r _ uuid arch _; do
        arch="${arch#(}"; arch="${arch%)}"
        curl --fail --silent --show-error -H "Authorization: Bearer $ZHARP_AUTH_TOKEN" \
          -F kind=dsym -F "debugId=$uuid" -F "arch=$arch" -F "name=$(basename "$dwarf")" \
          -F "file=@$dwarf" "$URL" || echo "warning: Zharp dSYM upload failed for $uuid"
      done
    done
  done
fi
```

For an archive built elsewhere (its dSYMs: Organizer → Archives → Show dSYMs), run `npx @zharp/cli dsym upload <path to .dSYM or folder> --app <id>`.
By hand, one address at a time, `atos` does the same:

```bash
atos -arch arm64 -o MyApp.app.dSYM/Contents/Resources/DWARF/MyApp -l 0x100a30000 0x0000000100a3c1f4
```

Uncaught Objective-C exceptions come with their name, reason and symbolicated call stack.

Turn it off with `options.captureCrashes = false`. While Xcode's debugger is attached it catches
crashes before Zharp does; to try it, launch the app from the home screen.

## Errors you catch

```swift
do {
    try checkout(cart)
} catch {
    Zharp.captureError(error, ["orderId": order.id])
}
```

It's reported as a handled error with its type (`MyApp.CheckoutError`), message and the stack of
the place you reported it from — Swift errors carry no stack of their own. Errors are sent
within a second, and never sampled out.

## Hangs

When the main thread is blocked for 2 seconds or more, Zharp reports an `AppHang` with the
screen it happened on. Not while the app is in the background or a debugger is attached.
`options.detectHangs = false` turns it off; `options.hangThreshold = 4` changes the limit.

## Screens

**UIKit** screens are recorded on their own: each time one of your view controllers appears, a
`screen CheckoutViewController` span is recorded (from `viewWillAppear` to `viewDidAppear`) and it
becomes the current screen on everything that follows. Navigation, tab bar, split and page
controllers are skipped, and so are system ones (alerts, keyboards).
`options.trackScreens = false` turns it off.

**SwiftUI** views aren't view controllers — they all live inside one hosting controller — so name
them:

```swift
CheckoutView()
    .zharpScreen("Checkout")
```

Or from anywhere: `Zharp.trackScreen("Checkout")`.

## Network requests and tracing into your back end

Every `URLSession` request becomes a span with its method, URL, status code and duration
(`options.traceNetwork = false` turns that off). Requests to Zharp itself aren't recorded.

To follow a request from the app into your back end — one trace across both in Zharp — list your
API's hosts:

```swift
options.tracingOrigins = ["api.shop.com", "*.shop-internal.com"]
```

Requests to those hosts get a W3C `traceparent` header and a `baggage` header with the user and
session (`enduser.id`, `session.id`), which Zharp's server SDKs pick up. No other host gets
them. An entry can be a host, `*.domain` for its subdomains, `host:port`, or a full origin such
as `https://api.shop.com:8443`.

## Logs

```swift
Zharp.log.info("Checkout started", ["items": cart.count])
Zharp.log.warn("Slow response", ["ms": 3200])
Zharp.log.error("Payment failed", ["orderId": order.id])
Zharp.log.debug("Cache miss")
```

Each log carries the session, the user, the current screen and the active span, so it shows up
in the trace and the session it belongs to. `print` and `os_log` aren't sent.

## Logs only

```swift
Zharp.start { options in
    options.key = "zpk_…"
    options.tracing = false
}
```

Logs, errors, crashes, hangs, the user, session, screen and tags are still sent; no spans are
made or sent (no screen or URLSession spans, `startSpan` just runs its closure, OpenTelemetry's
global tracer stays a no-op) and no request gets `traceparent` or `baggage`, whatever
`tracingOrigins` says.

## Your own spans

```swift
let receipt = try Zharp.startSpan("checkout", attributes: ["items": 3]) {
    try checkout(cart)
}

// async
let order = try await Zharp.startSpan("place order") {
    try await api.placeOrder(cart)
}
```

Spans and requests started inside it become its children (OpenTelemetry Swift tracks the active
span per thread and, best-effort, across `await`), and a thrown error marks it failed and is
rethrown.
Spans you start with the OpenTelemetry API directly go to Zharp too.

## Tags

```swift
Zharp.setTag("plan", "pro")   // on everything recorded from now on; nil removes it
```

## Sessions

A session starts when the app launches and lasts while it's used. After 30 minutes in the
background, or after `clearUser()`, a new one starts. `Zharp.sessionId` is the current one.

## Sending

Spans and logs are batched (every 5 seconds or 100 records) and written to the device first, so
nothing is lost offline or when the app is closed: what wasn't sent goes the next time it can.
That store is capped at 5 MB, oldest dropped first. Errors are sent within a second, and
everything waiting is sent when the app goes to the background. Failed sends are retried with
backoff, respecting the server's `Retry-After`.

If Zharp rejects the key (deleted, revoked or mistyped), the console says so once and sending
stops for an hour — nothing piles up meanwhile, and the app is unaffected.

`Zharp.flush()` sends everything now.

## Options

| `options.` | Default | |
|---|---|---|
| `key` | — | Required. The app key, `zpk_…`. |
| `service` | bundle identifier | The service name the data is filed under. |
| `environment` | none | `production`, `staging`… |
| `release` | `"2.3.0 (412)"` from the bundle | The app version. |
| `endpoint` | `https://api.zharp.io/api/v1/otlp` | Where to send. |
| `tracingOrigins` | `[]` | Hosts that get `traceparent` and `baggage`. |
| `tracing` | `true` | `false` = logs only (no spans, no trace headers). |
| `sampleRate` | `1.0` | The share of traces kept. Errors, crashes and logs are always sent. |
| `captureCrashes` | `true` | |
| `detectHangs` / `hangThreshold` | `true` / `2` s | |
| `trackScreens` | `true` | UIKit view controllers. |
| `traceNetwork` | `true` | URLSession spans. |
| `flushOnBackground` | `true` | |
| `debug` | `false` | Print what the SDK does to the console. |

## What's sent automatically

On everything: the service, release and environment; the device model (e.g. `iPhone15,2`), the
iOS version, and an install ID — a random ID Zharp creates and keeps in `UserDefaults`. It isn't
the advertising identifier (IDFA) or the vendor identifier (IDFV), needs no tracking permission,
and goes away when the app is deleted. Then the session, the user you set, the current screen
and your tags.

Network spans include the full request URL, query string included — keep secrets out of URLs.

## How it works

Zharp is a thin layer on the official OpenTelemetry Swift SDK: an OpenTelemetry tracer provider
and logger provider with Zharp's resource, sampler and context, OpenTelemetry's OTLP/HTTP
exporters, and its URLSession instrumentation. The exporters encode OTLP protobuf as usual but
hand each batch to Zharp's store on the device instead of posting it; Zharp sends from there,
which is what gives it the offline buffer, the retries and the key pause. The providers are
registered globally, so code already using the OpenTelemetry API sends to Zharp as well.

Dependencies: `opentelemetry-swift-core` and `opentelemetry-swift` 2.6.0 (Apache-2.0), with
SwiftProtobuf and swift-log. Xcode also fetches OpenTelemetry Swift's other dependencies, but
only the parts Zharp uses are built.

## Development

```bash
swift build
swift test
```

`ZharpCore` holds the plain-Swift logic — attribute mapping, sessions, propagation headers,
sampling, retry and outbox rules, crash report formatting — with no dependencies;
`Tests/ZharpCoreTests` covers it. `Tests/ZharpTests` runs the SDK end to end through
OpenTelemetry into the outbox and checks the uploader against a stubbed server. Both run on
macOS.

`Examples/ZharpSample` is a SwiftUI app with a button for each kind of data; its README says how
to run it.

## Releasing (maintainers)

Swift packages are released by git tag:

1. Update `ZharpVersion.current` in `Sources/ZharpCore/Basics.swift` and `CHANGELOG.md`.
2. `git tag -a 0.1.0 -m "0.1.0" && git push origin 0.1.0` on `github.com/zharp-io/zharp-ios`.

## License

MIT © [Zharp](https://zharp.io)
