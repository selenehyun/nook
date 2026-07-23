import BackgroundTasks
import NookKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import UserNotifications

/// iOS settings. Mirrors the macOS Settings tabs (General, Reading, Reader,
/// Feeds, About) as a navigation drill-down — the idiomatic iOS equivalent of
/// macOS's tab bar. Reuses the same @AppStorage keys as the macOS app so
/// preferences stay consistent. Sparkle updates and the Dock badge are
/// macOS-only and intentionally omitted.
struct SettingsView: View {
    @Bindable var store: ReaderStore
    /// True when hosted as the iPhone Settings tab (no "Done" button, and the
    /// OPML import/export + sync-folder actions the sidebar owns on iPad move
    /// into a "Data" section here). Defaults to sheet presentation (iPad),
    /// leaving that path unchanged.
    var isTab: Bool = false
    @Environment(\.dismiss) private var dismiss
    @AppStorage(TourFlags.hasCompletedWelcomeKey) private var hasCompletedWelcome = false
    @AppStorage(TourFlags.seenReaderGestureHintKey) private var seenReaderGestureHint = false
    @AppStorage(TourFlags.seenListHintKey) private var seenListHint = false

    /// A single file importer backs both the sync-folder picker and OPML import;
    /// stacking two `.fileImporter` modifiers on one view makes only one work.
    private enum ImportKind { case folder, opml }
    @State private var importKind: ImportKind = .folder
    @State private var isImporting = false
    @State private var isExportingOPML = false
    @State private var opmlImport: OPMLImportRequest?

    var body: some View {
        NavigationStack {
            List {
                Section {
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
                        ExperimentalSettingsScreen()
                    } label: {
                        Label("Experimental", systemImage: "flask")
                    }
                    NavigationLink {
                        AboutSettingsScreen()
                    } label: {
                        Label("About", systemImage: "info.circle")
                    }
                }
                .warmRows()

                Section {
                    Button {
                        // Reset every tour flag so replay and first-run share one
                        // path, then close (on iPad) so the cover shows over the app.
                        seenReaderGestureHint = false
                        seenListHint = false
                        hasCompletedWelcome = false
                        if !isTab { dismiss() }
                    } label: {
                        Label("Replay Tutorial", systemImage: "questionmark.circle")
                    }
                } header: {
                    Text("Help")
                }
                .warmRows()

                if isTab {
                    Section("Data") {
                        Button {
                            importKind = .folder
                            isImporting = true
                        } label: {
                            Label(
                                store.isStorageConfigured ? "Change Sync Folder" : "Choose Sync Folder",
                                systemImage: store.isStorageConfigured ? "checkmark.icloud" : "icloud"
                            )
                        }
                        Button {
                            importKind = .opml
                            isImporting = true
                        } label: {
                            Label("Import OPML", systemImage: "square.and.arrow.down")
                        }
                        Button {
                            isExportingOPML = true
                        } label: {
                            Label("Export OPML", systemImage: "square.and.arrow.up")
                        }
                        .disabled(store.feeds.isEmpty)
                    }
                    .warmRows()
                }
            }
            .warmListBackground()
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !isTab {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
            }
            .modifier(DataActionsModifier(
                isTab: isTab,
                store: store,
                importIsFolder: importKind == .folder,
                isImporting: $isImporting,
                isExportingOPML: $isExportingOPML,
                opmlImport: $opmlImport
            ))
        }
    }
}

/// Attaches the sync-folder / OPML importers and exporters — but only when
/// Settings is hosted as the iPhone tab. On iPad (sheet) this adds nothing, so
/// that presentation path is unchanged.
private struct DataActionsModifier: ViewModifier {
    let isTab: Bool
    let store: ReaderStore
    let importIsFolder: Bool
    @Binding var isImporting: Bool
    @Binding var isExportingOPML: Bool
    @Binding var opmlImport: OPMLImportRequest?

