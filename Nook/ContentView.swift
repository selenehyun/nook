import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    private static let sidebarVisibleKey = "sidebarVisible"

    @State private var store = ReaderStore()
    @State private var isAddingFeed = false
    @State private var isImportingOPML = false
    @State private var isExportingOPML = false
    @State private var opmlImport: OPMLImportRequest?
    @State private var columnVisibility: NavigationSplitViewVisibility
    @AppStorage("inspectorPresented") private var isInspectorPresented = true
    @AppStorage(ContentView.sidebarVisibleKey) private var sidebarVisible = true
    @AppStorage("autoRefreshEnabled") private var autoRefreshEnabled = true
    @AppStorage("refreshIntervalMinutes") private var refreshIntervalMinutes = 30

    init() {
        // Restore the last sidebar state before the first render to avoid a flash.
        let wasVisible = UserDefaults.standard.object(forKey: ContentView.sidebarVisibleKey) as? Bool ?? true
        _columnVisibility = State(initialValue: wasVisible ? .all : .doubleColumn)
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
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

            ToolbarItem(placement: .principal) {
                WindowBreadcrumb(store: store)
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
            guard case .success(let urls) = result, let fileURL = urls.first else { return }
            let candidates = store.parseOPML(at: fileURL)
            if candidates.isEmpty {
                store.errorMessage = String(localized: "No feeds found in the OPML file.")
            } else {
                opmlImport = OPMLImportRequest(feeds: candidates)
            }
        }
        .sheet(item: $opmlImport) { request in
            OPMLImportView(
                feeds: request.feeds,
                existingKeys: Set(store.feeds.flatMap { [$0.feedURL.feedIdentityKey, $0.siteURL.feedIdentityKey] })
            ) { selected in
                store.importFeeds(selected)
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
        .task(id: "\(autoRefreshEnabled)-\(refreshIntervalMinutes)-\(store.isStorageConfigured)") {
            guard autoRefreshEnabled, store.isStorageConfigured else { return }
            await store.runAutoRefreshLoop(intervalMinutes: refreshIntervalMinutes)
        }
        .onChange(of: columnVisibility) { _, newValue in
            sidebarVisible = (newValue == .all)
        }
        .onOpenURL { url in
            if let raw = WidgetShared.smartSourceRaw(from: url), let source = SmartSource(rawValue: raw) {
                store.selectSmartSource(source)
            }
            // nook://open simply brings the app forward.
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
        panel.message = String(localized: "Pick a folder in iCloud Drive so Nook can keep your feeds in sync across your devices.")
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

        // Make sure Nook is the active, key application before presenting. The
        // sandboxed open panel (and its nested "New Folder" dialog) run out of
        // process, and their text fields only receive input-source (한/영)
        // switching when the hosting app is truly frontmost and key.
        NSApp.activate()

        if let window = NSApplication.shared.modalPresentationWindow {
            window.makeKeyAndOrderFront(nil)
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

    @AppStorage("collapsedFolders") private var collapsedFoldersData = Data()
    @State private var isCreatingFolder = false
    @State private var newFolderName = ""
    @State private var folderPendingDeletion: String?
    @State private var dropTargetFolder: String?
    @State private var isTopLevelDropTargeted = false

    var body: some View {
        List(selection: $store.feedSelection) {
            Section("Library") {
                ForEach(SmartSource.allCases) { source in
                    smartSourceRow(source)
                }
            }

            Section {
                if store.feeds.isEmpty && store.feedFolders.isEmpty {
                    Text(store.isStorageConfigured ? "Add an RSS or Atom feed." : "Choose a sync folder first.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.ungroupedFeeds) { feed in
                        feedRow(feed)
                    }

                    ForEach(store.feedFolders, id: \.self) { folder in
                        folderHeader(folder)

                        if !collapsedFolders.contains(folder) {
                            ForEach(store.feeds(inFolder: folder)) { feed in
                                feedRow(feed)
                                    .padding(.leading, 14)
                            }
                        }
                    }
                }
            } header: {
                HStack(spacing: 6) {
                    if isTopLevelDropTargeted {
                        Label("Move out of folder", systemImage: "tray.and.arrow.up")
                            .foregroundStyle(Color.accentColor)
                            .fontWeight(.semibold)
                    } else {
                        Text("Feeds")
                    }
                    Spacer()
                    Button {
                        newFolderName = ""
                        isCreatingFolder = true
                    } label: {
                        Image(systemName: "folder.badge.plus")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("New Folder")
                    .disabled(!store.isStorageConfigured)
                }
                .padding(.vertical, 3)
                .padding(.horizontal, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.accentColor.opacity(isTopLevelDropTargeted ? 0.2 : 0))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(Color.accentColor, lineWidth: isTopLevelDropTargeted ? 1.5 : 0)
                        )
                )
                .contentShape(Rectangle())
                .dropDestination(for: String.self) { droppedIDs, _ in
                    for id in droppedIDs { store.moveFeed(id, toFolder: "") }
                    isTopLevelDropTargeted = false
                    return true
                } isTargeted: { targeted in
                    withAnimation(.easeOut(duration: 0.1)) {
                        isTopLevelDropTargeted = targeted
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Feeds")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SyncFolderFooter(store: store, onChoose: onChooseSyncFolder)
        }
        .alert("New Folder", isPresented: $isCreatingFolder) {
            TextField("Folder Name", text: $newFolderName)
            Button("Create") { store.createFolder(newFolderName) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Create an empty folder to organize feeds.")
        }
        .confirmationDialog(
            "Remove Folder",
            isPresented: Binding(
                get: { folderPendingDeletion != nil },
                set: { if !$0 { folderPendingDeletion = nil } }
            ),
            presenting: folderPendingDeletion
        ) { folder in
            Button("Remove Folder", role: .destructive) {
                store.removeFolder(folder)
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The folder and any feeds inside it will be removed.")
        }
    }

    /// Per-folder collapsed state, persisted so it is restored on relaunch.
    private var collapsedFolders: Set<String> {
        get { (try? JSONDecoder().decode(Set<String>.self, from: collapsedFoldersData)) ?? [] }
        nonmutating set { collapsedFoldersData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }

    @ViewBuilder
    private func folderHeader(_ folder: String) -> some View {
        let isActive = store.isFolderSelected(folder)
        let isCollapsed = collapsedFolders.contains(folder)
        let unread = store.unreadCount(inFolder: folder)

        HStack(spacing: 4) {
            Button {
                withAnimation(.snappy(duration: 0.2)) {
                    if isCollapsed { collapsedFolders.remove(folder) } else { collapsedFolders.insert(folder) }
                }
            } label: {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(isActive ? Color.white.opacity(0.9) : Color.secondary)
                    .frame(width: 12, height: 12)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Label(folder, systemImage: "folder")
                .lineLimit(1)

            Spacer(minLength: 8)

            if unread > 0 {
                Text(unread, format: .number)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(isActive ? Color.white.opacity(0.85) : Color.secondary)
            }
        }
        .contentShape(Rectangle())
        .foregroundStyle((isActive && dropTargetFolder != folder) ? Color.white : Color.primary)
        .onTapGesture {
            store.selectFolder(folder)
        }
        .listRowBackground(folderRowBackground(folder: folder, isActive: isActive))
        .dropDestination(for: String.self) { droppedIDs, _ in
            for id in droppedIDs { store.moveFeed(id, toFolder: folder) }
            dropTargetFolder = nil
            return true
        } isTargeted: { targeted in
            withAnimation(.easeOut(duration: 0.1)) {
                if targeted {
                    dropTargetFolder = folder
                } else if dropTargetFolder == folder {
                    dropTargetFolder = nil
                }
            }
        }
        .contextMenu {
            Button(role: .destructive) {
                folderPendingDeletion = folder
            } label: {
                Text("Remove Folder")
            }
        }
    }

    @ViewBuilder
    private func folderRowBackground(folder: String, isActive: Bool) -> some View {
        if dropTargetFolder == folder {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.accentColor.opacity(0.2))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: 1.5)
                )
                .padding(.horizontal, 6)
        } else if isActive {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.accentColor)
                .padding(.horizontal, 6)
        } else {
            Color.clear
        }
    }

    @ViewBuilder
    private func feedRow(_ feed: Feed) -> some View {
        SourceRow(
            title: feed.title,
            subtitle: feed.siteDescription,
            systemImage: store.isRefreshing(feedID: feed.id) ? "arrow.clockwise" : feed.systemImage,
            iconImage: store.isRefreshing(feedID: feed.id) ? nil : store.faviconImage(for: feed),
            isUnhealthy: !store.isRefreshing(feedID: feed.id) && feed.healthScore < 0.5,
            count: store.unreadCount(feedID: feed.id)
        )
        .tag(feed.id)
        .draggable(feed.id)
        .contextMenu {
            feedContextMenu(feed)
        }
    }

    @ViewBuilder
    private func smartSourceRow(_ source: SmartSource) -> some View {
        let isActive = store.feedSelection.isEmpty && store.smartSelection == source
        Button {
            store.selectSmartSource(source)
        } label: {
            HStack(spacing: 8) {
                Label(source.title, systemImage: source.systemImage)
                Spacer(minLength: 8)
                let count = store.count(for: source)
                if count > 0 {
                    Text(count, format: .number)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(isActive ? Color.white.opacity(0.85) : Color.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isActive ? Color.white : Color.primary)
        .listRowBackground(
            isActive
                ? RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.accentColor).padding(.horizontal, 6)
                : nil
        )
    }

    /// Acts on the whole feed selection when the right-clicked feed is part of
    /// a multi-selection; otherwise just on that feed. "Open Site" is disabled
    /// for multiple feeds; the rest run on all of them at once.
    @ViewBuilder
    private func feedContextMenu(_ feed: Feed) -> some View {
        let selected = store.selectedFeedIDs
        let targets = (selected.contains(feed.id) && selected.count > 1) ? selected : [feed.id]
        let isMultiple = targets.count > 1

        Button {
            store.refreshFeeds(ids: targets)
        } label: {
            Text(isMultiple ? "Refresh \(targets.count) Feeds" : "Refresh Feed")
        }

        Button {
            store.markFeedsRead(ids: targets)
        } label: {
            Text(isMultiple ? "Mark \(targets.count) Feeds as Read" : "Mark Feed as Read")
        }

        if isMultiple {
            Button("Open Site") {}
                .disabled(true)
        } else {
            Link("Open Site", destination: feed.siteURL)
        }

        Menu("Move to Folder") {
            Button("None") {
                targets.forEach { store.moveFeed($0, toFolder: "") }
            }
            if !store.feedFolders.isEmpty {
                Divider()
                ForEach(store.feedFolders, id: \.self) { folder in
                    Button(folder) {
                        targets.forEach { store.moveFeed($0, toFolder: folder) }
                    }
                }
            }
        }

        Divider()

        Button(role: .destructive) {
            store.removeFeeds(ids: targets)
        } label: {
            Text(isMultiple ? "Remove \(targets.count) Feeds" : "Remove Feed")
        }
    }
}

private struct SyncFolderFooter: View {
    @Bindable var store: ReaderStore
    var onChoose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Divider()

            Button(action: onChoose) {
                HStack(spacing: 8) {
                    Image(systemName: store.isStorageConfigured ? "checkmark.icloud" : "icloud")
                        .foregroundStyle(store.isStorageConfigured ? Color.secondary : Color.accentColor)
                        .imageScale(.large)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(store.isStorageConfigured ? "Sync Folder" : "Choose iCloud Folder")
                            .font(.callout)

                        if let name = store.syncFolderName {
                            Text(name)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }

                    Spacer(minLength: 0)

                    Image(systemName: "chevron.right")
                        .imageScale(.small)
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(SidebarActionButtonStyle())
            // Full path is intentionally hidden; it reveals as a native tooltip on hover.
            .help(store.syncFolderDisplayPath ?? String(localized: "Choose iCloud Sync Folder"))
            .padding(6)
        }
        .background(.bar)
    }
}

/// A sidebar footer button style with native hover and pressed highlights so
/// the control clearly reads as tappable.
private struct SidebarActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration)
    }

    private struct Row: View {
        let configuration: ButtonStyleConfiguration
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(fillColor)
                )
                .onHover { isHovering = $0 }
                .animation(.easeOut(duration: 0.12), value: isHovering)
                .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
        }

        private var fillColor: Color {
            if configuration.isPressed { return Color.primary.opacity(0.14) }
            if isHovering { return Color.primary.opacity(0.07) }
            return .clear
        }
    }
}

private struct SourceRow: View {
    var title: String
    var subtitle: String?
    var systemImage: String
    var iconImage: Image?
    var isUnhealthy: Bool
    var count: Int

    init(title: String, subtitle: String? = nil, systemImage: String, iconImage: Image? = nil, isUnhealthy: Bool = false, count: Int) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.iconImage = iconImage
        self.isUnhealthy = isUnhealthy
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

                if isUnhealthy {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .help("Last refresh failed.")
                }

                if count > 0 {
                    Text(count, format: .number)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        } icon: {
            if let iconImage {
                iconImage
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 16, height: 16)
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            } else {
                Image(systemName: systemImage)
            }
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
                            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                Button {
                                    store.setRead(articleID: article.id, isRead: !article.isRead)
                                } label: {
                                    Label(
                                        article.isRead ? "Mark as Unread" : "Mark as Read",
                                        systemImage: article.isRead ? "circle" : "checkmark.circle.fill"
                                    )
                                }
                                .tint(.accentColor)

                                Button {
                                    store.toggleStarred(articleID: article.id)
                                } label: {
                                    Label(
                                        article.isStarred ? "Remove Star" : "Star",
                                        systemImage: article.isStarred ? "star.slash.fill" : "star.fill"
                                    )
                                }
                                .tint(.yellow)
                            }
                    }
                }
                .listStyle(.inset)
            }
        }
        // The source is shown by the toolbar breadcrumb instead, so no column
        // title here (avoids duplicating it in the toolbar).
        .searchable(text: $store.searchText, placement: .toolbar, prompt: "Search Articles")
        .safeAreaInset(edge: .bottom) {
            ArticleListStatusBar(store: store)
        }
        .onChange(of: store.feedSelection) { _, _ in
            store.clearRetainedArticles()
            store.selectFirstVisibleArticleIfNeeded()
        }
        .onChange(of: store.smartSelection) { _, _ in
            store.clearRetainedArticles()
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
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Circle()
                .fill(article.isRead ? Color.clear : Color.accentColor)
                .frame(width: 8, height: 8)
                .alignmentGuide(.firstTextBaseline) { dimension in
                    dimension[VerticalAlignment.center] + 3
                }

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
        HStack(spacing: 8) {
            if store.isRefreshing {
                ProgressView()
                    .controlSize(.small)
                Text("Refreshing")
            } else if let errorMessage = store.errorMessage {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(errorMessage)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else {
                Text("\(store.unreadCount()) unread")
            }

            Spacer(minLength: 0)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(.bar)
    }
}

/// Makes the large reader title read as an interactive control: it tints to
/// the accent color and shows a pointer on hover, and dims while pressed.
private struct ReaderTitleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Title(configuration: configuration)
    }

    private struct Title: View {
        let configuration: ButtonStyleConfiguration
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .foregroundStyle(isHovering ? Color.accentColor : Color.primary)
                .opacity(configuration.isPressed ? 0.55 : 1)
                .contentShape(Rectangle())
                .onHover { hovering in
                    isHovering = hovering
                    if hovering {
                        NSCursor.pointingHand.push()
                    } else {
                        NSCursor.pop()
                    }
                }
                .onDisappear { if isHovering { NSCursor.pop() } }
                .animation(.easeOut(duration: 0.12), value: isHovering)
                .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
        }
    }
}

