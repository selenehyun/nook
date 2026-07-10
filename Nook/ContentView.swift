import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var store = ReaderStore()
    @State private var isAddingFeed = false
    @State private var isInspectorPresented = true
    @State private var isImportingOPML = false
    @State private var isExportingOPML = false
    @AppStorage("autoRefreshEnabled") private var autoRefreshEnabled = true
    @AppStorage("refreshIntervalMinutes") private var refreshIntervalMinutes = 30

    var body: some View {
        NavigationSplitView {
            FeedSidebar(store: store) {
                chooseSyncFolder()
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 270, max: 340)
        } content: {
            ArticleListView(store: store)
                .navigationSplitViewColumnWidth(min: 340, ideal: 420, max: 540)
        } detail: {
            ReaderWorkspaceView(store: store, isInspectorPresented: $isInspectorPresented)
        }
        .frame(minWidth: 920, minHeight: 640)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    isAddingFeed = true
                } label: {
                    Label("Add Feed", systemImage: "plus")
                }
                .disabled(!store.isStorageConfigured || store.isRefreshing)
                .help(store.isStorageConfigured ? "Add Feed" : "Choose a sync folder first")

                Button {
                    store.refreshAll()
                } label: {
                    Label("Refresh All", systemImage: "arrow.clockwise")
                }
                .disabled(store.feeds.isEmpty || store.isRefreshing)
                .help("Refresh All Feeds")

                Button {
                    chooseSyncFolder()
                } label: {
                    Label("Sync Folder", systemImage: "folder")
                }
                .help("Choose iCloud Sync Folder")

                Menu {
                    Button {
                        isImportingOPML = true
                    } label: {
                        Label("Import OPML", systemImage: "square.and.arrow.down")
                    }
                    .disabled(!store.isStorageConfigured || store.isRefreshing)

                    Button {
                        isExportingOPML = true
                    } label: {
                        Label("Export OPML", systemImage: "square.and.arrow.up")
                    }
                    .disabled(store.feeds.isEmpty)
                } label: {
                    Label("Subscriptions", systemImage: "tray.full")
                }
                .help("Import or Export Subscriptions")
            }

            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    store.toggleSelectedStarred()
                } label: {
                    Label(
                        store.selectedArticle?.isStarred == true ? "Unstar" : "Star",
                        systemImage: store.selectedArticle?.isStarred == true ? "star.fill" : "star"
                    )
                }
                .disabled(store.selectedArticle == nil)
                .help("Star Article")

                Button {
                    store.markSelectedRead()
                } label: {
                    Label("Mark Read", systemImage: "checkmark.circle")
                }
                .disabled(store.selectedArticle == nil)
                .help("Mark Selected Article as Read")

                if let article = store.selectedArticle {
                    ShareLink(item: article.url) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .help("Share Article")
                }

                Button {
                    isInspectorPresented.toggle()
                } label: {
                    Label("Inspector", systemImage: "sidebar.trailing")
                }
                .help("Toggle Inspector")
            }
        }
        .sheet(isPresented: $isAddingFeed) {
            AddFeedSheet(isLoading: store.isRefreshing) { feedURL in
                store.addFeed(urlString: feedURL)
            }
        }
        .fileImporter(
            isPresented: $isImportingOPML,
            allowedContentTypes: [.opml, .xml],
            allowsMultipleSelection: false
        ) { result in
            store.handleOPMLImport(result)
        }
        .fileExporter(
            isPresented: $isExportingOPML,
            document: OPMLDocument(feeds: store.feeds),
            contentType: .opml,
            defaultFilename: "NookSubscriptions.opml"
        ) { result in
            store.handleOPMLExport(result)
        }
        .task(id: "\(autoRefreshEnabled)-\(refreshIntervalMinutes)-\(store.isStorageConfigured)") {
            guard autoRefreshEnabled, store.isStorageConfigured else { return }
            await store.runAutoRefreshLoop(intervalMinutes: refreshIntervalMinutes)
        }
        .focusedSceneValue(
            \.readerCommandActions,
            ReaderCommandActions(
                refreshAll: store.refreshAll,
                markSelectedRead: store.markSelectedRead,
                toggleSelectedStarred: store.toggleSelectedStarred,
                selectNextArticle: store.selectNextArticle,
                selectPreviousArticle: store.selectPreviousArticle
            )
        )
    }
}

