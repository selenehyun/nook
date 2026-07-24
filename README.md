<h1 align="center">
  <img src="docs/icon.png" width="120" alt="Nook" /><br/>
  Nook
</h1>

<p align="center">A small, native RSS reader for macOS and iOS — offline-first, free, and stored in a plain folder on whatever cloud you already use.</p>

<p align="center">
  <a href="https://github.com/selenehyun/nook/releases/latest">
    <img src="https://img.shields.io/badge/Download-macOS-000000?style=for-the-badge&logo=apple&logoColor=white" alt="Download for macOS" />
  </a>
</p>

<p align="center">
  <a href="https://github.com/selenehyun/nook/releases/latest"><img src="https://img.shields.io/github/v/release/selenehyun/nook?label=latest&color=4c71f2" alt="Latest release" /></a>
  <img src="https://img.shields.io/badge/macOS-26%2B-000000?logo=apple&logoColor=white" alt="macOS 26+" />
  <img src="https://img.shields.io/badge/iOS-18%2B-000000?logo=apple&logoColor=white" alt="iOS 18+" />
  <img src="https://img.shields.io/badge/built%20with-SwiftUI-fa7343?logo=swift&logoColor=white" alt="Built with SwiftUI" />
  <a href="https://github.com/selenehyun/nook/stargazers"><img src="https://img.shields.io/github/stars/selenehyun/nook?style=flat&logo=github&label=stars&color=4c71f2" alt="GitHub stars" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-4c71f2" alt="MIT License" /></a>
</p>

<div align="center">
  <table>
    <tr>
      <td valign="middle"><img src="docs/screenshots/main.png" width="660" alt="Nook on macOS — sidebar, article list, and reader"></td>
      <td valign="middle"><img src="docs/screenshots/ios-splash.png" width="180" alt="Nook launch screen on iPhone"></td>
    </tr>
  </table>
</div>

> **New to RSS?** RSS lets you follow sites, blogs, and newsletters in one place — no algorithm, no ads, and nothing deciding what you should read. [Why use RSS feeds →](https://openrss.org/guides/what-are-rss-feeds#why-use-rss-feeds)

## Why Nook

A bird builds its nest one twig at a time — a small place that's entirely its own. Nook brings that idea to reading: gather the writing you care about into a space that fits you, and keep it somewhere you control.

There is no Nook account or Nook sync server. Pick a folder in iCloud Drive, Dropbox, Google Drive, OneDrive, Syncthing, or any other folder-sync service. That service carries Nook's files between devices; Nook then merges the per-device files with CRDTs so concurrent reads, stars, categories, and feed changes do not overwrite each other.

Apple Intelligence features stay on-device. Gemini is available only when you explicitly select it and save your own API key; in that case, the article text is sent directly to Google for the requested operation.

## Highlights

- **Native Mac, iPhone, and iPad apps.** SwiftUI and AppKit surfaces, native navigation, menus, gestures, widgets, sharing, and accessibility.
- **A folder is the sync service.** Your library remains portable, inspectable JSON in storage you choose, with OPML import and export for subscriptions.
- **A real native reader.** Typography, images, links, code, quotes, nested lists, and tables render without making the default reader a web view. Full-page and original-site modes remain available.
- **Translation that keeps its shape.** Use Apple Intelligence on-device or opt into Gemini. Gemini translates the native reader as coherent Markdown, preserving the context of headings, lists, tables, links, and code while it streams.
- **Markdown in and out.** Copy the article body as Markdown or save it as a `.md` file. When a Gemini-translated Markdown article is visible, that translated version is exported.
- **Rules you control.** Create categories, keyword filters, hidden sources, and optional AI classification. Automatic list-title translation and new-article notifications are opt-in.
- **Offline-first reading.** Feed content is local, selected full articles can be downloaded, and automatic expiry is configurable.
- **Quiet cross-device alerts.** Seen state suppresses duplicate alerts. A Mac left open but hidden, minimized, locked, asleep, or idle yields notification ownership to iOS.

See [all features and their defaults](docs/features.md), including which options are opt-in, opt-out, device-local, or network-backed.

## Is Nook the right reader for you?

Nook is strongest when you want a native Apple-platform reader, no service account, control of the sync folder, and optional translation without making AI mandatory. A hosted reader may fit better if you need a web or Android client, server-side feed collection while all your devices are offline, team features, or a large annotation and knowledge-management system.

See the neutral [RSS reader comparison](docs/reader-comparison.md) for Nook, NetNewsWire, Reeder, Feedly, and Readwise Reader, with official sources and tradeoffs rather than a checklist score.

## Install

### macOS (Homebrew)

```sh
brew install --cask selenehyun/tap/nook
```

Nook is ad-hoc signed rather than notarized. On first launch, right-click **Nook** in Applications and choose **Open**, or install without quarantine:

```sh
HOMEBREW_CASK_OPTS="--no-quarantine" brew install --cask selenehyun/tap/nook
```

### macOS (DMG)

1. Download the latest [Nook DMG](https://github.com/selenehyun/nook/releases/latest).
2. Drag **Nook** into **Applications**.
3. Right-click `Nook.app` and choose **Open**, or run `xattr -dr com.apple.quarantine /Applications/Nook.app` once.
4. Choose the folder where Nook should keep and sync your library.

Requires **macOS 26 (Tahoe)** or later. The universal build supports Apple Silicon and Intel. Apple Intelligence translation requires a supported Apple Silicon Mac; Gemini is optional and requires your own API key and a network connection.

### iOS / iPadOS

There is no App Store build yet. To install it on your own device:

1. Open `Nook.xcodeproj` and select the **NookiOS** scheme and your device.
2. Choose your team under **Signing & Capabilities**, then press **⌘R**.
3. Through the Files picker, select the same synced folder used by your Mac.

Requires **iOS/iPadOS 18** or later. Apple Intelligence translation requires a supported device running **iOS 26**.

## Learn more

- [Features, controls, and platform details](docs/features.md)
- [Comparison with other RSS readers](docs/reader-comparison.md)
- [Data ownership, cloud sync, and conflict handling](docs/data-and-sync.md)
- [Building, architecture, and releasing](docs/development.md)
- [Homebrew tap setup](docs/homebrew-tap.md)

## Build from source

```sh
git clone https://github.com/selenehyun/nook
cd nook
make build
```

See [development notes](docs/development.md) for the iOS build command, architecture, toolchain, and release process.

## License

[MIT](LICENSE) © 2026 Tim.
