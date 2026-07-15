# Moa Pulse companion

Pulse is the iOS call client for `moa serve`. The product definition and phased
implementation plan live in [PULSE.md](PULSE.md).

## Current app boundary

The host app targets iOS 17 and uses the local `MoaOpsCore` and
`MoaOpsPresentation` Swift package products. Its sole root is
`PulseCallRootView` with `PulseCallAppModel`; the removed Ops dashboard and
Companion conversation views are not part of the app.

The retained Call Pulse path keeps these boundaries:

- Pairing claims a one-use Pulse payload and stores only the resulting device
  credential in the Keychain.
- The paired device requests a short-lived, one-socket OpenAI Realtime client
  credential from Moa. Pulse retains it only in memory and connects directly to
  the documented OpenAI Realtime endpoint; the Moa device credential is never
  sent to OpenAI.
- Audio uses PCM16 on iOS. Simulator and macOS retain the explicit text
  fallback rather than claiming microphone support.
- The app has no signing credentials, team identifiers, or persisted OpenAI
  API key.

## Package layout

- `MoaOpsCore` contains pairing/device authentication, the existing Call Pulse
  domain and transport, OpenAI Realtime integration, audio control, and the
  Realtime budget ledger.
- `MoaOpsPresentation` contains only the Call Pulse app model and SwiftUI
  views.
- `MoaCompanion/MoaCompanionApp.swift` hosts the Call Pulse root.

## Local validation

The Swift package is nested at `Packages/MoaOps`. On macOS, validate the
package and the unsigned simulator host app with:

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

GitHub Actions runs the same package build/test and unsigned simulator build
on macOS for pull requests and pushes to `main` and `feat/**`.
