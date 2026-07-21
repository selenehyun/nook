import NookKit
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

/// The iOS reader UI. Reuses the shared `ReaderStore` from NookKit; only the
/// presentation differs from the macOS app.
///
/// The shell branches on horizontal size class: compact width (iPhone portrait)
/// opens straight into a bottom `TabView` (Home / Feeds / Starred / Settings);
/// regular width (iPad) keeps the three-column `NavigationSplitView`.
struct RootView: View {
    @Bindable private var store = ReaderStore.shared
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @AppStorage("autoRefreshEnabled") private var autoRefreshEnabled = true
    @AppStorage("showUnreadBadge") private var showUnreadBadge = true
    @AppStorage("markReadOnOpen") private var markReadOnOpen = true
    @AppStorage("markReadDelaySeconds") private var markReadDelaySeconds = 3
    @AppStorage(BackgroundRefresh.enabledKey) private var newArticleNotifications = false
    @State private var isReady = false

    var body: some View {
        ZStack {
            shell
                .task {
                    // The store computes the unread count; iOS reflects it on the
                    // app icon badge (requires notification authorization).
                    store.onUnreadBadgeChange = { count in
                        UNUserNotificationCenter.current().setBadgeCount(count)
                    }
                    store.showsUnreadBadge = showUnreadBadge
                    // Cold launch is foreground; `scenePhase`'s onChange doesn't fire
                    // for the initial value, so set active here or the on-screen list
                    // would never be marked "seen" until the first background→active
                    // cycle.
                    store.setForegroundActive(true)
                    // Warm up WebKit well after launch — off the critical path so its
                    // WebContent process (and the noisy system logs it emits) spin up
                    // once the app is settled, not during launch. Independent task with
                    // its own timer so the delay is measured from launch, still ahead
                    // of the user's first article tap. Idempotent, so a tap that beats
                    // it is fine.
                    Task {
                        try? await Task.sleep(for: .seconds(6))
                        WebViewWarmer.warmUp()
                    }
                    await store.bootstrap()
                    // Keep the splash up while the nest assembles and the wordmark
                    // appears, then reveal the loaded UI.
                    try? await Task.sleep(for: .milliseconds(1850))
                    withAnimation(.easeOut(duration: 0.35)) { isReady = true }
                    // Ask for notification permission after the UI is shown (so the
                    // prompt doesn't cover the splash), only for the features in use.
                    await requestNotificationAuthorizationIfNeeded()
                    BackgroundRefresh.schedule()
                }
                .onChange(of: showUnreadBadge) { _, newValue in
                    store.showsUnreadBadge = newValue
                    if newValue { Task { await requestNotificationAuthorizationIfNeeded() } }
                }
                .onChange(of: newArticleNotifications) { _, enabled in
                    if enabled {
                        Task { await requestNotificationAuthorizationIfNeeded() }
                        BackgroundRefresh.schedule()
                    } else {
                        BackgroundRefresh.cancel()
                    }
                }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        // Returning to the foreground: pull another device's changes
                        // from the sync folder, then refresh feeds over the network.
                        // Foreground-active marks the on-screen list "seen" so its
                        // articles don't fire a background notification later.
                        store.setForegroundActive(true)
                        store.setSyncObservationActive(true)
                        store.syncFromDisk()
                        // In the app now: clear any lingering "new articles" banner.
                        NewArticleNotifier.clearDelivered()
                        if autoRefreshEnabled { store.refreshOnActivation(honorThrottle: true) }
                    case .background:
                        // Queue the next background refresh as we leave.
                        store.setForegroundActive(false)
                        store.setSyncObservationActive(false)
                        BackgroundRefresh.schedule()
                    case .inactive:
                        store.setForegroundActive(false)
                    default:
                        break
                    }
                }
                .onOpenURL { url in handleIncomingURL(url) }
                // Mark-read dwell lives here on the always-present root, keyed on the
                // selected article, so it isn't cancelled by the detail column being
                // pushed/popped in the collapsed split view (iPad) or a tab's
                // navigation stack (iPhone).
                .task(id: store.selectedArticleID) {
                    guard let id = store.selectedArticleID else { return }
                    store.retainArticle(id: id)
                    guard markReadOnOpen else { return }
                    do {
                        if markReadDelaySeconds > 0 {
                            try await Task.sleep(for: .seconds(Double(markReadDelaySeconds)))
                        } else {
                            await Task.yield()
                        }
                        store.markArticleOpened(articleID: id)
                    } catch {
                        // Navigated away before the dwell completed — leave it unread.
                    }
                }
                .alert(
                    "Something Went Wrong",
                    isPresented: Binding(
                        get: { store.errorMessage != nil },
                        set: { if !$0 { store.errorMessage = nil } }
                    ),
                    presenting: store.errorMessage
                ) { _ in
                    Button("OK", role: .cancel) { store.errorMessage = nil }
                } message: { message in
                    Text(message)
                }

