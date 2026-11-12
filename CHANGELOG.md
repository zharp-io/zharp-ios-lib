# Changelog

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
