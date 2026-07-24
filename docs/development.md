# Development

## Build from source

Current toolchain:

- Xcode 26.5 or newer
- Swift 6
- macOS 26 deployment target
- iOS 18 deployment target

Build the macOS app without code signing:

```sh
make build
```

Equivalent command:

```sh
xcodebuild -project Nook.xcodeproj -scheme Nook \
  -destination 'platform=macOS' \
  -derivedDataPath DerivedData \
  CODE_SIGNING_ALLOWED=NO build
```

Build for the iOS simulator:

```sh
xcodebuild -project Nook.xcodeproj -scheme NookiOS \
  -destination 'generic/platform=iOS Simulator' build
```

For a physical iPhone or iPad, open `Nook.xcodeproj`, select the NookiOS scheme, choose a signing team and device, then press **⌘R**.

## Architecture

- **Shared core:** `NookKit`, a local Swift package containing the store, models, RSS/Atom and OPML parsing, storage, sync, translation, and native reader components.
- **macOS UI:** SwiftUI with AppKit bridges where native behavior is more reliable.
- **iOS/iPadOS UI:** SwiftUI, WidgetKit, and a share extension.
- **Networking:** `URLSession`.
- **Feed parsing:** `XMLParser`.
- **Native reader:** semantic SwiftUI rendering for parsed HTML and Markdown.
- **Full-page reader:** a deliberate opt-in `WKWebView` with a self-contained readability script.
- **Translation:** Foundation Models and NaturalLanguage on-device; optional Gemini through a direct network client.
- **Persistence:** per-device JSON CRDT shards in the chosen folder plus a disposable local SQLite replica/outbox.
- **Coordinated file access:** `NSFileCoordinator` and `NSFilePresenter`.
- **macOS updates:** Sparkle with an EdDSA-signed appcast.

There are no third-party UI frameworks and no Electron shell.

## Verification

```sh
make build
plutil -lint Nook.xcodeproj/project.pbxproj Nook/Nook.entitlements
git diff --check
```

## Releasing

Pushing a version tag runs `.github/workflows/release.yml`:

```sh
git tag v0.1.8
git push origin v0.1.8
```

The macOS runner archives a universal ad-hoc build, packages a DMG, publishes a GitHub Release, signs the update, and updates the Sparkle appcast on the `gh-pages` branch.