            if !isReady {
                SplashView()
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        // Apply Nook's signature accent explicitly across both shells (iPhone tab
        // bar and iPad split view). The asset-catalog global accent alone didn't
        // take effect, so tint the whole app root here.
        .tint(Color("AccentColor"))
    }

    @ViewBuilder
    private var shell: some View {
        if horizontalSizeClass == .compact {
            CompactShell(store: store)
        } else {
            RegularShell(store: store)
        }
    }

    /// Requests notification authorization once, for either notification feature —
    /// the unread badge or new-article alerts.
    ///
    /// iOS shows the permission prompt only the first time, so we request the full
    /// set both features need (`alert`, `sound`, `badge`) up front. Requesting just
    /// `.badge` first (the badge is on by default) would spend the one-time prompt
    /// and permanently foreclose alerts — so later enabling new-article
    /// notifications could never get banner/sound authorization.
    private func requestNotificationAuthorizationIfNeeded() async {
        guard showUnreadBadge || newArticleNotifications else { return }

        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    /// Handles `nook://` deep links. `nook://add-feed?url=<page or feed URL>`
    /// (sent by the share extension) adds the feed, auto-discovering RSS/Atom.
    private func handleIncomingURL(_ url: URL) {
        guard url.scheme == "nook" else { return }
        guard url.host == "add-feed" else { return }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let feed = components.queryItems?.first(where: { $0.name == "url" })?.value,
              !feed.isEmpty else { return }
        Task {
            do {
                try await store.addFeed(urlString: feed)
            } catch {
                await MainActor.run {
                    store.errorMessage = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - Regular width (iPad) shell

/// The original three-column `NavigationSplitView` shell, unchanged. Owns the
/// sheet/importer state that the sidebar's ellipsis menu drives.
private struct RegularShell: View {
    @Bindable var store: ReaderStore

    /// A single file importer backs both the sync-folder picker and OPML import;
    /// stacking two `.fileImporter` modifiers on one view makes only one work.
    enum ImportKind { case folder, opml }
    @State private var importKind: ImportKind = .folder
    @State private var isImporting = false
    @State private var isAddingFeed = false
    @State private var isExportingOPML = false
    @State private var opmlImport: OPMLImportRequest?
    @State private var isCreatingFolder = false
    @State private var newFolderName = ""
    @State private var isShowingSettings = false

    var body: some View {
        NavigationSplitView {
            Sidebar(
                store: store,
                chooseFolder: { importKind = .folder; isImporting = true },
                importOPML: { importKind = .opml; isImporting = true },
                isAddingFeed: $isAddingFeed,
                isExportingOPML: $isExportingOPML,
                isCreatingFolder: $isCreatingFolder,
                isShowingSettings: $isShowingSettings
            )
        } content: {
            ArticleList(store: store, selection: $store.selectedArticleID)
        } detail: {
            ReaderDetailView(store: store)
        }
        .navigationSplitViewStyle(.balanced)
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: importKind == .folder ? [.folder] : [.opml, .xml],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            switch importKind {
            case .folder:
                _ = url.startAccessingSecurityScopedResource()
                store.configureSyncFolder(url)
            case .opml:
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
        .sheet(isPresented: $isAddingFeed) {
            AddFeedView(folders: store.feedFolders) { feedURL, folder in
                try await store.addFeed(urlString: feedURL, toFolder: folder)
            }
        }
        .sheet(isPresented: $isShowingSettings) {
            SettingsView(store: store)
        }
        .sheet(item: $opmlImport) { request in
            OPMLImportView(
                feeds: request.feeds,
                existingKeys: Set(store.feeds.flatMap { [$0.feedURL.feedIdentityKey, $0.siteURL.feedIdentityKey] })
            ) { selected in
                store.importFeeds(selected)
            }
        }
        .alert("New Folder", isPresented: $isCreatingFolder) {
            TextField("Folder Name", text: $newFolderName)
            Button("Cancel", role: .cancel) { newFolderName = "" }
            Button("Create") {
                let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty { store.createFolder(name) }
                newFolderName = ""
            }
        }
    }
}

// MARK: - Compact width (iPhone) shell

/// The selected tab. The shared store has one selection scope, so switching tabs
/// re-asserts the newly-active tab's scope (feeds/starred change
/// `feedSelection`/`smartSelection`, so returning to Home must restore its filter).
private enum AppTab: Hashable { case home, feeds, starred, settings }

/// A navigable source in the Feeds tab.
private enum FeedTarget: Hashable {
    case all
    case folder(String)
    case feed(Feed.ID)
}

/// The iPhone bottom-tab shell: Home (segmented Unread/Today/All), Feeds
/// (library), Starred, and Settings. The shared `ReaderStore` has a single
/// selection scope, so the shell re-asserts the active tab's scope whenever the
/// selected tab (or the Home filter / Feeds drill-down) changes.
private struct CompactShell: View {
    @Bindable var store: ReaderStore
    @State private var selection: AppTab = .home
    @State private var homeFilter: SmartSource = .unread
    @State private var feedsPath: [FeedTarget] = []

    var body: some View {
        TabView(selection: $selection) {
            HomeTab(store: store, filter: $homeFilter, goToSettings: { selection = .settings })
                .tabItem { Image(systemName: "house").accessibilityLabel(Text("Home")) }
                .badge(store.count(for: .unread))
                .tag(AppTab.home)

            FeedsTab(store: store, path: $feedsPath)
                .tabItem { Image(systemName: "list.bullet").accessibilityLabel(Text("Feeds")) }
                .tag(AppTab.feeds)

            StarredTab(store: store)
                .tabItem { Image(systemName: "star").accessibilityLabel(Text("Starred")) }
                .tag(AppTab.starred)

            SettingsView(store: store, isTab: true)
                .tabItem { Image(systemName: "gearshape").accessibilityLabel(Text("Settings")) }
                .tag(AppTab.settings)
        }
        // Shrink the tab bar into a compact pill while scrolling the list, so the
        // content gets the focus; it expands again on scroll-up / at the top.
        .modifier(TabBarMinimizeOnScroll())
        .onAppear { applySelection(selection) }
        .onChange(of: selection) { _, tab in applySelection(tab) }
        .onChange(of: homeFilter) { _, _ in
            if selection == .home {
                clearSearch()
                store.selectSmartSource(homeFilter)
            }
        }
    }

    /// Points the shared store at the scope the given tab shows. Also clears the
    /// shared search text, which would otherwise leak a query from the tab you
    /// left into the newly-shown scope.
    private func applySelection(_ tab: AppTab) {
        clearSearch()
        switch tab {
        case .home:
            store.selectSmartSource(homeFilter)
        case .starred:
            store.selectSmartSource(.starred)
        case .feeds:
            applyFeedTarget(feedsPath.last)
        case .settings:
            break
        }
    }

    private func applyFeedTarget(_ target: FeedTarget?) {
        guard let target else { return }
        CompactShell.applyScope(target, store: store)
    }

    private func clearSearch() {
        store.searchText = ""
        store.debounceSearch()
    }

    /// Points the shared store at a feed target's scope. Static so the Feeds tab's
    /// navigation destination can apply it directly (see `FeedsTab`).
    static func applyScope(_ target: FeedTarget, store: ReaderStore) {
        switch target {
        case .all:
            store.selectSmartSource(.all)
        case .folder(let name):
            store.selectFolder(name)
        case .feed(let id):
            store.feedSelection = [id]
            store.smartSelection = nil
        }
    }
}

/// Minimizes the tab bar as the user scrolls down (restoring on scroll-up / at
/// the top) on iOS 26+, where the behavior is native; a no-op on earlier iOS.
private struct TabBarMinimizeOnScroll: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.tabBarMinimizeBehavior(.onScrollDown)
        } else {
            content
        }
    }
}

// MARK: - Home tab

/// The default tab: a segmented Unread / Today / All filter over the article
/// list, with inline search. The tab item carries the unread badge.
private struct HomeTab: View {
    @Bindable var store: ReaderStore
    @Binding var filter: SmartSource
    var goToSettings: () -> Void

    private let filters: [SmartSource] = [.unread, .today, .all]

    /// Short labels for the nav-bar segmented control — "All Articles" is too wide
    /// there, so it shows as "All".
    private func segmentTitle(_ source: SmartSource) -> String {
        source == .all ? String(localized: "All") : source.title
    }

    var body: some View {
        NavigationStack {
            Group {
                if store.isStorageConfigured {
                    // The segmented filter lives in the navigation bar itself (no
                    // separate strip, no redundant title). Search is the full native
                    // search bar, revealed on demand by the toolbar button
                    // (ReaderPushingList's CompactSearchButton) — not an always-
                    // visible row, and not a cramped custom field.
                    ReaderPushingList(store: store)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .principal) {
                                Picker("Filter", selection: $filter) {
                                    ForEach(filters) { source in
                                        Text(segmentTitle(source)).tag(source)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .frame(minWidth: 240)
                            }
                        }
                } else {
                    ContentUnavailableView {
                        Label("Set Up Sync", systemImage: "icloud.and.arrow.up")
                    } description: {
                        Text("Choose a sync folder so Nook keeps your feeds in sync across your devices.")
                    } actions: {
                        Button("Choose Sync Folder") { goToSettings() }
                    }
                    .background(Color("ListBackground").ignoresSafeArea())
                }
            }
        }
    }
}

// MARK: - Starred tab

private struct StarredTab: View {
    let store: ReaderStore

    var body: some View {
        NavigationStack {
            ReaderPushingList(store: store)
        }
    }
}

// MARK: - Feeds tab

/// The library: an "All Articles" row, ungrouped feeds, and folders as
/// disclosure groups. Tapping a row drills into that source's article list
/// (which pushes the reader). Folders navigate via their label link and expand
/// via the disclosure chevron.
private struct FeedsTab: View {
    @Bindable var store: ReaderStore
    @Binding var path: [FeedTarget]

    @State private var isAddingFeed = false
    @State private var isCreatingFolder = false
    @State private var newFolderName = ""
    @State private var folderPendingRename: String?
    @State private var renameFolderName = ""
    @State private var feedPendingRename: Feed.ID?
    @State private var renameFeedName = ""

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    NavigationLink(value: FeedTarget.all) {
                        Label(SmartSource.all.title, systemImage: SmartSource.all.systemImage)
                    }
                }
                .listRowBackground(Rectangle().fill(.ultraThinMaterial))

                if !store.feedFolders.isEmpty || !store.ungroupedFeeds.isEmpty {
                    Section("Feeds") {
                        ForEach(store.ungroupedFeeds) { feed in
                            feedRow(feed)
                        }
                        ForEach(store.feedFolders, id: \.self) { folder in
                            DisclosureGroup {
                                ForEach(store.feeds(inFolder: folder)) { feed in
                                    feedRow(feed)
                                }
                            } label: {
                                NavigationLink(value: FeedTarget.folder(folder)) {
                                    Label(folder, systemImage: "folder")
                                }
                                .contextMenu {
                                    Button {
                                        renameFolderName = folder
                                        folderPendingRename = folder
                                    } label: {
                                        Label("Rename Folder", systemImage: "pencil")
                                    }
                                    Button(role: .destructive) {
                                        store.removeFolder(folder)
                                    } label: {
                                        Label("Delete Folder", systemImage: "trash")
                                    }
                                }
                            }
                        }
                    }
                    .listRowBackground(Rectangle().fill(.ultraThinMaterial))
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color("ListBackground").ignoresSafeArea())
            .navigationTitle("Feeds")
            .navigationDestination(for: FeedTarget.self) { target in
                // Apply this target's scope as the screen appears, so the shown
                // articles come from the navigation value itself rather than an
                // out-of-band side effect.
                ReaderPushingList(store: store)
                    .task(id: target) { CompactShell.applyScope(target, store: store) }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            isAddingFeed = true
                        } label: {
                            Label("Add Feed", systemImage: "plus")
                        }
                        Button {
                            isCreatingFolder = true
                        } label: {
                            Label("New Folder", systemImage: "folder.badge.plus")
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .refreshable { await store.refreshAllAndWait() }
        }
        .sheet(isPresented: $isAddingFeed) {
            AddFeedView(folders: store.feedFolders) { feedURL, folder in
                try await store.addFeed(urlString: feedURL, toFolder: folder)
            }
        }
        .alert("New Folder", isPresented: $isCreatingFolder) {
            TextField("Folder Name", text: $newFolderName)
            Button("Cancel", role: .cancel) { newFolderName = "" }
            Button("Create") {
                let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty { store.createFolder(name) }
                newFolderName = ""
            }
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
            Button("Cancel", role: .cancel) {}
            Button("Rename") { store.renameFolder(folder, to: renameFolderName) }
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
            Button("Cancel", role: .cancel) {}
            Button("Rename") { store.renameFeed(feedID, to: renameFeedName) }
        } message: { _ in
            Text("Enter a new name, or leave empty to use the feed's own name.")
        }
    }

    @ViewBuilder
    private func feedRow(_ feed: Feed) -> some View {
        let isRefreshing = store.isRefreshing(feedID: feed.id)
        NavigationLink(value: FeedTarget.feed(feed.id)) {
            HStack {
                ZStack {
                    if isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                            .transition(.opacity.combined(with: .scale(scale: 0.85)))
                    } else if let icon = store.faviconImage(for: feed) {
                        icon.resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 18, height: 18)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    } else {
                        Image(systemName: feed.systemImage)
                            .frame(width: 18, height: 18)
                            .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    }
                }
                .frame(width: 18, height: 18)
                .animation(.easeInOut(duration: 0.18), value: isRefreshing)
                .feedActivityFlash(trigger: store.feedUpdateToken(feedID: feed.id))
                Text(feed.displayTitle).lineLimit(1)
                Spacer()
                let count = store.unreadCount(feedID: feed.id)
                if count > 0 {
                    Text(count, format: .number).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                store.removeFeeds(ids: [feed.id])
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .swipeActions(edge: .leading) {
            Button {
                store.markFeedsRead(ids: [feed.id])
            } label: {
                Label("Mark Read", systemImage: "checkmark")
            }
            .tint(.blue)
        }
        .contextMenu {
            Button {
                store.markFeedsRead(ids: [feed.id])
            } label: {
                Label("Mark All as Read", systemImage: "checkmark.circle")
            }
            Button {
                renameFeedName = feed.displayTitle
                feedPendingRename = feed.id
            } label: {
                Label("Rename Feed", systemImage: "pencil")
            }
            if !store.feedFolders.isEmpty {
                Menu {
                    Button("None") { store.moveFeed(feed.id, toFolder: "") }
                    ForEach(store.feedFolders, id: \.self) { folder in
                        Button(folder) { store.moveFeed(feed.id, toFolder: folder) }
                    }
                } label: {
                    Label("Move to Folder", systemImage: "folder")
                }
            }
            Divider()
            Button(role: .destructive) {
                store.removeFeeds(ids: [feed.id])
            } label: {
                Label("Delete Feed", systemImage: "trash")
            }
        }
    }
}

// MARK: - Article list that pushes the reader

/// Wraps `ArticleList` with a navigation destination that pushes
/// `ReaderDetailView` when a row is selected. Used by Home, Starred, and each
/// drilled-into feed source. Selection is local to this view (so switching tabs
/// never pushes the reader in an inactive tab) and mirrored to
/// `store.selectedArticleID` so the reader and mark-read dwell work.
private struct ReaderPushingList<Top: View>: View {
    @Bindable var store: ReaderStore
    /// When true, this view owns the compact search UI (a toolbar button that
    /// reveals the search field on demand). Home passes false and provides its own
    /// segment-morphing search bar instead.
    var providesSearch: Bool = true
    let top: () -> Top
    /// The article captured when a row is tapped — the value the reader renders.
    /// Local to this stack, so another tab's scope change never blanks or swaps
    /// what this pushed reader shows.
    @State private var pushed: Article?
    @State private var isSearching = false
    /// Animated tab-bar hide while the reader is open (see the destination below).
    @State private var hideTabBar = false

    init(store: ReaderStore, providesSearch: Bool = true, @ViewBuilder top: @escaping () -> Top = { EmptyView() }) {
        self.store = store
        self.providesSearch = providesSearch
        self.top = top
    }

    var body: some View {
        VStack(spacing: 0) {
            top()
            ArticleList(store: store, selection: selectionBinding, managesSearch: false)
        }
        .modifier(CompactSearchButton(searchText: $store.searchText, isSearching: $isSearching, enabled: providesSearch))
        .navigationDestination(item: $pushed) { _ in
            // Drive the reader from the binding (not the closure's snapshot) so
            // previous/next swipe can move it in place.
            ReaderDetailView(store: store, articleOverride: $pushed)
                // Hide the tab bar while reading, animated so it slides down as the
                // reader opens and back up on return (toggling from onAppear/
                // onDisappear inside withAnimation, rather than a static hide that
                // just cuts).
                .toolbar(hideTabBar ? .hidden : .automatic, for: .tabBar)
                .onAppear { withAnimation(.easeInOut(duration: 0.3)) { hideTabBar = true } }
                .onDisappear { withAnimation(.easeInOut(duration: 0.3)) { hideTabBar = false } }
        }
    }

    /// Selecting a row captures the article's value (while it's still in the
    /// current scope) and mirrors its id into the store so the mark-read dwell
    /// runs. Clearing (back navigation) pops the reader.
    private var selectionBinding: Binding<Article.ID?> {
        Binding(
            get: { pushed?.id },
            set: { id in
                if let id, let article = store.visibleArticles.first(where: { $0.id == id }) {
                    pushed = article
                    store.selectedArticleID = id
                } else {
                    pushed = nil
                }
            }
        )
    }
}

/// The launch/loading screen. The OS launch screen is a static `LaunchBackground`
/// (cream) — the same color used here — so the hand-off is seamless; then the
/// icon's twig layers drop in from above under gravity and assemble into the
/// nest, matching the app icon.
struct SplashView: View {
    @State private var assembled = false
    @State private var showWordmark = false

    var body: some View {
        ZStack {
            Color("LaunchBackground")
                .ignoresSafeArea()

            NestAssemblyView(size: 150, assembled: assembled)

            // The wordmark fades in just below the nest once the twigs land.
            // A fixed dark-brown reads on the always-cream splash (don't use
            // .primary, which would be white in dark mode).
            Text(verbatim: "Nook")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundStyle(Color(.displayP3, red: 0.26, green: 0.19, blue: 0.10))
                .offset(y: 78 + (showWordmark ? 0 : 6))
                .opacity(showWordmark ? 1 : 0)
                .animation(.easeOut(duration: 0.3), value: showWordmark)
        }
        .task {
            // Static launch background → drop the twigs → reveal the wordmark.
            try? await Task.sleep(for: .milliseconds(120))
            assembled = true
            try? await Task.sleep(for: .seconds(NestAssemblyView.duration))
            showWordmark = true
        }
    }
}

/// A selectable sidebar entry. Binding the List selection to this (rather than
/// using plain buttons) is what lets a collapsed NavigationSplitView push to the
/// article-list column when a row is tapped on iPhone.
enum SidebarItem: Hashable {
    case smart(SmartSource)
    case feed(Feed.ID)
}

private struct Sidebar: View {
    @Bindable var store: ReaderStore
    var chooseFolder: () -> Void
    var importOPML: () -> Void
    @Binding var isAddingFeed: Bool
    @Binding var isExportingOPML: Bool
    @Binding var isCreatingFolder: Bool
    @Binding var isShowingSettings: Bool

    @State private var selection: SidebarItem?
    @State private var folderPendingRename: String?
    @State private var renameFolderName = ""
    @State private var feedPendingRename: Feed.ID?
    @State private var renameFeedName = ""

    var body: some View {
        List(selection: $selection) {
            Section("Library") {
                ForEach(SmartSource.allCases) { source in
                    HStack {
                        Label(source.title, systemImage: source.systemImage)
                        Spacer()
                        let count = store.count(for: source)
                        if count > 0 {
                            Text(count, format: .number).foregroundStyle(.secondary)
                        }
                    }
                    .tag(SidebarItem.smart(source))
                }
            }
            // Frosted translucent cards (not the solid white/dark grouped fill)
            // so the warm background shows through with a glassy feel.
            .listRowBackground(Rectangle().fill(.ultraThinMaterial))

            if !store.feedFolders.isEmpty || !store.ungroupedFeeds.isEmpty {
                Section("Feeds") {
                    ForEach(store.ungroupedFeeds) { feed in
                        feedRow(feed)
                    }
                    ForEach(store.feedFolders, id: \.self) { folder in
                        DisclosureGroup(folder) {
                            ForEach(store.feeds(inFolder: folder)) { feed in
                                feedRow(feed)
                            }
                        }
                        .contextMenu {
                            Button {
                                renameFolderName = folder
                                folderPendingRename = folder
                            } label: {
                                Label("Rename Folder", systemImage: "pencil")
                            }
                            Button(role: .destructive) {
                                store.removeFolder(folder)
                            } label: {
                                Label("Delete Folder", systemImage: "trash")
                            }
                        }
                    }
                }
                .listRowBackground(Rectangle().fill(.ultraThinMaterial))
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color("ListBackground").ignoresSafeArea())
        .onChange(of: selection) { _, item in
            switch item {
            case .smart(let source):
                store.selectSmartSource(source)
            case .feed(let id):
                store.feedSelection = [id]
                store.smartSelection = nil
            case nil:
                break
            }
        }
        .navigationTitle("Nook")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Button {
                        isAddingFeed = true
                    } label: {
                        Label("Add Feed", systemImage: "plus")
                    }
                    Button {
                        isCreatingFolder = true
                    } label: {
                        Label("New Folder", systemImage: "folder.badge.plus")
                    }
                    Divider()
                    Button {
                        importOPML()
                    } label: {
                        Label("Import OPML", systemImage: "square.and.arrow.down")
                    }
                    Button {
                        isExportingOPML = true
                    } label: {
                        Label("Export OPML", systemImage: "square.and.arrow.up")
                    }
                    .disabled(store.feeds.isEmpty)
                    Divider()
                    Button {
                        chooseFolder()
                    } label: {
                        Label(
                            store.isStorageConfigured ? "Change Sync Folder" : "Choose Sync Folder",
                            systemImage: store.isStorageConfigured ? "checkmark.icloud" : "icloud"
                        )
                    }
                    Button {
                        isShowingSettings = true
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .refreshable { await store.refreshAllAndWait() }
        // Only prompt for a folder while none is set (first run). Once storage
        // is configured this goes away instead of sitting at the bottom.
        .safeAreaInset(edge: .bottom) {
            if !store.isStorageConfigured {
                Button {
                    chooseFolder()
                } label: {
                    Label("Choose Sync Folder", systemImage: "icloud")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .padding()
            }
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
            Button("Cancel", role: .cancel) {}
            Button("Rename") { store.renameFolder(folder, to: renameFolderName) }
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
            Button("Cancel", role: .cancel) {}
            Button("Rename") { store.renameFeed(feedID, to: renameFeedName) }
        } message: { _ in
            Text("Enter a new name, or leave empty to use the feed's own name.")
        }
    }

    @ViewBuilder
    private func feedRow(_ feed: Feed) -> some View {
        let isRefreshing = store.isRefreshing(feedID: feed.id)
        HStack {
            ZStack {
                if isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .transition(.opacity.combined(with: .scale(scale: 0.85)))
                } else if let icon = store.faviconImage(for: feed) {
                    icon.resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 18, height: 18)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                } else {
                    Image(systemName: feed.systemImage)
                        .frame(width: 18, height: 18)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .frame(width: 18, height: 18)
            .animation(.easeInOut(duration: 0.18), value: isRefreshing)
            .feedActivityFlash(trigger: store.feedUpdateToken(feedID: feed.id))
            Text(feed.displayTitle).lineLimit(1)
            Spacer()
            let count = store.unreadCount(feedID: feed.id)
            if count > 0 {
                Text(count, format: .number).font(.caption).foregroundStyle(.secondary)
            }
        }
        .tag(SidebarItem.feed(feed.id))
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                store.removeFeeds(ids: [feed.id])
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .swipeActions(edge: .leading) {
            Button {
                store.markFeedsRead(ids: [feed.id])
            } label: {
                Label("Mark Read", systemImage: "checkmark")
            }
            .tint(.blue)
        }
        .contextMenu {
            Button {
                store.markFeedsRead(ids: [feed.id])
            } label: {
                Label("Mark All as Read", systemImage: "checkmark.circle")
            }
            Button {
                renameFeedName = feed.displayTitle
                feedPendingRename = feed.id
            } label: {
                Label("Rename Feed", systemImage: "pencil")
            }
            if !store.feedFolders.isEmpty {
                Menu {
                    Button("None") { store.moveFeed(feed.id, toFolder: "") }
                    ForEach(store.feedFolders, id: \.self) { folder in
                        Button(folder) { store.moveFeed(feed.id, toFolder: folder) }
                    }
                } label: {
                    Label("Move to Folder", systemImage: "folder")
                }
            }
            Divider()
            Button(role: .destructive) {
                store.removeFeeds(ids: [feed.id])
            } label: {
                Label("Delete Feed", systemImage: "trash")
            }
        }
    }
}

/// Reveals the full native search bar on demand from a toolbar magnifying-glass
/// button. `.searchable` is attached only while searching, so there's no
/// always-visible search row; once attached, `presented` is flipped false→true
/// so the system runs its native present animation AND focuses the field (raising
/// the keyboard). The native "Cancel" dismisses it, which unmounts the bar.
private struct CompactSearchButton: ViewModifier {
    @Binding var searchText: String
    @Binding var isSearching: Bool
    let enabled: Bool
    @State private var presented = false

    func body(content: Content) -> some View {
        if !enabled {
            content
        } else if isSearching {
            content
                .searchable(text: $searchText, isPresented: $presented, prompt: "Search Articles")
                .task { presented = true }
                .onChange(of: presented) { _, nowPresented in
                    if !nowPresented {
                        searchText = ""
                        isSearching = false
                    }
                }
        } else {
            content.toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { isSearching = true } label: {
                        Label("Search Articles", systemImage: "magnifyingglass")
                    }
                }
            }
        }
    }
}

/// Applies the standard always-available search drawer only when `enabled`
/// (iPad). The compact tab shell presents search from a toolbar button instead.
private struct DrawerSearch: ViewModifier {
    @Binding var text: String
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.searchable(text: $text, prompt: "Search Articles")
        } else {
            content
        }
    }
}

private struct ArticleList: View {
    @Bindable var store: ReaderStore
    @Binding var selection: Article.ID?
    /// Whether this list owns the search field. True on iPad (the split-view list
    /// shows the standard always-available search drawer); false in the compact
    /// tab shell, where `ReaderPushingList` presents search from a toolbar button.
    var managesSearch: Bool = true
    @AppStorage("readerViewMode") private var readerViewMode = ReaderViewMode.reader

    var body: some View {
        List(store.visibleArticles, selection: $selection) { article in
            row(article)
                .tag(article.id)
                .swipeActions(edge: .leading) {
                    Button {
                        store.setRead(articleID: article.id, isRead: !article.isRead)
                    } label: {
                        Label(
                            article.isRead ? "Unread" : "Read",
                            systemImage: article.isRead ? "circle" : "checkmark.circle"
                        )
                    }
                    .tint(.blue)
                }
                .swipeActions(edge: .trailing) {
                    Button {
                        store.toggleStarred(articleID: article.id)
                    } label: {
                        Label("Star", systemImage: article.isStarred ? "star.slash" : "star")
                    }
                    .tint(.yellow)
                }
                .contextMenu {
                    Button {
                        store.setRead(articleID: article.id, isRead: !article.isRead)
                    } label: {
                        Label(article.isRead ? "Mark as Unread" : "Mark as Read",
                              systemImage: article.isRead ? "circle" : "checkmark.circle")
                    }
                    Button {
                        store.toggleStarred(articleID: article.id)
                    } label: {
                        Label(article.isStarred ? "Unstar" : "Star",
                              systemImage: article.isStarred ? "star.slash" : "star")
                    }
                    Button {
                        store.selectedArticleID = article.id
                        store.browserMode = store.feed(for: article.feedID)?.preferredViewMode ?? readerViewMode
                        store.isBrowserPresented = true
                    } label: {
                        Label("Open in Browser", systemImage: "safari")
                    }
                    ShareLink(item: article.url) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                }
                // Transparent rows so the warm list background shows through.
                .listRowBackground(Color.clear)
                // No divider above the first row or below the last — only between rows.
                .listRowSeparator(article.id == store.visibleArticles.first?.id ? .hidden : .automatic, edges: .top)
                .listRowSeparator(article.id == store.visibleArticles.last?.id ? .hidden : .automatic, edges: .bottom)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color("ListBackground").ignoresSafeArea())
        .navigationTitle(store.selectedSourceTitle)
        .modifier(DrawerSearch(text: $store.searchText, enabled: managesSearch))
        .onChange(of: store.searchText) { _, _ in store.debounceSearch() }
        .refreshable { await refreshCurrent() }
        .overlay {
            if store.visibleArticles.isEmpty {
                ContentUnavailableView("No Articles", systemImage: "newspaper")
            }
        }
    }

    /// Pull-to-refresh: when viewing a specific feed, refresh just that feed;
    /// otherwise (a smart source like Unread/Today/All) refresh everything.
    private func refreshCurrent() async {
        if store.smartSelection == nil, !store.feedSelection.isEmpty {
            await store.refreshFeedsAndWait(ids: Array(store.feedSelection))
        } else {
            await store.refreshAllAndWait()
        }
    }

    private func row(_ article: Article) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if !article.isRead {
                    Circle().fill(Color.accentColor).frame(width: 7, height: 7)
                }
                Text(article.title)
                    .font(.headline)
                    .lineLimit(2)
                    .foregroundStyle(article.isRead ? .secondary : .primary)
                if article.isStarred {
                    Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow)
                }
            }
            if !article.summary.isEmpty {
                Text(article.summary).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }
            HStack(spacing: 6) {
                Text(store.feed(for: article.feedID)?.displayTitle ?? "")
                Text("·")
                RelativeTimeText(article.publishedAt)
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
    }
}