private extension ContentView {
    @MainActor
    func chooseSyncFolder() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose iCloud Sync Folder")
        panel.message = String(localized: "Choose or create a folder in iCloud Drive. Nook stores NookLibrary.json there.")
        panel.prompt = String(localized: "Choose")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true

        if let iCloudDriveURL = FileManager.default.iCloudDriveURL {
            panel.directoryURL = iCloudDriveURL
        }

        let handleSelection: (NSApplication.ModalResponse) -> Void = { response in
            Task { @MainActor in
                guard response == .OK, let directoryURL = panel.url else {
                    return
                }

                store.configureSyncFolder(directoryURL)
            }
        }

        if let window = NSApplication.shared.modalPresentationWindow {
            panel.beginSheetModal(for: window, completionHandler: handleSelection)
        } else {
            panel.begin(completionHandler: handleSelection)
        }
    }
}

private extension NSApplication {
    var modalPresentationWindow: NSWindow? {
        keyWindow ?? mainWindow ?? windows.first { window in
            window.isVisible && !window.isMiniaturized
        }
    }
}

private extension FileManager {
    var iCloudDriveURL: URL? {
        let url = homeDirectoryForCurrentUser
            .appending(path: "Library/Mobile Documents/com~apple~CloudDocs", directoryHint: .isDirectory)
        return fileExists(atPath: url.path(percentEncoded: false)) ? url : nil
    }
}

private struct ReaderWorkspaceView: View {
    @Bindable var store: ReaderStore
    @Binding var isInspectorPresented: Bool

    var body: some View {
        HStack(spacing: 0) {
            ReaderDetailView(store: store)

            if isInspectorPresented {
                Divider()

                ArticleInspector(store: store)
                    .frame(width: 300)
                    .background(Color(nsColor: .windowBackgroundColor))
            }
        }
    }
}

private struct FeedSidebar: View {
    @Bindable var store: ReaderStore
    var onChooseSyncFolder: () -> Void

