import AppKit
import NaturalLanguage
import NookKit
import Observation
import SwiftUI
import Translation
import UniformTypeIdentifiers

struct ContentView: View {
    private static let sidebarVisibleKey = "sidebarVisible"

    @State private var store = ReaderStore.shared
    private let updateController = UpdateController.shared
    @State private var isAddingFeed = false
    @State private var isImportingOPML = false
    @State private var isExportingOPML = false
    @State private var opmlImport: OPMLImportRequest?
    @State private var imagePresenter = ArticleImagePresenter()
    @State private var columnVisibility: NavigationSplitViewVisibility
    @AppStorage("inspectorPresented") private var isInspectorPresented = true
    @AppStorage(ContentView.sidebarVisibleKey) private var sidebarVisible = true
    @AppStorage("autoRefreshEnabled") private var autoRefreshEnabled = true
    @AppStorage("refreshIntervalMinutes") private var refreshIntervalMinutes = 30
    @AppStorage("showUnreadBadge") private var showUnreadBadge = true

    // In-app browser (window-wide bottom sheet).
    @State private var browserDragOffset: CGFloat = 0
    @AppStorage("readerLinkBehavior") private var readerLinkBehavior = ReaderLinkBehavior.inApp
    @AppStorage("readerFont") private var readerFont = ReaderFont.system
    @AppStorage("readerFontSize") private var readerFontSize = 18
    @AppStorage("readerLineHeight") private var readerLineHeight = 1.7
    @AppStorage("readerLetterSpacing") private var readerLetterSpacing = 0.0
    @AppStorage("readerBackgroundOption") private var readerBackgroundOption = ReaderColorOption.automatic
    @AppStorage("readerBackgroundHex") private var readerBackgroundHex = "#FFFFFF"
    @AppStorage("readerTextOption") private var readerTextOption = ReaderColorOption.automatic
    @AppStorage("readerTextHex") private var readerTextHex = "#1A1A1A"

    private var readerStyle: ReaderStyle {
        ReaderStyle(
            font: readerFont,
            fontSize: readerFontSize,
            lineHeight: readerLineHeight,
            letterSpacing: readerLetterSpacing,
            backgroundOption: readerBackgroundOption,
            backgroundHex: readerBackgroundHex,
            textOption: readerTextOption,
            textHex: readerTextHex
        )
    }

    init() {
        // Restore the last sidebar state before the first render to avoid a flash.
        let wasVisible = UserDefaults.standard.object(forKey: ContentView.sidebarVisibleKey) as? Bool ?? true
        _columnVisibility = State(initialValue: wasVisible ? .all : .doubleColumn)
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            FeedSidebar(
                store: store,
                updateController: updateController,
                onChooseSyncFolder: { chooseSyncFolder() },
                onAddFeed: { isAddingFeed = true },
                onImportOPML: { isImportingOPML = true },
                onExportOPML: { isExportingOPML = true }
            )
            .navigationSplitViewColumnWidth(min: 220, ideal: 270, max: 340)
        } content: {
            ArticleListView(store: store)
                .navigationSplitViewColumnWidth(min: 340, ideal: 420, max: 540)
        } detail: {
            ReaderWorkspaceView(store: store, isInspectorPresented: $isInspectorPresented)
        }
        .articleImageOverlay(imagePresenter)
        .frame(minWidth: 920, minHeight: 640)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                // Add Feed, New Folder, and OPML import/export live in the
                // sidebar's bottom bar (the native place for library-management
                // actions); the toolbar keeps only the global Refresh.
                Button {
                    store.refreshAll()
                } label: {
                    Label("Refresh All", systemImage: "arrow.clockwise")
                }
                .disabled(store.feeds.isEmpty || store.isRefreshing)
                .help("Refresh All Feeds")
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
            AddFeedSheet(folders: store.feedFolders) { feedURL, folder in
                try await store.addFeed(urlString: feedURL, toFolder: folder)
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
        .task {
            // The store computes the unread count; macOS reflects it on the Dock.
            store.onUnreadBadgeChange = { count in
                NSApp.dockTile.badgeLabel = count > 0 ? String(count) : nil
            }
            // Mirror the badge preference into the store before loading, so the
            // first badge update (driven by the store) already respects it.
            store.showsUnreadBadge = showUnreadBadge
            await store.bootstrap()
            // Let the window paint the loaded library first, then kick off the
            // launch-time bursts (WebKit warm-up and the network refresh) so
            // their CPU/IO spike doesn't stall the first frames.
            try? await Task.sleep(for: .milliseconds(600))
            // Warm up WebKit so the first in-app browser opens without the
            // ~2-3s cold-start delay.
            WebViewWarmer.warmUp()
            // Sync on launch so the reader opens on fresh articles.
            if autoRefreshEnabled { store.refreshOnActivation(honorThrottle: false) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Pull another device's changes (read/star/feeds) from the sync
            // folder first, then refresh feeds over the network (throttled).
            store.syncFromDisk()
            if autoRefreshEnabled { store.refreshOnActivation(honorThrottle: true) }
        }
        // Periodic auto-refresh is driven app-wide by BackgroundRefreshController
        // (in NookApp) so it keeps running when the window is closed.
        .onChange(of: columnVisibility) { _, newValue in
            sidebarVisible = (newValue == .all)
        }
        .onOpenURL { url in
            if let raw = WidgetShared.smartSourceRaw(from: url), let source = SmartSource(rawValue: raw) {
                store.selectSmartSource(source)
            }
            // nook://open simply brings the app forward.
        }
        .overlay { browserOverlay }
        .onChange(of: store.isBrowserPresented) { _, presented in
            if presented {
                // Honor the selected article's feed preference, falling back to
                // the global default (advancing articles re-resolves this in the
                // store, so "next" follows the setting too).
                if let article = store.selectedArticle {
                    store.browserMode = store.resolvedBrowserMode(for: article)
                }
                browserDragOffset = 0
            }
        }
        .onChange(of: showUnreadBadge) { _, newValue in store.showsUnreadBadge = newValue }
        .focusedSceneValue(
            \.readerCommandActions,
            ReaderCommandActions(
                refreshAll: store.refreshAll,
                markSelectedRead: store.markSelectedRead,
                toggleSelectedStarred: store.toggleSelectedStarred,
                selectNextArticle: store.selectNextArticle,
                selectPreviousArticle: store.selectPreviousArticle,
                toggleReaderMode: store.toggleBrowserMode
            )
        )
    }

    /// The window-wide in-app browser bottom sheet, its dimmer, and the fixed
    /// drag grabber, shown when an article is opened in the browser.
    @ViewBuilder
    private var browserOverlay: some View {
        ZStack(alignment: .bottom) {
            if store.isBrowserPresented {
                Color.black
                    .opacity(max(0, 0.32 - browserDragOffset / 1400))
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { closeBrowser() }
                    .transition(.opacity)
            }

            if store.isBrowserPresented, let article = store.selectedArticle {
                InAppBrowserPanel(
                    store: store,
                    article: article,
                    style: readerStyle,
                    linkOpensInApp: readerLinkBehavior == .inApp,
                    dragOffset: $browserDragOffset,
                    onClose: closeBrowser
                )
                .transition(.move(edge: .bottom))
            }

            // Grabber lives outside the sheet (does not move with it) so its
            // drag gesture isn't cancelled as the sheet slides down.
            if store.isBrowserPresented {
                browserGrabber
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, 52)
                    .transition(.opacity)
            }
        }
        .animation(.spring(response: 0.38, dampingFraction: 0.85), value: store.isBrowserPresented)
        .allowsHitTesting(store.isBrowserPresented)
    }
}

