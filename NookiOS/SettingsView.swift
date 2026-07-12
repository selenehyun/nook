import NookKit
import SwiftUI

/// iOS settings. A single grouped form mirroring the macOS Settings tabs
/// (Reading, Reader, Feeds, General, About). Reuses the same @AppStorage keys
/// as the macOS app so preferences stay consistent. Sparkle updates and the
/// Dock badge are macOS-only and intentionally omitted.
struct SettingsView: View {
    @Bindable var store: ReaderStore
    @Environment(\.dismiss) private var dismiss

    // Reading
    @AppStorage("markReadOnOpen") private var markReadOnOpen = true
    @AppStorage("markReadDelaySeconds") private var markReadDelaySeconds = 3
    @AppStorage("readerViewMode") private var readerViewMode = ReaderViewMode.reader
    @AppStorage("readerLinkBehavior") private var readerLinkBehavior = ReaderLinkBehavior.inApp

    // Reader typography / colors
    @AppStorage("readerFont") private var readerFont = ReaderFont.system
    @AppStorage("readerFontSize") private var readerFontSize = 18
    @AppStorage("readerLineHeight") private var readerLineHeight = 1.7
    @AppStorage("readerLetterSpacing") private var readerLetterSpacing = 0.0
    @AppStorage("readerBackgroundOption") private var readerBackgroundOption = ReaderColorOption.automatic
    @AppStorage("readerBackgroundHex") private var readerBackgroundHex = "#FFFFFF"
    @AppStorage("readerTextOption") private var readerTextOption = ReaderColorOption.automatic
    @AppStorage("readerTextHex") private var readerTextHex = "#1A1A1A"

    // Feeds
    @AppStorage("autoRefreshEnabled") private var autoRefreshEnabled = true
    @AppStorage("refreshIntervalMinutes") private var refreshIntervalMinutes = 30
    @AppStorage(ReaderStorage.displayPathDefaultsKey) private var syncFolderDisplayPath = ""

    // General
    @AppStorage(AppLanguage.storageKey) private var appLanguage = AppLanguage.system
    @AppStorage("showUnreadBadge") private var showUnreadBadge = true

    private var backgroundColor: Binding<Color> {
        Binding { Color(hex: readerBackgroundHex) } set: { readerBackgroundHex = $0.hexString }
    }
    private var textColor: Binding<Color> {
        Binding { Color(hex: readerTextHex) } set: { readerTextHex = $0.hexString }
    }

    private var sortedFeeds: [Feed] {
        store.feeds.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0" }
    private var build: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1" }

    var body: some View {
        NavigationStack {
            Form {
                readingSection
                typographySection
                colorsSection
                feedsSection
                perFeedSection
                storageSection
                generalSection
                aboutSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: appLanguage) { _, newValue in
                AppLanguage.apply(newValue)
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var readingSection: some View {
        Section("Reading") {
            Toggle("Mark articles as read when opened", isOn: $markReadOnOpen)
            Stepper("Mark as read after \(markReadDelaySeconds) seconds", value: $markReadDelaySeconds, in: 0...30)
                .disabled(!markReadOnOpen)
            Picker("In-App Browser", selection: $readerViewMode) {
                ForEach(ReaderViewMode.allCases) { Text($0.label).tag($0) }
            }
            Picker("Links Open", selection: $readerLinkBehavior) {
                ForEach(ReaderLinkBehavior.allCases) { Text($0.label).tag($0) }
            }
        }
    }

    private var typographySection: some View {
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
    }

    private var colorsSection: some View {
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

    private var feedsSection: some View {
        Section("Feeds") {
            Toggle("Refresh feeds automatically", isOn: $autoRefreshEnabled)
            Stepper("Refresh every \(refreshIntervalMinutes) minutes", value: $refreshIntervalMinutes, in: 5...240, step: 5)
                .disabled(!autoRefreshEnabled)
        }
    }

    @ViewBuilder
    private var perFeedSection: some View {
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
                        Text(feed.title).lineLimit(1)
                    }
                }
            }
        } header: {
            Text("Reading View")
        } footer: {
            Text("Choose how each feed's articles open in the web view. “Default” follows the In-App Browser setting above.")
        }
    }

    private var storageSection: some View {
        Section {
            LabeledContent("Sync Folder", value: syncFolderDisplayPath.isEmpty ? String(localized: "Not selected") : syncFolderDisplayPath)
        } header: {
            Text("Storage")
        } footer: {
            Text("Nook keeps your feeds in a folder in the cloud so they stay in sync across your devices.")
        }
    }

    @ViewBuilder
    private var generalSection: some View {
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

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("Version", value: "\(version) (\(build))")
            if let url = feedbackURL {
                Link(destination: url) {
                    Label("Send Feedback…", systemImage: "envelope")
                }
            }
        }
    }

    private func viewModeBinding(for feed: Feed) -> Binding<ReaderViewMode?> {
        Binding(
            get: { store.feed(for: feed.id)?.preferredViewMode },
            set: { store.setPreferredViewMode($0, feedIDs: [feed.id]) }
        )
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
