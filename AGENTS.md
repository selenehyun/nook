# AGENTS.md

## Scope

These instructions apply to the entire repository.

## User And Workflow

- The user prefers Korean communication. Reply in Korean unless the user explicitly asks for another language.
- The user is a web developer with little macOS native app background. When explaining native concepts, map them briefly to familiar web concepts when useful.
- Unless the user says otherwise, work directly on `main`, commit completed work, and push to `origin/main`.
- Do not create feature branches, pull requests, or extra release flows by default.
- Preserve user changes. Never revert unrelated edits or run destructive git commands unless the user explicitly asks.

## Product Direction

Nook is a native macOS RSS reader. Keep it native.

- Use SwiftUI and macOS APIs, not Electron or a browser-style app shell.
- The app shell, navigation, lists, and default reader are native SwiftUI/AppKit. Do not turn Nook into a webview wrapper.
- One deliberate exception: an opt-in full-article reader mode may use a `WKWebView` (`ArticleWebView`) that loads the article page and injects a self-contained reader script. It is invoked from the reader title button, not the default reading surface.
- Favor standard macOS UI patterns: `NavigationSplitView`, toolbars, menus, settings scenes, share links, context menus, keyboard commands, and AppKit bridges when SwiftUI is unreliable.
- The app should fetch real RSS/Atom data. Do not reintroduce mock feed/article data for production reader behavior.
- RSS data belongs in a user-selected sync folder, preferably in iCloud Drive, similar to an Obsidian vault.
- Persist RSS reader state in that folder: feeds, articles, read state, starred state, and refresh metadata.
- Treat `NookLibrary.json` as user data. Make schema changes carefully and prefer backward-compatible migrations.

## Current App Shape

- `Nook/NookApp.swift`: SwiftUI app entry point, window sizing, commands, and Settings scene.
- `Nook/ContentView.swift`: main native UI, split view, sidebar, article list, reader pane, inspector, toolbar, sheets, import/export UI, and settings view.
- `Nook/ReaderStore.swift`: `@MainActor` observable application state, feed actions, persistence coordination, refresh loops, OPML import handling, and mutations.
- `Nook/ReaderModels.swift`: Codable library models for feeds and articles.
- `Nook/ReaderStorage.swift`: security-scoped bookmark persistence and `NookLibrary.json` load/save.
- `Nook/RSSFeedService.swift`: URL normalization, real `URLSession` fetching, RSS/Atom XML parsing, date parsing, and website feed auto-discovery.
- `Nook/OPMLService.swift`: OPML import/export and `.opml` file document support.
- `Nook/Info.plist`: explicit app metadata, including `CFBundleAllowMixedLocalizations` for native dialog localization.
- `Nook/Nook.entitlements`: App Sandbox, network client access, and user-selected read/write file access.

## Important Implementation Notes

- Folder picking must use `NSOpenPanel` from `ContentView.chooseSyncFolder()`. Present it as a sheet with `beginSheetModal(for:)` when a window is available. Avoid `runModal()` for this panel because it can interfere with text input and Korean/English IME switching inside the panel's New Folder dialog.
- Do not replace the folder picker with SwiftUI `fileImporter` for folders; it previously made the "Choose iCloud Folder" action appear to do nothing on macOS.
- Keep the iCloud folder permission flow based on security-scoped bookmarks in `ReaderStorage`.
- The folder picker should default to `~/Library/Mobile Documents/com~apple~CloudDocs` when that path exists, but users may choose any folder.
- Folder picker dialog strings live in `Localizable.strings`. Keep `CFBundleAllowMixedLocalizations` enabled in `Nook/Info.plist` so AppKit-provided dialog controls can follow the user's preferred language.
- Use `URLSession` for network fetches and `XMLParser` for RSS/Atom/OPML parsing.
- Website URLs may be added as feeds. If direct RSS/Atom parsing fails, discover RSS/Atom links from HTML `<link rel="alternate">` tags.
- OPML import/export should support `.opml` and `.xml` where appropriate.
- Automatic refresh is controlled by `@AppStorage("autoRefreshEnabled")` and `@AppStorage("refreshIntervalMinutes")`.
- Prefer keeping UI state in `ContentView` and app/domain state in `ReaderStore`.
- Keep SwiftUI mutations on the main actor. `ReaderStore` is `@MainActor`.
- Use AppKit only where it improves macOS correctness or native behavior.

## Known Native UI Pitfalls

- The app previously hit a SwiftUI/AppKit constraint crash when toggling the first sidebar. Prefer Apple's native sidebar commands (`SidebarCommands`) and avoid custom split-view hacks unless thoroughly tested.
- macOS may log `com.apple.linkd.autoShortcut` or App Intents registration errors during debug runs. Treat them as OS/App Intents noise unless there is a matching app crash or user-visible failure.
- If a UI action appears inert, verify both the SwiftUI action path and whether the native panel/sheet is being presented from a valid window context.

## Build And Verification

Use these commands from the repository root:

```sh
make build
```

Equivalent explicit build command:

```sh
xcodebuild -project Nook.xcodeproj -scheme Nook -destination 'platform=macOS' -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO build
```

Additional checks:

```sh
plutil -lint Nook.xcodeproj/project.pbxproj Nook/Nook.entitlements
git diff --check
```

Notes:

- Xcode builds may need to run outside the sandbox in Codex because Xcode and Swift plugin services access system locations.
- `make build` disables code signing for fast local verification.
- For actual app runs and UI checks, opening `Nook.xcodeproj` in Xcode and using `Command-R` is the simplest path.

## Project Configuration

- Current local toolchain used for verification: Xcode 26.5, Swift 6.3.2.
- Language mode: Swift 6.
- Deployment target: macOS 26.0.
- Apple's newest Xcode may be newer than the local version. Do not churn project settings just because Xcode offers updates unless the user asks or the change is required.

## Git Hygiene

- Before editing, check `git status --short --branch`.
- Stage only files related to the task.
- Before committing, run `git diff --check`; run `make build` or the explicit `xcodebuild` command for Swift changes.
- Commit messages should be concise and conventional, for example `fix: open sync folder picker reliably`.
- Include the Codex co-author trailer when creating commits:

```text
Co-authored-by: Codex <noreply@openai.com>
```