/// A native, Xcode-jump-bar-style breadcrumb shown at the top of the window
/// (toolbar), reflecting the current location: Source › Feed › Article. The
/// feed segment jumps to that feed.
private struct WindowBreadcrumb: View {
    @Bindable var store: ReaderStore

    @State private var edges = BreadcrumbEdges(leading: false, trailing: false)
    @State private var isHovered = false

    var body: some View {
        if store.isStorageConfigured {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    Text(store.selectedSourceTitle)
                        .foregroundStyle(.secondary)
                        .fixedSize()

                    if let article = store.selectedArticle {
                        if let feed = store.feed(for: article.feedID), store.feedSelection != [article.feedID] {
                            chevron
                            MiddleCrumbSegment(
                                title: feed.title,
                                icon: store.faviconImage(for: feed),
                                breadcrumbHovered: isHovered
                            ) {
                                store.feedSelection = [feed.id]
                            }
                        }

                        chevron

                        Text(article.title)
                            .foregroundStyle(.primary)
                            .fixedSize()
                    }
                }
                .padding(.horizontal, 12)
            }
            .scrollIndicators(.never)
            .font(.callout)
            .frame(maxWidth: 520)
            .onScrollGeometryChange(for: BreadcrumbEdges.self) { geometry in
                let maxOffset = max(0, geometry.contentSize.width - geometry.containerSize.width)
                return BreadcrumbEdges(
                    leading: geometry.contentOffset.x > 1,
                    trailing: geometry.contentOffset.x < maxOffset - 1
                )
            } action: { _, newEdges in
                edges = newEdges
            }
            // Fade only the edge(s) where content is actually clipped, hinting
            // there is more to scroll to.
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: edges.leading ? 0.06 : 0),
                        .init(color: .black, location: edges.trailing ? 0.94 : 1),
                        .init(color: .clear, location: 1)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .onHover { hovering in
                isHovered = hovering
            }
        }
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.caption2)
            .foregroundStyle(.tertiary)
    }
}

