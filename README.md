# Nook

A native macOS RSS reader built with SwiftUI, Swift 6, and Xcode.

## Download & Install

1. Download the latest `Nook-x.y.z.dmg` from the [Releases](https://github.com/selenehyun/nook/releases) page.
2. Open the DMG and drag **Nook** into your **Applications** folder.

Because this build is ad-hoc signed but not notarized by Apple, macOS
Gatekeeper blocks it on first launch. Clear the quarantine flag once and it
will open normally from then on:

```sh
xattr -dr com.apple.quarantine /Applications/Nook.app
```

Alternatively, double-click Nook, dismiss the warning, then go to
**System Settings → Privacy & Security** and click **Open Anyway**.

Requires macOS 26 or later. The build is a universal binary (Apple Silicon
and Intel).

> **Note on signing:** A one-time bypass is required only because the app is
> not notarized. See [Notarization](#notarization) for how to remove this step
> entirely with an Apple Developer account.

## Overview

- App framework: SwiftUI
- Language mode: Swift 6
- Toolchain verified here: Xcode 26.5, Swift 6.3.2
- Deployment target: macOS 26.0
- Security baseline: App Sandbox with user-selected file access
- UI: three-column reader with sidebar feeds, article list, reader pane,
  inspector, native settings, toolbar actions, search, share sheet, context
  menus, and menu commands
- Feed loading: real RSS/Atom fetching via `URLSession` and `XMLParser`
- Feed discovery: plain website URLs are scanned for RSS/Atom
  `<link rel="alternate">` tags
- Storage: a user-selected sync folder holding `NookLibrary.json`, intended to
  live in iCloud Drive
- Subscriptions: OPML import/export

## Project Layout

- `Nook.xcodeproj` — the Xcode project (targets, build settings, schemes).
- Scheme `Nook` — the run/build configuration for the app.
- Target `Nook` — the macOS app bundle; the product is `Nook.app`.
- `Nook/NookApp.swift` — the app entry point.
- `Nook/ContentView.swift` — the main reader UI.
- `Nook/ReaderStore.swift` — feed/article state and persistence.
- `Nook/RSSFeedService.swift` — RSS/Atom fetching and parsing.
- `Nook/ReaderStorage.swift` — security-scoped bookmark and library storage.
- `Nook/Assets.xcassets` — colors, icons, and image resources.
- `Nook/Nook.entitlements` — macOS permissions and sandbox settings.

## Build & Run

Run from Xcode:

1. Open `Nook.xcodeproj`.
2. Make sure the scheme is `Nook` and the run destination is `My Mac`.
3. Press `Command-R`.

Build from the terminal (code signing disabled, for a fast compile check):

```sh
make build
```

Open the project in Xcode:

```sh
make open
```

## Build & Install From Source

If you'd rather build the app yourself instead of downloading the DMG, you
can compile a Release build and copy it into `/Applications`. An app you build
locally is **not** quarantined, so it launches without any Gatekeeper prompt.

Using the command line:

```sh
git clone https://github.com/selenehyun/nook.git
cd nook

# Build a Release version (ad-hoc signed via the project's default settings)
xcodebuild -project Nook.xcodeproj -scheme Nook -configuration Release \
  -derivedDataPath build build

# Copy the app into Applications
cp -R build/Build/Products/Release/Nook.app /Applications/
```

Or from Xcode:

1. Open `Nook.xcodeproj`.
2. Choose **Product → Archive**.
3. In the Organizer, click **Distribute App → Custom → Copy App**, then save
   `Nook.app` and drag it into `/Applications`.

## RSS & iCloud Folder Storage

1. Launch the app.
2. Use the folder button in the toolbar to pick a folder inside iCloud Drive.
3. Nook creates `NookLibrary.json` there and stores feeds, articles, read
   state, and starred state.
4. Use the `+` button to add an RSS/Atom feed URL, or a website URL that links
   to a feed.
5. Import or export OPML from the Subscriptions menu.
6. Adjust automatic refresh and the refresh interval in Settings.

To support older macOS versions, lower `MACOSX_DEPLOYMENT_TARGET` in
`Nook.xcodeproj`. It is currently `26.0` to match the local development
environment.

## Releasing (maintainers)

Building the DMG and publishing a GitHub Release is automated by
`.github/workflows/release.yml`, triggered when a version tag (`v*`) is pushed:

```sh
git tag v0.1.0
git push origin v0.1.0
```

On a push the workflow, on a macOS 26 runner:

1. Archives the Release configuration with ad-hoc signing (`-`) as a universal
   binary (arm64 + x86_64). The tag value overrides `MARKETING_VERSION`.
2. Builds a "drag to Applications" DMG with `hdiutil`.
3. Creates a GitHub Release for the tag and attaches the DMG, with generated
   release notes plus install/Gatekeeper instructions.

You can also run the **Release** workflow manually (`workflow_dispatch`) to
produce a DMG artifact for testing without publishing a release.

## Notarization

The published DMG is ad-hoc signed only, so users must clear the quarantine
flag once before the first launch. To distribute without any user friction,
join the Apple Developer Program, sign with a Developer ID Application
certificate, and notarize the app. In that case, add `xcrun notarytool submit`
and `xcrun stapler staple` steps after the archive/DMG steps in the workflow,
and supply the certificate and App Store Connect API key via GitHub Secrets.
