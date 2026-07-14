import NookKit
import SwiftUI
import UIKit
import UserNotifications

/// iOS settings. Mirrors the macOS Settings tabs (General, Reading, Reader,
/// Feeds, About) as a navigation drill-down — the idiomatic iOS equivalent of
/// macOS's tab bar. Reuses the same @AppStorage keys as the macOS app so
/// preferences stay consistent. Sparkle updates and the Dock badge are
/// macOS-only and intentionally omitted.
struct SettingsView: View {
    @Bindable var store: ReaderStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                NavigationLink {
                    GeneralSettingsScreen()
                } label: {
                    Label("General", systemImage: "gearshape")
                }
                NavigationLink {
                    ReadingSettingsScreen()
                } label: {
                    Label("Reading", systemImage: "book")
                }
                NavigationLink {
                    ReaderSettingsScreen()
                } label: {
                    Label("Reader", systemImage: "textformat")
                }
                NavigationLink {
                    FeedsSettingsScreen(store: store)
                } label: {
                    Label("Feeds", systemImage: "dot.radiowaves.up.forward")
                }
                NavigationLink {
                    AboutSettingsScreen()
                } label: {
                    Label("About", systemImage: "info.circle")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - General

private struct GeneralSettingsScreen: View {
    @AppStorage(AppLanguage.storageKey) private var appLanguage = AppLanguage.system
    @AppStorage("showUnreadBadge") private var showUnreadBadge = true

    var body: some View {
        Form {
            Section("Language") {
                Picker("Language", selection: $appLanguage) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.label).tag(language)
                    }
                }
                if appLanguage != AppLanguage.launchLanguage {
                    Text("Restart Nook to apply the language change.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("App Icon") {
                Toggle("Show unread count on app icon", isOn: $showUnreadBadge)
            }
        }
        .navigationTitle("General")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: appLanguage) { _, newValue in
            AppLanguage.apply(newValue)
        }
    }
}

// MARK: - Reading

private struct ReadingSettingsScreen: View {
    @AppStorage("markReadOnOpen") private var markReadOnOpen = true
    @AppStorage("markReadDelaySeconds") private var markReadDelaySeconds = 3
    @AppStorage("readerViewMode") private var readerViewMode = ReaderViewMode.reader
    @AppStorage("readerLinkBehavior") private var readerLinkBehavior = ReaderLinkBehavior.inApp

