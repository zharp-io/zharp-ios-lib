# Changelog

## 0.5.0 — 2026-11-24

- Apps with C and C++ code: an uncaught C++ exception is reported by its type and `what()`, its stack starting where it was thrown (a `std::terminate` handler in the new `ZharpCxx` target, which `Zharp` links). C and C++ crashes are symbolicated with the uploaded dSYM (`zharp dsym upload`); checked end to end in an iOS app in the simulator on CI.

## 0.4.1 — 2026-11-22

- macOS apps: sessions end when the app stops being the active app, and what is waiting is sent when it quits (AppKit lifecycle). Checked end to end in a real AppKit app on CI (crash sent on relaunch, error and logs sent on quit).

## 0.4.0 — 2026-11-21

- Request and response headers on URLSession spans (`captureHeaders`, `redactHeaders`); secrets are sent as `[Filtered]`.
- `ignoreCrashTypes`: skip crashes another layer already reported (React Native uses it).
- swift-log is kept below 1.17, which Xcode 26.0–26.2 can't build.

## 0.3.0 — 2026-11-17

- `options.logs` (default **off**): the switch for sending the app's own logs. Off, nothing it
  logs or prints is sent — stdout and stderr are untouched, the unified log isn't read and
  `ZharpLogHandler` forwards nothing; crashes, errors, hangs, traces, sessions, screens and
  `Zharp.log` calls are sent either way. `ZHARP_LOGS=true` also turns it on. The options below
  only apply with it on.
- `options.captureOutput` (default on, with `logs`): everything the app prints — `print`, `NSLog`, `printf`,
  logging libraries writing to stdout or stderr — is sent as logs, with the level read from the
  line (JSON `level`, `ERROR`, `[warn]`…; else info, warning on stderr; `NSLog` info). The app's
  output is unchanged; a line `Zharp.log` already sent isn't sent twice. Not while a debugger is
  attached. `ZHARP_CAPTURE_OUTPUT=false` also turns it off.
- `ZharpLogging`: `ZharpLogHandler` for swift-log, keeping the span, label and metadata (with `logs` on).
- `options.captureOSLog` (default off, needs `logs`): the app's own `os_log`/`Logger` entries, read back from
  the unified log every 30 seconds and when the app goes to the background.

- Docs: the README no longer describes a custom endpoint; the SDK sends straight to Zharp.

## 0.2.0

- `options.captureBodies` (`.errors`, `.all` or `CaptureBodies(…)`): request and response bodies
  on URLSession spans, off by default. Field names kept, secret values `[Filtered]` on the device,
  files in uploads and binary bodies described (`[file photo.png · image/png · 240 KB]`), text
  capped at 32 KB (`maxSize` up to 128 KB). The same rules as Zharp's other SDKs.
- Secret-looking query values in `url.full` (`token`, `key`, `sig`, …) are recorded as `[Filtered]`.

## 0.1.0

- First release: `Zharp` for iOS 15 and up, on OpenTelemetry Swift 2.6.0.
- Crashes (uncaught exceptions and fatal signals) saved on the device and sent on the next
  launch with the crashed thread's stack and binary images; hangs of 2 s or more.
- Readable stacks: crashes and caught errors list the binary images their frames run through
  ("Binary Images:" with load address, UUID and arch) and send them as `zharp.binary_images`
  JSON, so Zharp symbolicates them with the dSYMs uploaded by `zharp dsym upload` (README:
  Xcode Run Script phase, or a curl fallback).
- `captureError`, `Zharp.log.*`, `startSpan`, `setUser`/`clearUser`, `setTag`, `flush`.
- Sessions (new after 30 minutes in the background or on `clearUser`), device context, an
  install-scoped device ID.
- UIKit screen views automatically, SwiftUI with `.zharpScreen("Name")`.
- `options.tracing = false` for logs only: no spans and no trace headers; logs, errors and
  context still sent.
- URLSession spans; `traceparent` and `baggage` only to `tracingOrigins`.
- Batching, an on-device outbox (5 MB cap) that survives offline and restarts, retries with
  backoff, and a one-hour pause with one warning when the key is rejected.
