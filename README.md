# MoaOpsCore

`MoaOpsCore` is the small iOS 17 / Swift 5.9 package boundary for a future Moa companion app. It has no app target, audio implementation, or CarPlay dependency.

## CI

GitHub Actions validates the package on GitHub-hosted macOS 14 for pull requests and pushes to `main` and `feat/**`, running `swift build` and `swift test`. It does not use signing, secrets, or deployment steps.

## What it contains

- Codable models for the server's safe Ops snapshot, sitrep/blocker/status briefings, directed-instruction request, success, and disambiguation response JSON.
- `MoaOpsClient`, an actor-backed `URLSession` REST client for `GET /api/ops/overview`, the sitrep/blockers/status Ops queries, and `POST /api/ops/instruction`.
- Per-request `X-Request-ID` values, plus the same ID in an instruction's `request_id` JSON field. Callers can supply an ID to safely retry an instruction.
- `MoaOpsWebSocketClient`, a read-only `URLSessionWebSocketTask` abstraction for `/api/ops/ws`. `init` and increasing-version `snapshot` envelopes replace local state atomically; it sends no application messages and reconnects under the supplied bounded policy.

## Authentication boundary

The package accepts an optional `MoaOpsAuthenticationBootstrap`. The provided `CookieTokenBootstrap` performs the conventional Moa token-to-cookie bootstrap using the `URLSession` cookie jar; a host app supplies its token in memory. There is deliberately no secret persistence, Keychain code, hard-coded token, or logging of tokens/instruction text in this package. Apps may instead provide their own bootstrap implementation for an existing cookie session or future auth flow.

Use one cookie-configured `URLSession` for the bootstrap, REST client, and WebSocket client so the server-issued cookie is shared.

## Integration shape

```swift
let configuration = URLSessionConfiguration.default
configuration.httpCookieStorage = HTTPCookieStorage.shared
let session = URLSession(configuration: configuration)
let auth = CookieTokenBootstrap(token: suppliedAtRuntime)
let client = try MoaOpsClient(baseURL: serverURL, session: session, authentication: auth)
let snapshot = try await client.overview()
```

The server remains authoritative: the client only renders safe snapshots and requests directed instructions. It does not execute agents or make local production decisions.