    func body(content: Content) -> some View {
        if isTab {
            content
                .fileImporter(
                    isPresented: $isImporting,
                    allowedContentTypes: importIsFolder ? [.folder] : [.opml, .xml],
                    allowsMultipleSelection: false
                ) { result in
                    guard case .success(let urls) = result, let url = urls.first else { return }
                    if importIsFolder {
                        _ = url.startAccessingSecurityScopedResource()
                        store.configureSyncFolder(url)
                    } else {
                        let candidates = store.parseOPML(at: url)
                        if candidates.isEmpty {
                            store.errorMessage = String(localized: "No feeds found in the OPML file.")
                        } else {
                            opmlImport = OPMLImportRequest(feeds: candidates)
                        }
                    }
                }
                .fileExporter(
                    isPresented: $isExportingOPML,
                    document: OPMLDocument(feeds: store.feeds),
                    contentType: .opml,
                    defaultFilename: "NookSubscriptions.opml"
                ) { result in
                    store.handleOPMLExport(result)
                }
                .sheet(item: $opmlImport) { request in
                    OPMLImportView(
                        feeds: request.feeds,
                        existingKeys: Set(store.feeds.flatMap { [$0.feedURL.feedIdentityKey, $0.siteURL.feedIdentityKey] })
                    ) { selected in
                        store.importFeeds(selected)
                    }
                }
        } else {
            content
        }
    }
}

// MARK: - General

private struct GeneralSettingsScreen: View {
    @AppStorage(AppLanguage.storageKey) private var appLanguage = AppLanguage.system
    @AppStorage("showUnreadBadge") private var showUnreadBadge = true