    var body: some View {
        List(selection: $store.selectedSource) {
            Section("Sync") {
                Button {
                    onChooseSyncFolder()
                } label: {
                    Label(
                        store.isStorageConfigured ? "Change Sync Folder" : "Choose iCloud Folder",
                        systemImage: store.isStorageConfigured ? "checkmark.icloud" : "icloud"
                    )
                }
                .buttonStyle(.borderless)
                .help("Choose iCloud Sync Folder")

                if let syncFolderDisplayPath = store.syncFolderDisplayPath {
                    Text(syncFolderDisplayPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else {
                    Text("Pick a folder in iCloud Drive to store feeds, articles, read state, and starred state.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Library") {
                ForEach(SmartSource.allCases) { source in
                    SourceRow(
                        title: source.title,
                        systemImage: source.systemImage,
                        count: store.count(for: source)
                    )
                    .tag(SourceSelection.smart(source))
                }
            }

            Section("Feeds") {
                if store.feeds.isEmpty {
                    Text(store.isStorageConfigured ? "Add an RSS or Atom feed." : "Choose a sync folder first.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.feeds) { feed in
                        SourceRow(
                            title: feed.title,
                            subtitle: feed.siteDescription,
                            systemImage: store.isRefreshing(feedID: feed.id) ? "arrow.clockwise" : feed.systemImage,
                            count: store.unreadCount(feedID: feed.id)
                        )
                        .tag(SourceSelection.feed(feed.id))
                        .contextMenu {
                            Button("Refresh Feed") {
                                store.refresh(feedID: feed.id)
                            }
                            Button("Mark Feed as Read") {
                                store.markFeedRead(feedID: feed.id)
                            }
                            Divider()
                            Link("Open Site", destination: feed.siteURL)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Feeds")
    }
}

private struct SourceRow: View {
    var title: String
    var subtitle: String?
    var systemImage: String
    var count: Int

    init(title: String, subtitle: String? = nil, systemImage: String, count: Int) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.count = count
    }

    var body: some View {
        Label {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .lineLimit(1)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                if count > 0 {
                    Text(count, format: .number)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        } icon: {
            Image(systemName: systemImage)
        }
    }
}

private struct ArticleListView: View {
    @Bindable var store: ReaderStore

    var body: some View {
        Group {
            if !store.isStorageConfigured {
                ContentUnavailableView {
                    Label("Choose a Sync Folder", systemImage: "icloud")
                } description: {
                    Text("Nook stores its RSS library in a folder you choose, so iCloud Drive can sync it like a vault.")
                }
            } else if store.visibleArticles.isEmpty {
                ContentUnavailableView {
                    Label("No Articles", systemImage: "newspaper")
                } description: {
                    Text(store.searchText.isEmpty ? "Add an RSS or Atom feed, then refresh." : "No article matches the current search.")
                }
            } else {
                List(selection: $store.selectedArticleID) {
                    ForEach(store.visibleArticles) { article in
                        ArticleRow(article: article, feed: store.feed(for: article.feedID))
                            .tag(article.id)
                            .contextMenu {
                                Button(article.isRead ? "Mark as Unread" : "Mark as Read") {
                                    store.setRead(articleID: article.id, isRead: !article.isRead)
                                }
                                Button(article.isStarred ? "Remove Star" : "Star") {
                                    store.toggleStarred(articleID: article.id)
                                }
                                Divider()
                                Link("Open in Browser", destination: article.url)
                            }
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle(store.selectedSourceTitle)
        .searchable(text: $store.searchText, placement: .toolbar, prompt: "Search Articles")
        .safeAreaInset(edge: .bottom) {
            ArticleListStatusBar(store: store)
        }
        .onChange(of: store.selectedSource) { _, _ in
            store.selectFirstVisibleArticleIfNeeded()
        }
        .onChange(of: store.searchText) { _, _ in
            store.selectFirstVisibleArticleIfNeeded()
        }
    }
}

private struct ArticleRow: View {
    var article: Article
    var feed: Feed?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(article.isRead ? Color.clear : Color.accentColor)
                .frame(width: 8, height: 8)
                .padding(.top, 7)

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(article.title)
                        .fontWeight(article.isRead ? .regular : .semibold)
                        .lineLimit(2)

                    if article.isStarred {
                        Image(systemName: "star.fill")
                            .font(.caption)
                            .foregroundStyle(.yellow)
                            .accessibilityLabel("Starred")
                    }
                }

                Text(article.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                HStack(spacing: 6) {
                    Text(feed?.title ?? String(localized: "Unknown Feed"))
                    Text("·")
                    Text(article.publishedAt, format: .relative(presentation: .named))
                    Text("·")
                    Text("\(article.estimatedReadMinutes) min")
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            }
        }
        .padding(.vertical, 8)
    }
}

private struct ArticleListStatusBar: View {
    @Bindable var store: ReaderStore

    var body: some View {
        HStack(spacing: 12) {
            if store.isRefreshing {
                ProgressView()
                    .controlSize(.small)
                Text("Refreshing")
            } else if let status = store.statusMessage {
                Text(status)
            } else {
                Text("\(store.visibleArticles.count) articles")
            }

            Text("\(store.unreadCount()) unread")

            if let errorMessage = store.errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }

            Spacer()

            Picker("Filter", selection: $store.readingFilter) {
                ForEach(ReadingFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 240)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.bar)
    }
}

private struct ReaderDetailView: View {
    @Bindable var store: ReaderStore
    @Environment(\.openURL) private var openURL

    var body: some View {
        Group {
            if !store.isStorageConfigured {
                ContentUnavailableView {
                    Label("Set Up iCloud Sync", systemImage: "icloud.and.arrow.up")
                } description: {
                    Text("Choose a folder in iCloud Drive. Nook will keep its library JSON there.")
                }
            } else if let article = store.selectedArticle {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        articleHeader(article)

                        Divider()

                        VStack(alignment: .leading, spacing: 16) {
                            ForEach(article.bodyParagraphs, id: \.self) { paragraph in
                                Text(paragraph)
                                    .font(.body)
                                    .lineSpacing(4)
                                    .textSelection(.enabled)
                            }
                        }

                        Divider()

                        HStack {
                            Link(destination: article.url) {
                                Label("Open Original", systemImage: "safari")
                            }

                            ShareLink(item: article.url) {
                                Label("Share", systemImage: "square.and.arrow.up")
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.horizontal, 44)
                    .padding(.vertical, 36)
                    .frame(maxWidth: 820, alignment: .leading)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .task(id: article.id) {
                    await Task.yield()
                    store.markArticleOpened(articleID: article.id)
                }
            } else {
                ContentUnavailableView {
                    Label("Select an Article", systemImage: "newspaper")
                } description: {
                    Text("Choose a story from the article list.")
                }
            }
        }
    }

    private func articleHeader(_ article: Article) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                if let feed = store.feed(for: article.feedID) {
                    Label(feed.title, systemImage: feed.systemImage)
                }

                Text("·")

                Text(article.publishedAt.formatted(date: .abbreviated, time: .shortened))

                Text("·")

                Text("\(article.estimatedReadMinutes) min read")
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            Text(article.title)
                .font(.system(.largeTitle, design: .serif))
                .fontWeight(.semibold)
                .lineLimit(nil)
                .textSelection(.enabled)

            Text(article.summary)
                .font(.title3)
                .foregroundStyle(.secondary)
                .lineSpacing(3)

            HStack(spacing: 10) {
                Button {
                    store.toggleStarred(articleID: article.id)
                } label: {
                    Label(article.isStarred ? "Starred" : "Star", systemImage: article.isStarred ? "star.fill" : "star")
                }

                Button {
                    openURL(article.url)
                } label: {
                    Label("Open", systemImage: "arrow.up.forward")
                }
            }
            .buttonStyle(.bordered)
        }
    }
}

private struct ArticleInspector: View {
    @Bindable var store: ReaderStore

    var body: some View {
        Form {
            if let article = store.selectedArticle {
                Section("Article") {
                    LabeledContent("Status", value: article.isRead ? String(localized: "Read") : String(localized: "Unread"))
                    LabeledContent("Published", value: article.publishedAt.formatted(date: .abbreviated, time: .shortened))
                    LabeledContent("Reading Time", value: String(localized: "\(article.estimatedReadMinutes) min"))

                    Toggle("Starred", isOn: store.starredBinding(articleID: article.id))
                    Toggle("Read", isOn: store.readBinding(articleID: article.id))
                }

                Section("Source") {
                    if let feed = store.feed(for: article.feedID) {
                        LabeledContent("Feed", value: feed.title)
                        LabeledContent("Category", value: feed.category)
                        LabeledContent("Last Refresh", value: feed.lastFetchedAt?.formatted(date: .abbreviated, time: .shortened) ?? String(localized: "Never"))
                        Link("Open Site", destination: feed.siteURL)
                        Link("Open Feed", destination: feed.feedURL)
                    }

                    Link("Open Article", destination: article.url)
                }

                Section("Feed Health") {
                    if let feed = store.feed(for: article.feedID) {
                        Gauge(value: feed.healthScore, in: 0...1) {
                            Text("Availability")
                        } currentValueLabel: {
                            Text(feed.healthScore.formatted(.percent))
                        }
                    }
                }
            } else {
                ContentUnavailableView("No Article", systemImage: "info.circle")
            }
        }
        .formStyle(.grouped)
    }
}

private struct AddFeedSheet: View {
    var isLoading: Bool
    var onAdd: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var feedURL = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Add Feed")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("Paste an RSS or Atom feed URL. Nook will fetch it now and save the library to your sync folder.")
                    .foregroundStyle(.secondary)
            }

            TextField("https://example.com/feed.xml", text: $feedURL)
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()

                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Add") {
                    onAdd(feedURL)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(feedURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoading)
            }
        }
        .padding(24)
        .frame(width: 440)
    }
}

struct ReaderSettingsView: View {
    @AppStorage("autoRefreshEnabled") private var autoRefreshEnabled = true
    @AppStorage("refreshIntervalMinutes") private var refreshIntervalMinutes = 30
    @AppStorage("markReadOnOpen") private var markReadOnOpen = true
    @AppStorage("openLinksInBrowser") private var openLinksInBrowser = true
    @AppStorage(ReaderStorage.displayPathDefaultsKey) private var syncFolderDisplayPath = ""

    var body: some View {
        Form {
            Section("Reading") {
                Toggle("Mark articles as read when opened", isOn: $markReadOnOpen)
                Toggle("Open original links in the default browser", isOn: $openLinksInBrowser)
            }

            Section("Feeds") {
                Toggle("Refresh feeds automatically", isOn: $autoRefreshEnabled)
                Stepper("Refresh every \(refreshIntervalMinutes) minutes", value: $refreshIntervalMinutes, in: 5...240, step: 5)
                    .disabled(!autoRefreshEnabled)
            }

            Section("Storage") {
                LabeledContent("Sync Folder", value: syncFolderDisplayPath.isEmpty ? String(localized: "Not selected") : syncFolderDisplayPath)
                Text("Use the folder button in the main window to choose or change the iCloud Drive folder. Nook stores RSS data in NookLibrary.json inside that folder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 520)
    }
}

struct ReaderCommandActions {
    var refreshAll: @MainActor () -> Void
    var markSelectedRead: @MainActor () -> Void
    var toggleSelectedStarred: @MainActor () -> Void
    var selectNextArticle: @MainActor () -> Void
    var selectPreviousArticle: @MainActor () -> Void
}

private struct ReaderCommandActionsKey: FocusedValueKey {
    typealias Value = ReaderCommandActions
}

extension FocusedValues {
    var readerCommandActions: ReaderCommandActions? {
        get { self[ReaderCommandActionsKey.self] }
        set { self[ReaderCommandActionsKey.self] = newValue }
    }
}

struct ReaderAppCommands: Commands {
    @FocusedValue(\.readerCommandActions) private var actions

    var body: some Commands {
        CommandMenu("Feeds") {
            Button("Refresh All") {
                actions?.refreshAll()
            }
            .keyboardShortcut("r", modifiers: [.command])
            .disabled(actions == nil)

            Divider()

            Button("Mark Selected as Read") {
                actions?.markSelectedRead()
            }
            .keyboardShortcut("m", modifiers: [.command, .shift])
            .disabled(actions == nil)

            Button("Star Selected") {
                actions?.toggleSelectedStarred()
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(actions == nil)

            Divider()

            Button("Next Article") {
                actions?.selectNextArticle()
            }
            .keyboardShortcut(.downArrow, modifiers: [.command])
            .disabled(actions == nil)

            Button("Previous Article") {
                actions?.selectPreviousArticle()
            }
            .keyboardShortcut(.upArrow, modifiers: [.command])
            .disabled(actions == nil)
        }
    }
}

#Preview {
    ContentView()
}
