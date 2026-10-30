# Changelog

## 0.1.0 (unreleased)

- First release: `Zharp` for iOS 15 and up, on OpenTelemetry Swift 2.6.0.
- Crashes (uncaught exceptions and fatal signals) saved on the device and sent on the next
  launch with the crashed thread's stack and binary images; hangs of 2 s or more.
- `captureError`, `Zharp.log.*`, `startSpan`, `setUser`/`clearUser`, `setTag`, `flush`.
- Sessions (new after 30 minutes in the background or on `clearUser`), device context, an
  install-scoped device ID.
- UIKit screen views automatically, SwiftUI with `.zharpScreen("Name")`.
- URLSession spans; `traceparent` and `baggage` only to `tracingOrigins`.
- Batching, an on-device outbox (5 MB cap) that survives offline and restarts, retries with
  backoff, and a one-hour pause with one warning when the key is rejected.