private extension ContentView {
    func closeBrowser() {
        withAnimation(.easeInOut(duration: 0.28)) {
            store.isBrowserPresented = false
            browserDragOffset = 0
        }
    }

    /// The sheet's drag handle. Kept outside the sheet's `.offset` so the drag
    /// gesture's own view never moves — otherwise macOS cancels the in-flight
    /// gesture as the view slides, producing jitter.
    var browserGrabber: some View {
        Capsule()
            .fill(.quaternary)
            .frame(width: 38, height: 5)
            .frame(width: 160, height: 22)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .global)
                    .onChanged { value in browserDragOffset = max(0, value.translation.height) }
                    .onEnded { value in
                        if value.translation.height > 120 {
                            closeBrowser()
                        } else {
                            withAnimation(.easeOut(duration: 0.2)) { browserDragOffset = 0 }
                        }
                    }
            )
    }

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
    var updateController: UpdateController
    var onChooseSyncFolder: () -> Void
    var onAddFeed: () -> Void
    var onImportOPML: () -> Void
    var onExportOPML: () -> Void

    @AppStorage("collapsedFolders") private var collapsedFoldersData = Data()
    @State private var isCreatingFolder = false
    @State private var newFolderName = ""
    @State private var folderPendingDeletion: String?
    @State private var folderPendingRename: String?
    @State private var renameFolderName = ""
    @State private var feedPendingRename: Feed.ID?
    @State private var renameFeedName = ""
    @State private var dropTargetFolder: String?
    @State private var isTopLevelDropTargeted = false
    /// Bumped on each action-bar tap to drive a haptic tick on Force Touch
    /// trackpads (a no-op elsewhere).
    @State private var actionFeedback = 0

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
            VStack(spacing: 0) {
                sidebarActionBar
                SyncFolderFooter(store: store, onChoose: onChooseSyncFolder)
                UpdateBanner(updateController: updateController)
            }
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
        .alert(
            "Rename Folder",
            isPresented: Binding(
                get: { folderPendingRename != nil },
                set: { if !$0 { folderPendingRename = nil } }
            ),
            presenting: folderPendingRename
        ) { folder in
            TextField("Folder Name", text: $renameFolderName)
            Button("Rename") { store.renameFolder(folder, to: renameFolderName) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Enter a new name for the folder.")
        }
        .alert(
            "Rename Feed",
            isPresented: Binding(
                get: { feedPendingRename != nil },
                set: { if !$0 { feedPendingRename = nil } }
            ),
            presenting: feedPendingRename
        ) { feedID in
            TextField("Feed Name", text: $renameFeedName)
            Button("Rename") { store.renameFeed(feedID, to: renameFeedName) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Enter a new name, or leave empty to use the feed's own name.")
        }
    }

    /// The library-management bar at the base of the sidebar — the native home
    /// (à la Xcode's navigator / Mail's mailbox list) for creating feeds and
    /// folders and importing/exporting subscriptions, kept out of the window
    /// toolbar so those global actions don't crowd the article toolbar.
    private var sidebarActionBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                // Primary action reads as a proper labeled macOS button (like
                // Reminders' "New List"), so it's unmistakably clickable.
                Button {
                    actionFeedback += 1
                    onAddFeed()
                } label: {
                    Label("Add Feed", systemImage: "plus")
                }
                // Allowed during a refresh: adding cancels the in-flight refresh
                // and re-runs it afterward (see ReaderStore.addFeed).
                .disabled(!store.isStorageConfigured)
                .help(store.isStorageConfigured ? "Add a feed" : "Choose a sync folder first")

                Spacer(minLength: 0)

                Button {
                    actionFeedback += 1
                    newFolderName = ""
                    isCreatingFolder = true
                } label: {
                    Image(systemName: "folder.badge.plus")
                }
                .help("New Folder")
                .disabled(!store.isStorageConfigured)

                Menu {
                    Button(action: onImportOPML) {
                        Label("Import OPML…", systemImage: "square.and.arrow.down")
                    }
                    .disabled(!store.isStorageConfigured || store.isRefreshing)

                    Button(action: onExportOPML) {
                        Label("Export OPML…", systemImage: "square.and.arrow.up")
                    }
                    .disabled(store.feeds.isEmpty)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Import or export subscriptions (OPML)")
            }
            // Liquid Glass controls: translucent glass shapes that react to
            // hover and press with the system's built-in interactive feedback,
            // at the standard macOS control size.
            .buttonStyle(.glass)
            .menuStyle(.button)
            .controlSize(.large)
            .sensoryFeedback(.levelChange, trigger: actionFeedback)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
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
            Button {
                renameFolderName = folder
                folderPendingRename = folder
            } label: {
                Text("Rename Folder…")
            }
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
            title: feed.displayTitle,
            subtitle: feed.siteDescription,
            systemImage: feed.systemImage,
            iconImage: store.faviconImage(for: feed),
            isRefreshing: store.isRefreshing(feedID: feed.id),
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

        if !isMultiple {
            Button {
                renameFeedName = feed.displayTitle
                feedPendingRename = feed.id
            } label: {
                Text("Rename Feed…")
            }
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

        Menu("Reading View") {
            readingViewChoice("Use Default", mode: nil, current: feed.preferredViewMode, targets: targets)
            Divider()
            readingViewChoice("Reader Mode", mode: .reader, current: feed.preferredViewMode, targets: targets)
            readingViewChoice("Original Page", mode: .original, current: feed.preferredViewMode, targets: targets)
        }

        Divider()

        Button(role: .destructive) {
            store.removeFeeds(ids: targets)
        } label: {
            Text(isMultiple ? "Remove \(targets.count) Feeds" : "Remove Feed")
        }
    }

    @ViewBuilder
    private func readingViewChoice(
        _ title: LocalizedStringKey,
        mode: ReaderViewMode?,
        current: ReaderViewMode?,
        targets: [Feed.ID]
    ) -> some View {
        Button {
            store.setPreferredViewMode(mode, feedIDs: targets)
        } label: {
            if current == mode {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
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

/// A quiet, non-modal "update available" chip pinned to the very bottom of the
/// sidebar, below the sync-folder footer. It only appears once a background
/// check finds an update and never interrupts the user. Tapping the chip opens
/// a small popover where the user can start the update (which hands off to
/// Sparkle's standard release-notes/install flow).
private struct UpdateBanner: View {
    let updateController: UpdateController
    @State private var showDetails = false

    var body: some View {
        if let version = updateController.pendingUpdateVersion {
            VStack(spacing: 0) {
                Divider()

                Button { showDetails = true } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down.circle.fill")
                            .imageScale(.small)
                        Text("Update available")
                            .fontWeight(.medium)
                        Spacer(minLength: 0)
                        Text(version)
                            .opacity(0.9)
                    }
                    .font(.caption)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .frame(maxWidth: .infinity)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 7))
                    .contentShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .help("A new version of Nook is available")
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .popover(isPresented: $showDetails, arrowEdge: .top) {
                    UpdatePopover(version: version, controller: updateController) {
                        showDetails = false
                    }
                }
            }
            .background(.bar)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

/// The tooltip-style popover shown when the update chip is tapped: version info
/// plus the actions. "Update" hands off to Sparkle's standard install flow.
private struct UpdatePopover: View {
    let version: String
    let controller: UpdateController
    var onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: "sparkles").foregroundStyle(.tint)
                Text("New Version Available").font(.headline)
            }

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    Text("Current").foregroundStyle(.secondary)
                    Text(controller.currentVersion)
                }
                GridRow {
                    Text("New").foregroundStyle(.secondary)
                    Text(version).fontWeight(.semibold)
                }
                if let date = controller.pendingUpdateDate {
                    GridRow {
                        Text("Released").foregroundStyle(.secondary)
                        Text(date.localized(date: .abbreviated, time: .omitted))
                    }
                }
            }
            .font(.callout)

            HStack {
                Button("Later") { onDismiss() }
                Spacer()
                Button("Update") {
                    onDismiss()
                    controller.checkForUpdates()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 260)
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
    var isRefreshing: Bool
    var isUnhealthy: Bool
    var count: Int

    init(
        title: String,
        subtitle: String? = nil,
        systemImage: String,
        iconImage: Image? = nil,
        isRefreshing: Bool = false,
        isUnhealthy: Bool = false,
        count: Int
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.iconImage = iconImage
        self.isRefreshing = isRefreshing
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
            ZStack {
                if isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .transition(.opacity.combined(with: .scale(scale: 0.85)))
                } else if let iconImage {
                    iconImage
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 16, height: 16)
                        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                } else {
                    Image(systemName: systemImage)
                        .frame(width: 16, height: 16)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .frame(width: 16, height: 16)
            .animation(.easeInOut(duration: 0.18), value: isRefreshing)
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
                    Text(store.activeSearchQuery.isEmpty ? "Add an RSS or Atom feed, then refresh." : "No article matches the current search.")
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
                .onKeyPress(.return) {
                    // Enter on the selected row opens the web view, mirroring a
                    // click on the reader's title.
                    guard store.selectedArticle != nil else { return .ignored }
                    withAnimation(.easeInOut(duration: 0.3)) {
                        store.isBrowserPresented = true
                    }
                    return .handled
                }
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
            store.pruneSelectionIfHidden()
        }
        .onChange(of: store.smartSelection) { _, _ in
            store.clearRetainedArticles()
            store.pruneSelectionIfHidden()
        }
        .onChange(of: store.searchText) { _, _ in
            store.debounceSearch()
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
                    Text(feed?.displayTitle ?? String(localized: "Unknown Feed"))
                    Text("·")
                    RelativeTimeText(article.publishedAt)
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
                                title: feed.displayTitle,
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
    private let fadeInset: CGFloat = 18

    // Expands when hovered and stays expanded until the pointer leaves the
    // whole breadcrumb (breadcrumbHovered turns false).
    @State private var expanded = false
    @State private var intrinsicWidth: CGFloat = 0

    private var isTruncated: Bool { intrinsicWidth > collapsedMaxWidth + 0.5 }

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
        // The in-flow width is constant (capped when truncated), so expanding
        // never shifts the following segments.
        .frame(maxWidth: isTruncated ? collapsedMaxWidth : nil, alignment: .leading)
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black, location: isTruncated ? 0.78 : 1),
                    .init(color: isTruncated ? .clear : .black, location: 1)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
        // On hover, reveal the full text as a floating pill overlaid on top of
        // the following segments — no layout shift. The pill's width unfurls
        // from the collapsed cap to full, with the trailing fade receding as
        // more text is revealed.
        .overlay(alignment: .leading) {
            if isTruncated {
                let full = intrinsicWidth + fadeInset
                let revealWidth = expanded ? full : collapsedMaxWidth
                content()
                    .fixedSize()
                    .foregroundStyle(.secondary)
                    .frame(width: revealWidth, alignment: .leading)
                    .clipped()
                    .mask(
                        LinearGradient(
                            stops: [
                                .init(color: .black, location: 0),
                                .init(color: .black, location: max(0, (revealWidth - fadeInset) / revealWidth)),
                                .init(color: .clear, location: 1)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    // Match the toolbar surface so the pill blends in; the
                    // shadow alone lifts it off the bar.
                    .background(.bar, in: Capsule())
                    .shadow(color: .black.opacity(expanded ? 0.22 : 0), radius: 7, y: 1)
                    .offset(x: -8)
                    .opacity(expanded ? 1 : 0)
                    .allowsHitTesting(false)
            }
        }
        .zIndex(expanded ? 1 : 0)
        .onHover { isHovered in
            if isHovered {
                withAnimation(.easeOut(duration: 0.18)) { expanded = true }
            }
        }
        .onChange(of: breadcrumbHovered) { _, hovering in
            if !hovering {
                withAnimation(.easeOut(duration: 0.18)) { expanded = false }
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

/// A window-wide in-app browser presented as a bottom sheet (à la the iOS Mail
/// compose sheet): a rounded card that slides up from the bottom of the window,
/// with a grabber, and is dragged down to dismiss.
private struct InAppBrowserPanel: View {
    @Bindable var store: ReaderStore
    let article: Article
    let style: ReaderStyle
    let linkOpensInApp: Bool
    @Binding var dragOffset: CGFloat
    var onClose: () -> Void

    @Environment(\.openURL) private var openURL
    @AppStorage("markReadOnOpen") private var markReadOnOpen = true
    @AppStorage(AppLanguage.storageKey) private var appLanguage = AppLanguage.system
    @State private var loadingProgress: Double = 0
    @State private var bottomPull: CGFloat = 0
    @State private var isTranslationOn = false
    @State private var translationInFlight = false

    private var targetLanguage: Locale.Language {
        (appLanguage == .system ? Locale.current : appLanguage.locale).language
    }

    private var targetLanguageName: String {
        let code = targetLanguage.languageCode?.identifier ?? "en"
        return Locale(identifier: "en_US").localizedString(forLanguageCode: code) ?? code
    }

    /// Web-view translation uses Apple Intelligence in place; offer it only when
    /// that's available and the article's language differs from the app's.
    private var canTranslate: Bool {
        guard NaturalTranslator.isAvailable,
              let detected = ReaderDetailView.detectLanguage(for: article),
              let target = targetLanguage.languageCode?.identifier else { return false }
        return detected != target
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            WebLoadingBar(progress: loadingProgress)
            Divider()
            ArticleWebView(
                url: article.url,
                useReaderMode: store.browserMode == .reader,
                style: style,
                linkOpensInApp: linkOpensInApp,
                translate: isTranslationOn,
                translationLanguage: targetLanguageName,
                onTranslatingChange: { translationInFlight = $0 },
                onLoadingProgress: { loadingProgress = $0 },
                onOverscroll: { amount in
                    dragOffset = amount
                },
                onOverscrollEnded: { amount in
                    if amount > 140 {
                        onClose()
                    } else {
                        withAnimation(.easeOut(duration: 0.2)) { dragOffset = 0 }
                    }
                },
                onBottomOverscroll: { bottomPull = $0 },
                onBottomOverscrollEnded: handleBottomRelease
            )
            .id("\(article.id)|\(store.browserMode.rawValue)|\(style.identity)")
            .overlay(alignment: .bottom) {
                BottomPullAffordance(pull: bottomPull, nextTitle: store.article(after: article.id)?.title)
            }
            .overlay(alignment: .top) {
                if translationInFlight {
                    TranslationBanner()
                }
            }
            .animation(.easeInOut(duration: 0.2), value: translationInFlight)
        }
        .frame(maxWidth: 980)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        )
        .shadow(color: .black.opacity(0.3), radius: 30, y: 6)
        .padding(.top, 44)
        .padding(.horizontal, 20)
        .padding(.bottom, 14)
        .offset(y: max(0, dragOffset))
        .task(id: article.id) {
            store.retainArticle(id: article.id)
            if markReadOnOpen {
                store.markArticleOpened(articleID: article.id)
            }
        }
    }

    /// Decides what a bottom pull-up did on release: a short pull opens the next
    /// article, a longer pull closes the browser, otherwise it snaps back.
    private func handleBottomRelease(_ amount: CGFloat) {
        if amount >= BottomPullAffordance.closeThreshold {
            onClose()
        } else if amount >= BottomPullAffordance.nextThreshold {
            store.selectNextArticle()
            bottomPull = 0
        } else {
            withAnimation(.easeOut(duration: 0.2)) { bottomPull = 0 }
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
                Button { onClose() } label: {
                    Image(systemName: "xmark")
                }
                .keyboardShortcut("w", modifiers: .command)
                .help("Close")

                Spacer()

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { store.toggleBrowserMode() }
                } label: {
                    Label(
                        store.browserMode == .reader ? "Reader Mode" : "Original Page",
                        systemImage: store.browserMode == .reader ? "doc.plaintext" : "globe"
                    )
                }
                .help("Switch Reader / Original (⌘⇧F)")

                Spacer()

                if canTranslate {
                    Button {
                        isTranslationOn.toggle()
                    } label: {
                        Image(systemName: isTranslationOn ? "character.bubble.fill" : "character.bubble")
                    }
                    .help(isTranslationOn ? "Show Original Text" : "Translate")
                }

                Button { openURL(article.url) } label: {
                    Image(systemName: "safari")
                }
                .help("Open Original")

                ShareLink(item: article.url) {
                    Image(systemName: "square.and.arrow.up")
                }
                .help("Share")
            }
            .buttonStyle(.borderless)
        .padding(.top, 22)
        .padding(.bottom, 9)
        .padding(.horizontal, 14)
        .background(.bar)
    }
}

private struct ReaderDetailView: View {
    @Bindable var store: ReaderStore
    @Environment(\.openURL) private var openURL
    @AppStorage("markReadOnOpen") private var markReadOnOpen = true
    @AppStorage("markReadDelaySeconds") private var markReadDelaySeconds = 3
    @AppStorage(AppLanguage.storageKey) private var appLanguage = AppLanguage.system

    // Translation (Apple Intelligence). Rich (contentHTML) articles stream an
    // in-place translation preserving markup; plain-body articles fall back to a
    // whole-body translation.
    @State private var nativeTranslator = NativeArticleTranslator()
    @State private var detectedLanguage: String?
    @State private var translatedTitle: String?
    @State private var translatedBody: [String]?
    @State private var isTranslated = false
    @State private var isTranslating = false
    @State private var isShowingTranslation = false

    private var targetLanguage: Locale.Language {
        (appLanguage == .system ? Locale.current : appLanguage.locale).language
    }

    private var targetLanguageName: String {
        let code = targetLanguage.languageCode?.identifier ?? "en"
        return Locale(identifier: "en_US").localizedString(forLanguageCode: code) ?? code
    }

    /// Offer translation whenever the article's language differs from the target.
    /// Apple Intelligence is used when available; otherwise the button falls back
    /// to the system Translation overlay (so the button matches iOS and never
    /// silently disappears when Apple Intelligence is off/unsupported).
    private func canTranslate(_ article: Article) -> Bool {
        guard let detected = detectedLanguage,
              let target = targetLanguage.languageCode?.identifier else { return false }
        return detected != target
    }

    private static func translationText(for article: Article) -> String {
        ([article.title] + article.bodyParagraphs).joined(separator: "\n\n")
    }

    static func detectLanguage(for article: Article) -> String? {
        let sample = (article.bodyParagraphs.prefix(4).joined(separator: " ") + " " + article.title)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sample.isEmpty else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        return recognizer.dominantLanguage?.rawValue
    }

    private func translationActive(_ article: Article) -> Bool {
        article.contentHTML != nil ? nativeTranslator.isActive : isTranslated
    }

    private var translationBusy: Bool {
        nativeTranslator.isTranslating || isTranslating
    }

    private func displayTitle(_ article: Article) -> String {
        if article.contentHTML != nil {
            return nativeTranslator.isActive ? (nativeTranslator.translatedTitle ?? article.title) : article.title
        }
        return isTranslated ? (translatedTitle ?? article.title) : article.title
    }

    /// Toggles translation: rich articles stream in place; plain-body articles
    /// translate the whole body once. A length guard keeps an "answered"
    /// imperative title from replacing the real one.
    private func toggleTranslation(_ article: Article) {
        if let html = article.contentHTML {
            if nativeTranslator.isActive {
                nativeTranslator.stop()
            } else if NaturalTranslator.isAvailable {
                nativeTranslator.start(html: html, baseURL: article.url, title: article.title, into: targetLanguageName)
            } else {
                isShowingTranslation = true
            }
            return
        }

        if isTranslated {
            isTranslated = false
            return
        }
        if translatedBody != nil {
            isTranslated = true
            return
        }
        guard NaturalTranslator.isAvailable else {
            isShowingTranslation = true
            return
        }
        isTranslating = true
        let body = article.bodyParagraphs
        let title = article.title
        let language = targetLanguageName
        Task {
            defer { isTranslating = false }
            guard
                let titleText = try? await NaturalTranslator.translate(title, into: language),
                let bodyText = try? await NaturalTranslator.translate(body.joined(separator: "\n\n"), into: language)
            else { return }
            let cleanedTitle = titleText.trimmingCharacters(in: .whitespacesAndNewlines)
            translatedTitle = cleanedTitle.count <= max(120, title.count * 4) ? cleanedTitle : title
            translatedBody = bodyText
                .components(separatedBy: "\n\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            isTranslated = true
        }
    }

    var body: some View {
        baseContent
    }

    @ViewBuilder
    private var baseContent: some View {
        if !store.isStorageConfigured {
            ContentUnavailableView {
                Label("Set Up iCloud Sync", systemImage: "icloud.and.arrow.up")
            } description: {
                Text("Choose a folder in iCloud Drive and Nook keeps your feeds in sync across your devices.")
            }
        } else if let article = store.selectedArticle {
            articleReader(article)
        } else {
            ContentUnavailableView {
                Label("Select an Article", systemImage: "newspaper")
            } description: {
                Text("Choose a story from the article list.")
            }
        }
    }

    private func articleReader(_ article: Article) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                articleHeader(article)

                Divider()

                if let html = article.contentHTML {
                    HTMLContentView(html: html, baseURL: article.url, translator: nativeTranslator)
                } else if isTranslated, let translatedBody {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(Array(translatedBody.enumerated()), id: \.offset) { _, paragraph in
                            Text(paragraph)
                                .font(.body)
                                .lineSpacing(4)
                                .textSelection(.enabled)
                        }
                    }
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
        .overlay(alignment: .top) {
            if translationBusy {
                TranslationBanner()
            }
        }
        .animation(.easeInOut(duration: 0.2), value: translationBusy)
        .translationPresentation(isPresented: $isShowingTranslation, text: Self.translationText(for: article))
        .task(id: article.id) {
            // Reset any prior translation and re-detect the language so the
            // Translate action is offered only when it differs from the target.
            nativeTranslator.stop()
            isTranslated = false
            translatedTitle = nil
            translatedBody = nil
            isShowingTranslation = false
            detectedLanguage = Self.detectLanguage(for: article)
            await markReadAfterDwell(article)
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
                        Text(feed.displayTitle)
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

                Text(article.publishedAt.localized(date: .abbreviated, time: .shortened))

                Text("·")

                Text("\(article.estimatedReadMinutes) min read")
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            Button {
                if NSEvent.modifierFlags.contains(.command) {
                    openURL(article.url)
                } else {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        store.isBrowserPresented = true
                    }
                }
            } label: {
                Text(displayTitle(article))
                    .font(.system(.largeTitle, design: .serif))
                    .fontWeight(.semibold)
                    .lineLimit(nil)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(ReaderTitleButtonStyle())
            .help("Open in Reader — ⌘-click to open in browser")

            if translationActive(article) {
                Label("Translated by Apple Intelligence", systemImage: "apple.intelligence")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

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

                if canTranslate(article) {
                    Button {
                        toggleTranslation(article)
                    } label: {
                        Label(
                            translationActive(article) ? "Show Original" : "Translate",
                            systemImage: translationActive(article) ? "character.bubble.fill" : "character.bubble"
                        )
                    }
                    .disabled(translationBusy)
                }
            }
            .buttonStyle(.bordered)
        }
    }
}

/// A small banner shown while an article translation streams in.
private struct TranslationBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Translating…")
                .font(.callout)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        .padding(.top, 12)
    }
}

/// Renders HTML feed content natively via the AppKit text system (no web
/// view), normalizing fonts and colors to match the app.
private struct ArticleInspector: View {
    @Bindable var store: ReaderStore

    var body: some View {
        Form {
            if let article = store.selectedArticle {
                Section("Article") {
                    LabeledContent("Status", value: article.isRead ? String(localized: "Read") : String(localized: "Unread"))
                    LabeledContent("Published", value: article.publishedAt.localized(date: .abbreviated, time: .shortened))
                    LabeledContent("Reading Time", value: String(localized: "\(article.estimatedReadMinutes) min"))

                    Toggle("Starred", isOn: store.starredBinding(articleID: article.id))
                    Toggle("Read", isOn: store.readBinding(articleID: article.id))
                }

                Section("Source") {
                    if let feed = store.feed(for: article.feedID) {
                        LabeledContent("Feed", value: feed.displayTitle)
                        LabeledContent("Category", value: feed.category)
                        LabeledContent("Last Refresh", value: feed.lastFetchedAt?.localized(date: .abbreviated, time: .shortened) ?? String(localized: "Never"))
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
    var folders: [String]
    var onAdd: (String, String) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var feedURL = ""
    @State private var folderChoice: FolderChoice = .topLevel
    @State private var newFolderName = ""
    @State private var isSubmitting = false
    @State private var submissionError: String?
    @FocusState private var isFocused: Bool

    private enum FolderChoice: Hashable {
        case topLevel
        case existing(String)
        case newFolder
    }

    private var trimmedFeedURL: String {
        feedURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedNewFolderName: String {
        newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var selectedFolder: String {
        switch folderChoice {
        case .topLevel:
            return ""
        case .existing(let folder):
            return folder
        case .newFolder:
            return trimmedNewFolderName
        }
    }

    private var canSubmit: Bool {
        !trimmedFeedURL.isEmpty
            && !isSubmitting
            && (folderChoice != .newFolder || !trimmedNewFolderName.isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Add Feed")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("Paste an RSS or Atom feed URL, or a website address. Nook will check it before closing.")
                    .foregroundStyle(.secondary)
            }

            TextField("https://example.com/feed.xml", text: $feedURL)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .disabled(isSubmitting)

            VStack(alignment: .leading, spacing: 8) {
                Text("Folder")
                    .font(.callout.weight(.semibold))
                Picker("Folder", selection: $folderChoice) {
                    Text("Top Level").tag(FolderChoice.topLevel)
                    ForEach(folders, id: \.self) { folder in
                        Text(folder).tag(FolderChoice.existing(folder))
                    }
                    Text("New Folder…").tag(FolderChoice.newFolder)
                }
                .labelsHidden()
                .pickerStyle(.menu)

                if folderChoice == .newFolder {
                    TextField("Folder Name", text: $newFolderName)
                        .textFieldStyle(.roundedBorder)
                }
            }

            Group {
                if isSubmitting {
                    Label {
                        Text("Checking RSS/Atom feed…")
                    } icon: {
                        ProgressView()
                    }
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.secondary)
                } else if let submissionError {
                    Label {
                        Text(submissionError)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.red)
                } else {
                    Text("Nook will only close after it finds a valid feed.")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            .frame(minHeight: 22, alignment: .leading)

            HStack {
                Spacer()

                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button {
                    addFeed()
                } label: {
                    if isSubmitting {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Checking…")
                        }
                    } else {
                        Text("Add")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit)
            }
        }
        .padding(24)
        .frame(width: 440)
        .task { isFocused = true }
        .onChange(of: feedURL) { _, _ in
            if submissionError != nil { submissionError = nil }
        }
        .onChange(of: folderChoice) { _, _ in
            if submissionError != nil { submissionError = nil }
        }
        .onChange(of: newFolderName) { _, _ in
            if submissionError != nil { submissionError = nil }
        }
    }

    private func addFeed() {
        guard canSubmit else { return }
        let feedURL = trimmedFeedURL
        let folder = selectedFolder
        isSubmitting = true
        submissionError = nil

        Task {
            do {
                try await onAdd(feedURL, folder)
                await MainActor.run {
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    submissionError = error.localizedDescription
                    isSubmitting = false
                }
            }
        }
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

/// The app's preferences window, laid out as a standard macOS multi-tab
/// Settings scene with grouped forms that match the main window's styling.
struct ReaderSettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            ReadingSettingsTab()
                .tabItem { Label("Reading", systemImage: "book") }
            ReaderSettingsTab()
                .tabItem { Label("Reader", systemImage: "textformat") }
            FeedsSettingsTab()
                .tabItem { Label("Feeds", systemImage: "dot.radiowaves.up.forward") }
            AboutSettingsTab()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 540, height: 430)
    }
}

private struct GeneralSettingsTab: View {
    @AppStorage(AppLanguage.storageKey) private var appLanguage = AppLanguage.system
    @AppStorage("showUnreadBadge") private var showUnreadBadge = true
    @Bindable private var updateController = UpdateController.shared

    var body: some View {
        Form {
            Section("Language") {
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

            Section("App Icon") {
                Toggle("Show unread count on app icon", isOn: $showUnreadBadge)
            }

            Section("Software Update") {
                Toggle("Automatically check for updates", isOn: $updateController.automaticallyChecksForUpdates)
                LabeledContent {
                    Button("Check Now") { updateController.checkForUpdates() }
                } label: {
                    Text("Nook checks quietly in the background and shows a notice in the sidebar when an update is ready.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: appLanguage) { _, newValue in
            AppLanguage.apply(newValue)
        }
    }
}

private struct ReadingSettingsTab: View {
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
        .formStyle(.grouped)
    }
}

private struct ReaderSettingsTab: View {
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
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
        .formStyle(.grouped)
    }
}

private struct FeedsSettingsTab: View {
    @Bindable private var store = ReaderStore.shared
    @AppStorage("autoRefreshEnabled") private var autoRefreshEnabled = true
    @AppStorage("refreshIntervalMinutes") private var refreshIntervalMinutes = 30
    @AppStorage(ReaderStore.resolveMissingDatesKey) private var resolveMissingDates = true
    @AppStorage(NewArticleNotifier.enabledKey) private var newArticleNotifications = false
    @AppStorage(ReaderStorage.displayPathDefaultsKey) private var syncFolderDisplayPath = ""

    private var sortedFeeds: [Feed] {
        store.feeds.sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    var body: some View {
        Form {
            Section {
                Toggle("Refresh feeds automatically", isOn: $autoRefreshEnabled)
                Stepper("Refresh every \(refreshIntervalMinutes) minutes", value: $refreshIntervalMinutes, in: 5...240, step: 5)
                    .disabled(!autoRefreshEnabled)
                Toggle("Notify me about new articles", isOn: $newArticleNotifications)
                    .disabled(!autoRefreshEnabled)
                    .onChange(of: newArticleNotifications) { _, enabled in
                        if enabled {
                            Task { await NewArticleNotifier.requestAuthorizationIfNeeded() }
                        }
                    }
                Toggle("Fill in missing article dates", isOn: $resolveMissingDates)
            } header: {
                Text("Feeds")
            } footer: {
                Text("Some feeds omit each article's date. When enabled, Nook reads the real date from the article's page (once per article).")
            }

            Section {
                if sortedFeeds.isEmpty {
                    Text("No feeds yet. Add feeds from the main window.")
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
                Text("Choose how each feed's articles open in the web view. “Default” follows the reader setting in the Reader tab.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Sync Folder", value: syncFolderDisplayPath.isEmpty ? String(localized: "Not selected") : syncFolderDisplayPath)
            } header: {
                Text("Storage")
            } footer: {
                Text("Nook keeps your feeds in a folder in iCloud Drive so they stay in sync across your devices.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func viewModeBinding(for feed: Feed) -> Binding<ReaderViewMode?> {
        Binding(
            get: { store.feed(for: feed.id)?.preferredViewMode },
            set: { store.setPreferredViewMode($0, feedIDs: [feed.id]) }
        )
    }
}

private struct AboutSettingsTab: View {
    private var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0" }
    private var build: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1" }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            VStack(spacing: 10) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .frame(width: 96, height: 96)

                Text("Nook")
                    .font(.title)
                    .fontWeight(.semibold)

                Text("A native RSS reader for macOS.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Text("Version \(version) (\(build))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 0)

            VStack(spacing: 6) {
                Button {
                    FeedbackMailer.compose()
                } label: {
                    Label("Send Feedback…", systemImage: "envelope")
                }
                .controlSize(.large)

                Text("Report a bug, request a feature, or share an idea with the developer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Link(destination: URL(string: "https://github.com/selenehyun/nook")!) {
                    Label {
                        Text(verbatim: "GitHub")
                    } icon: {
                        Image("GitHubMark").renderingMode(.template)
                    }
                }
                .buttonStyle(.link)
                .padding(.top, 4)
            }
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 40)
    }
}

/// Opens the user's default mail app with a pre-filled feedback message
/// addressed to the developer. Subject/body follow the app's current language.
enum FeedbackMailer {
    static let recipient = "rationlunas@gmail.com"

    @MainActor
    static func compose() {
        guard let url = mailtoURL() else { return }
        NSWorkspace.shared.open(url)
    }

    private static func mailtoURL() -> URL? {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let osString = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"

        let subject = String(localized: "Nook Feedback")
        let intro = String(localized: "Please describe your bug report, feature request, or idea below. Screenshots are welcome.")
        let prompts = String(localized: "• What were you trying to do?\n\n• What actually happened?\n\n• What did you expect instead?")
        let diagnosticsHeader = String(localized: "— Diagnostics (helps with troubleshooting; feel free to delete) —")
        let diagnostics = String(localized: "Nook \(version) (\(build)) · macOS \(osString)")
        let body = "\(intro)\n\n\(prompts)\n\n\n\(diagnosticsHeader)\n\(diagnostics)"

        // Encode everything except the mailto delimiters we add ourselves so
        // newlines become %0A and spaces %20 the way mail clients expect.
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&?=+")
        let encodedSubject = subject.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        let encodedBody = body.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        return URL(string: "mailto:\(recipient)?subject=\(encodedSubject)&body=\(encodedBody)")
    }
}

struct ReaderCommandActions {
    var refreshAll: @MainActor () -> Void
    var markSelectedRead: @MainActor () -> Void
    var toggleSelectedStarred: @MainActor () -> Void
    var selectNextArticle: @MainActor () -> Void
    var selectPreviousArticle: @MainActor () -> Void
    var toggleReaderMode: @MainActor () -> Void
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

            Divider()

            Button("Switch Reader / Original") {
                actions?.toggleReaderMode()
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .disabled(actions == nil)
        }

        CommandGroup(after: .help) {
            Button("Send Feedback…") { FeedbackMailer.compose() }
        }
    }
}

#Preview {
    ContentView()
}