    var body: some View {
        List {
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
            .warmRows()

            Section("App Icon") {
                Toggle("Show unread count on app icon", isOn: $showUnreadBadge)
            }
            .warmRows()
        }
        .warmListBackground()
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
    @AppStorage(ReaderStore.longPressOpensBrowserKey) private var longPressOpensBrowser = false

    var body: some View {
        List {
            Section("Reading") {
                Toggle("Mark articles as read when opened", isOn: $markReadOnOpen)
                Stepper("Mark as read after \(markReadDelaySeconds) seconds", value: $markReadDelaySeconds, in: 0...30)
                    .disabled(!markReadOnOpen)
            }
            .warmRows()

            Section("In-App Browser") {
                Picker("In-App Browser", selection: $readerViewMode) {
                    ForEach(ReaderViewMode.allCases) { Text($0.label).tag($0) }
                }
                Picker("Links Open", selection: $readerLinkBehavior) {
                    ForEach(ReaderLinkBehavior.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Press and hold article to open browser", isOn: $longPressOpensBrowser)
                Text("When on, press-and-hold the article body to open the in-app browser. The toolbar button opens it either way.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .warmRows()
        }
        .warmListBackground()
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
        List {
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
            .warmRows()

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
            .warmRows()
        }
        .warmListBackground()
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
    @AppStorage(ReaderStore.resolveMissingDatesKey) private var resolveMissingDates = true
    @AppStorage(BackgroundRefresh.enabledKey) private var newArticleNotifications = false
    @AppStorage(ReaderStorage.displayPathDefaultsKey) private var syncFolderDisplayPath = ""
    /// True when notifications are on but iOS won't actually show alert banners
    /// (denied, or authorized for badge only) — the usual reason "notifications
    /// don't arrive."
    @State private var alertsBlocked = false
    /// True when notifications are on but iOS won't run Nook in the background
    /// (Background App Refresh off, globally or for Nook) — so scheduled refreshes
    /// never fire and no new-article notification can ever arrive.
    @State private var backgroundRefreshBlocked = false
    @State private var notificationStatus = "—"
    @State private var backgroundStatus = "—"
    @State private var pendingRefreshCount = 0

    private var sortedFeeds: [Feed] {
        store.feeds.sorted { $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending }
    }

    var body: some View {
        List {
            Section {
                Toggle("Refresh feeds automatically", isOn: $autoRefreshEnabled)
                Stepper("Refresh every \(refreshIntervalMinutes) minutes", value: $refreshIntervalMinutes, in: 5...240, step: 5)
                    .disabled(!autoRefreshEnabled)
                Toggle("Fill in missing article dates", isOn: $resolveMissingDates)
            } header: {
                Text("Feeds")
            } footer: {
                Text("Some feeds omit each article's date. When enabled, Nook reads the real date from the article's page (once per article).")
            }
            .warmRows()

            Section {
                Toggle("Notify me about new articles", isOn: $newArticleNotifications)
                if newArticleNotifications && backgroundRefreshBlocked {
                    Button {
                        openSystemSettings()
                    } label: {
                        Label("Turn on Background App Refresh", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
                if newArticleNotifications && alertsBlocked {
                    Button {
                        openSystemSettings()
                    } label: {
                        Label("Turn on notifications in Settings", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
                Button("Send Test Notification") {
                    Task {
                        await NewArticleNotifier.post(
                            title: String(localized: "New in Nook"),
                            body: String(localized: "Test notification"),
                            badge: 0
                        )
                        UserDefaults.standard.set("test submitted", forKey: BackgroundRefresh.lastNotificationResultKey)
                    }
                }
                .disabled(alertsBlocked)
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    if newArticleNotifications && backgroundRefreshBlocked {
                        Text("Background App Refresh is off, so Nook can't check for new articles in the background and no notifications will arrive. Tap above, then turn on Settings › General › Background App Refresh and enable it for Nook.")
                            .foregroundStyle(.orange)
                    }
                    if newArticleNotifications && alertsBlocked {
                        Text("Notification banners are turned off for Nook, so new-article alerts won't appear. Enable them in Settings › Nook › Notifications.")
                            .foregroundStyle(.orange)
                    }
                    Text("Nook checks for new articles in the background and sends a notification when some arrive. iOS decides exactly when to run this, so timing is approximate.")
                }
            }
            .warmRows()

            Section("Background Diagnostics") {
                LabeledContent("Notification Authorization", value: notificationStatus)
                LabeledContent("Background App Refresh", value: backgroundStatus)
                LabeledContent("Pending Requests", value: "\(pendingRefreshCount)")
                diagnosticRow("Last Schedule", key: BackgroundRefresh.lastScheduleKey)
                diagnosticRow("Schedule Result", key: BackgroundRefresh.lastScheduleResultKey)
                diagnosticRow("Last Run", key: BackgroundRefresh.lastRunKey)
                diagnosticRow("Fetch Result", key: BackgroundRefresh.lastFetchResultKey)
                diagnosticRow("Notification Result", key: BackgroundRefresh.lastNotificationResultKey)
            }
            .warmRows()

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
            .warmRows()

            Section {
                LabeledContent("Sync Folder", value: syncFolderDisplayPath.isEmpty ? String(localized: "Not selected") : syncFolderDisplayPath)
            } header: {
                Text("Storage")
            } footer: {
                Text("Nook keeps your feeds in a folder in the cloud so they stay in sync across your devices.")
            }
            .warmRows()
        }
        .warmListBackground()
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
        notificationStatus = String(describing: settings.authorizationStatus)
        let refreshStatus = UIApplication.shared.backgroundRefreshStatus
        backgroundRefreshBlocked = refreshStatus != .available
        backgroundStatus = switch refreshStatus {
        case .available: "available"
        case .denied: "denied"
        case .restricted: "restricted"
        @unknown default: "unknown"
        }
        pendingRefreshCount = await withCheckedContinuation { continuation in
            BGTaskScheduler.shared.getPendingTaskRequests { requests in
                continuation.resume(returning: requests.filter { $0.identifier == BackgroundRefresh.taskIdentifier }.count)
            }
        }
    }

    /// Opens Nook's page in the system Settings app — the deepest link the OS
    /// allows. From there the user reaches Notifications and (when the global
    /// switch is on) Background App Refresh for Nook; the footer text points them
    /// to Settings › General › Background App Refresh for the global toggle.
    private func openSystemSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            openURL(url)
        }
    }

    @ViewBuilder
    private func diagnosticRow(_ title: LocalizedStringKey, key: String) -> some View {
        let defaults = UserDefaults.standard
        if let date = defaults.object(forKey: key) as? Date {
            LabeledContent(title) { Text(date, style: .relative) }
        } else {
            LabeledContent(title, value: defaults.string(forKey: key) ?? "—")
        }
    }

    private func viewModeBinding(for feed: Feed) -> Binding<ReaderViewMode?> {
        Binding(
            get: { store.feed(for: feed.id)?.preferredViewMode },
            set: { store.setPreferredViewMode($0, feedIDs: [feed.id]) }
        )
    }
}

// MARK: - Experimental

private struct ExperimentalSettingsScreen: View {
    @AppStorage(ReaderStore.readerContentByDefaultKey) private var readerContentByDefault = true
    @AppStorage(ReaderStore.translateListTitlesKey) private var translateListTitles = false
    @AppStorage(ReaderStore.coherentArticleTranslationKey) private var coherentArticleTranslation = false
    @State private var confirmingClearTranslationCache = false

    var body: some View {
        List {
            Section("Reader View") {
                Toggle("Show reader view content by default", isOn: $readerContentByDefault)
                Text("Fetches the full article and shows its Reader-view content in the native reader instead of the feed's summary. Turn off to read the original feed content. If Reader view can't be loaded, the original content is shown with a notice.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Coherent long-article translation", isOn: $coherentArticleTranslation)
                Text("When translating a full article, keeps the previous paragraph in context so the translation reads more consistently across a long piece. Experimental — it falls back to the standard paragraph-by-paragraph translation whenever needed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .warmRows()

            Section("Article List") {
                Toggle("Translate titles in the list", isOn: $translateListTitles)
                Text("Titles of the stories on screen are translated into your language with Apple Intelligence, shown beneath the original. Only titles that stay in view are translated, and results are cached. Titles already in your language are left as-is.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button(role: .destructive) {
                    confirmingClearTranslationCache = true
                } label: {
                    Text("Clear Translation Cache")
                }
            }
            .warmRows()
        }
        .warmListBackground()
        .navigationTitle("Experimental")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Clear Translation Cache",
            isPresented: $confirmingClearTranslationCache,
            titleVisibility: .visible
        ) {
            Button("Clear Translation Cache", role: .destructive) {
                ListTitleTranslator.shared.clearCache()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Deletes all saved title translations on this device. Titles are translated again as you view them.")
        }
    }
}

// MARK: - About

private struct AboutSettingsScreen: View {
    static let repositoryURL = URL(string: "https://github.com/selenehyun/nook")!

    private var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0" }
    private var build: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1" }

    var body: some View {
        List {
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
            .warmRows()
        }
        .warmListBackground()
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

/// Gives a `List`/`Form` the app's warm tone — hiding the default system grouped
/// background and letting `ListBackground` show through transparent rows — so
/// Settings matches the article list instead of the plain (or cool frosted)
/// system background.
private extension View {
    /// Warm background for a Settings list. Rows must additionally use
    /// `.warmRows()` on each `Section` — a container-level row background does not
    /// reach grouped-list rows, leaving cool `secondarySystemGroupedBackground`
    /// cards, so the clear must be applied per-section.
    func warmListBackground() -> some View {
        scrollContentBackground(.hidden)
            .background(Color("ListBackground").ignoresSafeArea())
            // Tighten the grouped list's generous section spacing (and the large
            // gap above the first section) so the top isn't mostly whitespace.
            .listSectionSpacing(.compact)
            .contentMargins(.top, 8, for: .scrollContent)
    }

    /// Clears a `Section`'s row cards so the warm background shows through. Applied
    /// per section because that reliably reaches the rows.
    func warmRows() -> some View {
        listRowBackground(Color.clear)
    }
}