private struct BreadcrumbEdges: Equatable {
    var leading: Bool
    var trailing: Bool
}

/// A middle breadcrumb segment: capped to a max width with a trailing fade
/// when its text is too long, and expanding to its full text (fade removed)
/// while hovered.
private struct MiddleCrumbSegment: View {
    let title: String
    let icon: Image?
    let breadcrumbHovered: Bool
    var action: () -> Void

    private let collapsedMaxWidth: CGFloat = 150

    // Expands when hovered and stays expanded until the pointer leaves the
    // whole breadcrumb (breadcrumbHovered turns false).
    @State private var expanded = false
    @State private var intrinsicWidth: CGFloat = 0

    private var isTruncated: Bool { intrinsicWidth > collapsedMaxWidth + 0.5 }
    private var showsFade: Bool { isTruncated && !expanded }

    var body: some View {
        Button(action: action) {
            content()
                .lineLimit(1)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .background(alignment: .leading) {
            content()
                .fixedSize()
                .hidden()
                .background(
                    GeometryReader { geometry in
                        Color.clear.preference(key: CrumbWidthKey.self, value: geometry.size.width)
                    }
                )
        }
        .onPreferenceChange(CrumbWidthKey.self) { intrinsicWidth = $0 }
        .frame(maxWidth: (expanded || !isTruncated) ? nil : collapsedMaxWidth, alignment: .leading)
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black, location: showsFade ? 0.78 : 1),
                    .init(color: showsFade ? .clear : .black, location: 1)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
        .onHover { isHovered in
            if isHovered {
                withAnimation(.easeOut(duration: 0.2)) { expanded = true }
            }
        }
        .onChange(of: breadcrumbHovered) { _, hovering in
            if !hovering {
                withAnimation(.easeOut(duration: 0.2)) { expanded = false }
            }
        }
    }