    var body: some View {
        Form {
            Section("Reading") {
                Toggle("Mark articles as read when opened", isOn: $markReadOnOpen)
                Stepper("Mark as read after \(markReadDelaySeconds) seconds", value: $markReadDelaySeconds, in: 0...30)
                    .disabled(!markReadOnOpen)
            }

            Section("In-App Browser") {
                Picker("In-App Browser", selection: $readerViewMode) {
                    ForEach(ReaderViewMode.allCases) { Text($0.label).tag($0) }
                }
                Picker("Links Open", selection: $readerLinkBehavior) {
                    ForEach(ReaderLinkBehavior.allCases) { Text($0.label).tag($0) }
                }
            }
        }
        .navigationTitle("Reading")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Reader

private struct ReaderSettingsScreen: View {
    @AppStorage("readerFont") private var readerFont = ReaderFont.system
    @AppStorage("readerFontSize") private var readerFontSize = 18
    @AppStorage("readerLineHeight") private var readerLineHeight = 1.7
    @AppStorage("readerLetterSpacing") private var readerLetterSpacing = 0.0
    @AppStorage("readerBackgroundOption") private var readerBackgroundOption = ReaderColorOption.automatic
    @AppStorage("readerBackgroundHex") private var readerBackgroundHex = "#FFFFFF"
    @AppStorage("readerTextOption") private var readerTextOption = ReaderColorOption.automatic
    @AppStorage("readerTextHex") private var readerTextHex = "#1A1A1A"

    private var backgroundColor: Binding<Color> {
        Binding { Color(hex: readerBackgroundHex) } set: { readerBackgroundHex = $0.hexString }
    }
    private var textColor: Binding<Color> {
        Binding { Color(hex: readerTextHex) } set: { readerTextHex = $0.hexString }
    }

    var body: some View {
        Form {
            Section {
                Picker("Font", selection: $readerFont) {
                    ForEach(ReaderFont.allCases) { Text($0.label).tag($0) }
                }
                Stepper("Font Size: \(readerFontSize)", value: $readerFontSize, in: 12...28)
                Stepper("Line Spacing: \(String(format: "%.1f", readerLineHeight))", value: $readerLineHeight, in: 1.2...2.4, step: 0.1)
                Stepper("Letter Spacing: \(String(format: "%.2f", readerLetterSpacing))", value: $readerLetterSpacing, in: -0.02...0.15, step: 0.01)
            } header: {
                Text("Typography")
            } footer: {
                Text("These options apply when reading in reader mode.")
            }

            Section("Colors") {
                Picker("Background", selection: $readerBackgroundOption) {
                    ForEach(ReaderColorOption.allCases) { Text($0.label).tag($0) }
                }
                if readerBackgroundOption == .custom {
                    ColorPicker("Background Color", selection: backgroundColor, supportsOpacity: false)
                }
                Picker("Text", selection: $readerTextOption) {
                    ForEach(ReaderColorOption.allCases) { Text($0.label).tag($0) }
                }
                if readerTextOption == .custom {
                    ColorPicker("Text Color", selection: textColor, supportsOpacity: false)
                }
            }
        }
        .navigationTitle("Reader")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Feeds

private struct FeedsSettingsScreen: View {
    @Bindable var store: ReaderStore
    @Environment(\.openURL) private var openURL
    @AppStorage("autoRefreshEnabled") private var autoRefreshEnabled = true
    @AppStorage("refreshIntervalMinutes") private var refreshIntervalMinutes = 30
    @AppStorage(BackgroundRefresh.enabledKey) private var newArticleNotifications = false
    @AppStorage(ReaderStorage.displayPathDefaultsKey) private var syncFolderDisplayPath = ""
    /// True when notifications are on but iOS won't actually show alert banners
    /// (denied, or authorized for badge only) — the usual reason "notifications
    /// don't arrive."
    @State private var alertsBlocked = false

    private var sortedFeeds: [Feed] {
        store.feeds.sorted { $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending }
    }

    var body: some View {
        Form {
            Section("Feeds") {
                Toggle("Refresh feeds automatically", isOn: $autoRefreshEnabled)
                Stepper("Refresh every \(refreshIntervalMinutes) minutes", value: $refreshIntervalMinutes, in: 5...240, step: 5)
                    .disabled(!autoRefreshEnabled)
            }

            Section {
                Toggle("Notify me about new articles", isOn: $newArticleNotifications)
                if newArticleNotifications && alertsBlocked {
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            openURL(url)
                        }
                    } label: {
                        Label("Turn on notifications in Settings", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
            } footer: {
                if newArticleNotifications && alertsBlocked {
                    Text("Notification banners are turned off for Nook, so new-article alerts won't appear. Enable them in Settings › Nook › Notifications.")
                } else {
                    Text("Nook checks for new articles in the background and sends a notification when some arrive. iOS decides exactly when to run this, so timing is approximate.")
                }
            }

            Section {
                if sortedFeeds.isEmpty {
                    Text("No feeds yet. Add feeds from the sidebar.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(sortedFeeds) { feed in
                        Picker(selection: viewModeBinding(for: feed)) {
                            Text("Default").tag(ReaderViewMode?.none)
                            Text(ReaderViewMode.reader.label).tag(ReaderViewMode?.some(.reader))
                            Text(ReaderViewMode.original.label).tag(ReaderViewMode?.some(.original))
                        } label: {
                            Text(feed.displayTitle).lineLimit(1)
                        }
                    }
                }
            } header: {
                Text("Reading View")
            } footer: {
                Text("Choose how each feed's articles open in the web view. “Default” follows the In-App Browser setting above.")
            }

            Section {
                LabeledContent("Sync Folder", value: syncFolderDisplayPath.isEmpty ? String(localized: "Not selected") : syncFolderDisplayPath)
            } header: {
                Text("Storage")
            } footer: {
                Text("Nook keeps your feeds in a folder in the cloud so they stay in sync across your devices.")
            }
        }
        .navigationTitle("Feeds")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: newArticleNotifications) { await checkAlerts() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            Task { await checkAlerts() }
        }
    }

    /// Notifications are "blocked" if the user turned them on but iOS won't show
    /// banners — denied, or authorized for badge only (a stale earlier grant).
    private func checkAlerts() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        alertsBlocked = settings.authorizationStatus == .denied
            || (settings.authorizationStatus == .authorized && settings.alertSetting != .enabled)
    }

    private func viewModeBinding(for feed: Feed) -> Binding<ReaderViewMode?> {
        Binding(
            get: { store.feed(for: feed.id)?.preferredViewMode },
            set: { store.setPreferredViewMode($0, feedIDs: [feed.id]) }
        )
    }
}

// MARK: - About

private struct AboutSettingsScreen: View {
    static let repositoryURL = URL(string: "https://github.com/selenehyun/nook")!

    private var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0" }
    private var build: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1" }

    var body: some View {
        Form {
            Section("About") {
                LabeledContent("Version", value: "\(version) (\(build))")
                if let url = feedbackURL {
                    Link(destination: url) {
                        Label("Send Feedback…", systemImage: "envelope")
                    }
                }
                Link(destination: Self.repositoryURL) {
                    Label {
                        Text(verbatim: "GitHub")
                    } icon: {
                        Image("GitHubMark").renderingMode(.template)
                    }
                }
            }
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var feedbackURL: URL? {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let osString = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        let subject = String(localized: "Nook Feedback")
        let intro = String(localized: "Please describe your bug report, feature request, or idea below. Screenshots are welcome.")
        let prompts = String(localized: "• What were you trying to do?\n\n• What actually happened?\n\n• What did you expect instead?")
        let diagnosticsHeader = String(localized: "— Diagnostics (helps with troubleshooting; feel free to delete) —")
        let diagnostics = String(localized: "Nook \(version) (\(build)) · iOS \(osString)")
        let body = "\(intro)\n\n\(prompts)\n\n\n\(diagnosticsHeader)\n\(diagnostics)"

        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&?=+")
        let s = subject.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        let b = body.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        return URL(string: "mailto:rationlunas@gmail.com?subject=\(s)&body=\(b)")
    }
}
