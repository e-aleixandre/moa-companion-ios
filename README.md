# Moa Ops companion packages

## Pulse direct Realtime boundary

Pulse stores an owner-supplied OpenAI API key only in the device Keychain
(`pulse.openai.api-key.v1`). It opens the documented `wss://api.openai.com/v1/realtime`
connection directly from the companion with `Authorization: Bearer …`; Moa never receives,
stores, relays, or logs that key. The Realtime adapter accepts only fixed typed Moa tools and
the bounded safe Ops brief, never raw conversation context or a generic HTTP tool. It uses the
documented PCM16 Realtime session format on iOS; macOS and Simulator retain the explicit text
fallback rather than claiming microphone support. Pulse remains PTT-only, keeps one turn/review
reservation, and requires the existing visible immutable Moa review before confirmation.

This repository provides package libraries plus a minimal iOS 17 host app for the Moa companion, targeting iOS 17 and macOS 13 with Swift 5.10. `MoaCompanion.xcodeproj` uses the local `MoaOpsCore` and `MoaOpsPresentation` package products and launches `MoaOpsRootView`. The app uses automatic signing, so developers select their own Team in Xcode before running on a physical device. The project contains no signing credentials, team identifiers, audio implementation, CarPlay dependency, or deployment configuration.

## CI

GitHub Actions validates the package on GitHub-hosted macOS 14 for pull requests and pushes to `main` and `feat/**`, running `swift build --package-path Packages/MoaOps`, `swift test --package-path Packages/MoaOps`, and an unsigned Debug build of `MoaCompanion` for the generic iOS Simulator destination. It does not use signing, secrets, or deployment steps.

## Local validation

The Swift package is intentionally nested at `Packages/MoaOps`, separate from the Xcode project root. Validate the package and unsigned simulator host app with:

```sh
swift build --package-path Packages/MoaOps
swift test --package-path Packages/MoaOps
xcodebuild \
  -project MoaCompanion.xcodeproj \
  -scheme MoaCompanion \
  -configuration Debug \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

## Libraries

### MoaOpsCore

- Codable models for the server's safe Ops snapshot, sitrep/blocker/status briefings, directed-instruction request, success, and disambiguation response JSON.
- `MoaOpsClient`, an actor-backed `URLSession` REST client for the primary `GET /api/ops/pulse[?cursor=opaque-token]` inbox, legacy verified Ops queries, and `POST /api/ops/instruction`.
- Per-request `X-Request-ID` values, plus the same ID in an instruction's `request_id` JSON field. Callers can supply an ID to safely retry an instruction.
- `MoaOpsWebSocketClient`, a read-only `URLSessionWebSocketTask` abstraction for `/api/ops/ws`. `init` and increasing-version `snapshot` envelopes replace local state atomically; it sends no application messages and reconnects under the supplied bounded policy.

### MoaOpsPresentation

`MoaOpsPresentation` is a SwiftUI presentation library above `MoaOpsCore`, suitable for embedding in a future iOS or macOS app. It provides:

- `MoaOpsAppModel`, a `@MainActor` observable model with explicit Pulse loading, connection testing, and safe error states.
- A Spanish-first Pulse inbox: attention first, then retained changes, with active work as a secondary section. It persists only the server-issued opaque non-secret `next_cursor` after rendering a page; it never derives a cursor from `generated_at`. A `410 Gone` reset is retried once without a cursor and is shown as unavailable history.
- Server URL validation and a test-connection action. Configuration is only held in the model; the library persists neither URLs nor credentials.
- Card detail sheets with bounded facts and observed/derived provenance; no raw transcripts, logs, or server error bodies are rendered.
- A directed-instruction composer opened only from a current Pulse card with a server-supplied `target_id`. It confirms the exact resolved title and has no free-form or fuzzy target field.
- `MoaOpsLiveService`, which adapts the REST and read-only WebSocket facilities in `MoaOpsCore`, plus `MoaOpsPresentationService` for deterministic host integration and tests.

The presentation layer intentionally maps failures to short user-facing messages. It does not render raw server error bodies, logs, or thrown-error descriptions.

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
let pulse = try await client.pulse()
```

The server remains authoritative: the client only renders safe snapshots and requests directed instructions. It does not execute agents or make local production decisions.

## Embedding the presentation library

```swift
import MoaOpsPresentation
import SwiftUI

@StateObject private var ops = MoaOpsAppModel()

var body: some View {
    MoaOpsRootView(model: ops)
}
```

Hosts that need token-to-cookie authentication create their own `MoaOpsPresentationService` using a shared cookie-configured `URLSession` and `MoaOpsLiveService(baseURL:session:authentication:)`. Tokens remain host-supplied in memory; this package has no Keychain or other secret persistence.