    private func content() -> some View {
        HStack(spacing: 4) {
            if let icon {
                icon
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 13, height: 13)
                    .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
            }
            Text(title)
        }
    }
}

private struct CrumbWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct ReaderDetailView: View {
    @Bindable var store: ReaderStore
    @Environment(\.openURL) private var openURL
    @State private var webReaderArticleID: Article.ID?
    @AppStorage("markReadOnOpen") private var markReadOnOpen = true
    @AppStorage("markReadDelaySeconds") private var markReadDelaySeconds = 3

    var body: some View {
        Group {
            if !store.isStorageConfigured {
                ContentUnavailableView {
                    Label("Set Up iCloud Sync", systemImage: "icloud.and.arrow.up")
                } description: {
                    Text("Choose a folder in iCloud Drive and Nook keeps your feeds in sync across your devices.")
                }
            } else if let article = store.selectedArticle {
                articleReader(article)
                    .overlay {
                        if webReaderArticleID == article.id {
                            webReader(article)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
            } else {
                ContentUnavailableView {
                    Label("Select an Article", systemImage: "newspaper")
                } description: {
                    Text("Choose a story from the article list.")
                }
            }
        }
        .onChange(of: store.selectedArticleID) { _, _ in
            webReaderArticleID = nil
        }
    }

    private func articleReader(_ article: Article) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                articleHeader(article)

                Divider()

                if let html = article.contentHTML {
                    HTMLContentText(html: html)
                } else {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(article.bodyParagraphs, id: \.self) { paragraph in
                            Text(paragraph)
                                .font(.body)
                                .lineSpacing(4)
                                .textSelection(.enabled)
                        }
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
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .task(id: article.id) {
            await markReadAfterDwell(article)
        }
    }

    private func webReader(_ article: Article) -> some View {
        ArticleWebView(url: article.url)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
            .overlay(alignment: .topLeading) {
                floatingReaderButton(systemImage: "xmark", label: "Close Reader") {
                    closeWebReader()
                }
                .keyboardShortcut("w", modifiers: .command)
                .padding(16)
            }
            .overlay(alignment: .topTrailing) {
                HStack(spacing: 10) {
                    floatingReaderButton(systemImage: "safari", label: "Open Original") {
                        openURL(article.url)
                    }

                    ShareLink(item: article.url) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 30, height: 30)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .background(.regularMaterial, in: Circle())
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.12)))
                    .shadow(color: .black.opacity(0.15), radius: 5, y: 1)
                    .help("Share")
                }
                .padding(16)
            }
            .task(id: article.id) {
                // Opening the full reader mode is an explicit "I'm reading
                // this" action, so mark it read immediately.
                store.retainArticle(id: article.id)
                if markReadOnOpen {
                    store.markArticleOpened(articleID: article.id)
                }
            }
    }

    private func floatingReaderButton(systemImage: String, label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 30, height: 30)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .background(.regularMaterial, in: Circle())
        .overlay(Circle().strokeBorder(Color.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.15), radius: 5, y: 1)
        .help(label)
    }

    private func closeWebReader() {
        withAnimation(.easeInOut(duration: 0.28)) {
            webReaderArticleID = nil
        }
    }

    /// Keeps the article visible while reading, then marks it read only after
    /// the user dwells for the configured delay. Navigating away cancels this
    /// task before the delay elapses, so the article stays unread.
    private func markReadAfterDwell(_ article: Article) async {
        store.retainArticle(id: article.id)
        guard markReadOnOpen else { return }

        do {
            if markReadDelaySeconds > 0 {
                try await Task.sleep(for: .seconds(Double(markReadDelaySeconds)))
            } else {
                await Task.yield()
            }
            store.markArticleOpened(articleID: article.id)
        } catch {
            // Cancelled before the dwell completed — leave it unread.
        }
    }

    /// Hides the standfirst summary when it merely repeats the body, which
    /// happens for feeds that only ship a short description.
    private func shouldShowSummary(_ article: Article) -> Bool {
        let summary = article.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else { return false }
        let firstParagraph = article.bodyParagraphs.first?.trimmingCharacters(in: .whitespacesAndNewlines)
        return summary != firstParagraph
    }

    private func articleHeader(_ article: Article) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                if let feed = store.feed(for: article.feedID) {
                    Label {
                        Text(feed.title)
                    } icon: {
                        if let icon = store.faviconImage(for: feed) {
                            icon
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 14, height: 14)
                                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                        } else {
                            Image(systemName: feed.systemImage)
                        }
                    }
                }

                Text("·")

                Text(article.publishedAt.formatted(date: .abbreviated, time: .shortened))

                Text("·")

                Text("\(article.estimatedReadMinutes) min read")
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            Button {
                if NSEvent.modifierFlags.contains(.command) {
                    openURL(article.url)
                } else {
                    withAnimation(.easeInOut(duration: 0.28)) {
                        webReaderArticleID = article.id
                    }
                }
            } label: {
                Text(article.title)
                    .font(.system(.largeTitle, design: .serif))
                    .fontWeight(.semibold)
                    .lineLimit(nil)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(ReaderTitleButtonStyle())
            .help("Open in Reader — ⌘-click to open in browser")

            if shouldShowSummary(article) {
                Text(article.summary)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
            }

            HStack(spacing: 10) {
                Button {
                    store.toggleStarred(articleID: article.id)
                } label: {
                    Label(article.isStarred ? "Starred" : "Star", systemImage: article.isStarred ? "star.fill" : "star")
                }
            }
            .buttonStyle(.bordered)
        }
    }
}

/// Renders HTML feed content natively via the AppKit text system (no web
/// view), normalizing fonts and colors to match the app.
private struct HTMLContentText: View {
    let html: String
    @State private var attributed: AttributedString?

    var body: some View {
        Group {
            if let attributed {
                Text(attributed)
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .tint(.accentColor)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: html) {
            attributed = Self.render(html)
        }
    }

    private static func render(_ html: String) -> AttributedString? {
        guard let data = html.data(using: .utf8) else { return nil }

        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue
        ]
        guard let mutable = try? NSMutableAttributedString(data: data, options: options, documentAttributes: nil) else {
            return nil
        }

        let fullRange = NSRange(location: 0, length: mutable.length)
        let baseSize = NSFont.preferredFont(forTextStyle: .body).pointSize

        // Replace the HTML importer's default fonts with the system font while
        // preserving bold/italic emphasis.
        mutable.enumerateAttribute(.font, in: fullRange, options: []) { value, range, _ in
            let existingTraits = (value as? NSFont)?.fontDescriptor.symbolicTraits ?? []
            var traits: NSFontDescriptor.SymbolicTraits = []
            if existingTraits.contains(.bold) { traits.insert(.bold) }
            if existingTraits.contains(.italic) { traits.insert(.italic) }
            let descriptor = NSFont.systemFont(ofSize: baseSize).fontDescriptor.withSymbolicTraits(traits)
            let font = NSFont(descriptor: descriptor, size: baseSize) ?? NSFont.systemFont(ofSize: baseSize)
            mutable.addAttribute(.font, value: font, range: range)
        }

        // Keep link runs their own color; make everything else adapt to light/dark.
        mutable.enumerateAttribute(.link, in: fullRange, options: []) { link, range, _ in
            if link == nil {
                mutable.addAttribute(.foregroundColor, value: NSColor.labelColor, range: range)
            }
        }

        return try? AttributedString(mutable, including: \.appKit)
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
                Text("Paste an RSS or Atom feed URL and Nook will fetch it right away.")
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

private struct OPMLImportRequest: Identifiable {
    let id = UUID()
    let feeds: [OPMLFeed]
}

/// A native import preview: pick which OPML feeds to bring in before merging.
/// Styled to match the main window (inset list + sections) rather than the
/// grouped Settings form.
private struct OPMLImportView: View {
    let feeds: [OPMLFeed]
    let existingKeys: Set<String>
    var onImport: ([OPMLFeed]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selection: Set<OPMLFeed.ID>
    @State private var icons: [OPMLFeed.ID: NSImage] = [:]
    private let faviconService = FaviconService()

    init(feeds: [OPMLFeed], existingKeys: Set<String>, onImport: @escaping ([OPMLFeed]) -> Void) {
        self.feeds = feeds
        self.existingKeys = existingKeys
        self.onImport = onImport
        // Default to the feeds that are not already subscribed.
        let isNew: (OPMLFeed) -> Bool = { feed in
            !(existingKeys.contains(feed.feedURL.feedIdentityKey)
                || (feed.siteURL.map { existingKeys.contains($0.feedIdentityKey) } ?? false))
        }
        _selection = State(initialValue: Set(feeds.filter(isNew).map(\.id)))
    }

    private func isExisting(_ feed: OPMLFeed) -> Bool {
        existingKeys.contains(feed.feedURL.feedIdentityKey)
            || (feed.siteURL.map { existingKeys.contains($0.feedIdentityKey) } ?? false)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            List {
                ForEach(groupedFeeds, id: \.category) { group in
                    Section(group.category ?? String(localized: "Ungrouped")) {
                        ForEach(group.feeds) { feed in
                            feedRow(feed)
                        }
                    }
                }
            }
            .listStyle(.inset)

            Divider()
            footer
        }
        .frame(minWidth: 560, idealWidth: 620, minHeight: 520, idealHeight: 640)
        .task {
            await loadIcons()
        }
    }

    /// Temporarily fetches site favicons just for the preview list (not cached
    /// to the sync folder; that happens when a feed is actually imported).
    private func loadIcons() async {
        await withTaskGroup(of: (OPMLFeed.ID, Data?).self) { group in
            for feed in feeds {
                let iconURL = feed.siteURL ?? feed.feedURL
                group.addTask {
                    (feed.id, await faviconService.fetchFavicon(for: iconURL))
                }
            }
            for await (id, data) in group {
                if let data, let image = NSImage(data: data) {
                    icons[id] = image
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Import Feeds")
                    .font(.headline)
                Text("Choose which feeds to import.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(allSelected ? "Deselect All" : "Select All") {
                selection = allSelected ? [] : Set(feeds.map(\.id))
            }
        }
        .padding(16)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text("\(selection.count) selected")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Spacer()

            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)

            Button("Import \(selection.count) Feeds") {
                onImport(feeds.filter { selection.contains($0.id) })
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(selection.isEmpty)
        }
        .padding(16)
        .background(.bar)
    }

    private var allSelected: Bool { selection.count == feeds.count }

    private var groupedFeeds: [(category: String?, feeds: [OPMLFeed])] {
        var order: [String?] = []
        var map: [String?: [OPMLFeed]] = [:]
        for feed in feeds {
            if map[feed.category] == nil { order.append(feed.category) }
            map[feed.category, default: []].append(feed)
        }
        return order.map { (category: $0, feeds: map[$0] ?? []) }
    }

    private func feedRow(_ feed: OPMLFeed) -> some View {
        Toggle(isOn: binding(for: feed)) {
            HStack(spacing: 8) {
                Group {
                    if let icon = icons[feed.id] {
                        Image(nsImage: icon)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    } else {
                        Image(systemName: "globe")
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(width: 16, height: 16)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(feed.title)
                            .lineLimit(1)
                        if isExisting(feed) {
                            Text("Already added")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.quaternary, in: Capsule())
                        }
                    }
                    Text(feed.feedURL.absoluteString)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
        }
        .toggleStyle(.checkbox)
    }

    private func binding(for feed: OPMLFeed) -> Binding<Bool> {
        Binding {
            selection.contains(feed.id)
        } set: { isOn in
            if isOn { selection.insert(feed.id) } else { selection.remove(feed.id) }
        }
    }
}

struct ReaderSettingsView: View {
    @AppStorage("autoRefreshEnabled") private var autoRefreshEnabled = true
    @AppStorage("refreshIntervalMinutes") private var refreshIntervalMinutes = 30
    @AppStorage("markReadOnOpen") private var markReadOnOpen = true
    @AppStorage("markReadDelaySeconds") private var markReadDelaySeconds = 3
    @AppStorage("openLinksInBrowser") private var openLinksInBrowser = true
    @AppStorage(AppLanguage.storageKey) private var appLanguage = AppLanguage.system
    @AppStorage(ReaderStorage.displayPathDefaultsKey) private var syncFolderDisplayPath = ""

    var body: some View {
        Form {
            Section("General") {
                Picker("Language", selection: $appLanguage) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.label).tag(language)
                    }
                }

                if appLanguage != AppLanguage.launchLanguage {
                    LabeledContent {
                        Button("Relaunch") { AppLanguage.relaunch() }
                    } label: {
                        Text("Restart Nook to apply the language change.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Reading") {
                Toggle("Mark articles as read when opened", isOn: $markReadOnOpen)
                Stepper("Mark as read after \(markReadDelaySeconds) seconds", value: $markReadDelaySeconds, in: 0...30)
                    .disabled(!markReadOnOpen)
                Toggle("Open original links in the default browser", isOn: $openLinksInBrowser)
            }

            Section("Feeds") {
                Toggle("Refresh feeds automatically", isOn: $autoRefreshEnabled)
                Stepper("Refresh every \(refreshIntervalMinutes) minutes", value: $refreshIntervalMinutes, in: 5...240, step: 5)
                    .disabled(!autoRefreshEnabled)
            }

            Section("Storage") {
                LabeledContent("Sync Folder", value: syncFolderDisplayPath.isEmpty ? String(localized: "Not selected") : syncFolderDisplayPath)
                Text("Nook keeps your feeds in a folder in iCloud Drive so they stay in sync across your devices.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 520)
        .onChange(of: appLanguage) { _, newValue in
            AppLanguage.apply(newValue)
        }
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
