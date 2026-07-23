import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
public final class ReaderStore {
    public var feeds: [Feed] = [] { didSet { scheduleArticleFilter(debounced: true) } }
    var articles: [Article] = [] {
        didSet {
            // Counts + unread badge recompute on every change (a single O(all)
            // pass, cheap) so the Dock/app-icon badge and sidebar counts always
            // stay live — including a read toggle made while a refresh is in
            // flight. Only the filter+sort is debounced/coalesced.
            recomputeCounts()
            updateUnreadBadge()
            scheduleArticleFilter(debounced: true)
        }
    }

    // Sidebar badge counts, recomputed in a single pass whenever `articles`
    // changes, so rendering a feed/folder/source badge is an O(1)/O(feeds)
    // lookup instead of an O(articles) scan on every re-render (the sidebar
    // re-renders constantly while a refresh streams articles in).
    private(set) var unreadByFeed: [Feed.ID: Int] = [:]
    private(set) var totalUnread = 0
    private(set) var todayCount = 0
    private(set) var starredCount = 0
    // Library and Feeds are independent selection scopes: a single smart
    // source acts as navigation, while feeds support multiple selection.
    public var smartSelection: SmartSource? = .all { didSet { scheduleArticleFilter() } }
    public var feedSelection: Set<Feed.ID> = [] { didSet { scheduleArticleFilter() } }
    /// Whether the window-wide in-app browser bottom sheet is showing.
    public var isBrowserPresented = false
    /// The in-app browser's current view mode (reader vs original). Toggled
    /// instantly without changing the saved default.
    public var browserMode: ReaderViewMode = .reader

    public func toggleBrowserMode() {
        guard isBrowserPresented else { return }
        browserMode = (browserMode == .reader) ? .original : .reader
    }

    /// The in-app browser's reading mode for `article`: the feed's per-feed
    /// override, else the global default. The single source of truth so opening
    /// an article and advancing to the next one resolve the mode identically —
    /// previously "next" skipped this and stuck on the prior article's mode.
    public func resolvedBrowserMode(for article: Article) -> ReaderViewMode {
        if let feedMode = feed(for: article.feedID)?.preferredViewMode { return feedMode }
        let stored = UserDefaults.standard.string(forKey: "readerViewMode")
        return stored.flatMap(ReaderViewMode.init(rawValue:)) ?? .reader
    }
    // Articles kept visible in the current source even after being read, until
    // the user navigates to another source (Chrome-tab-close heuristic).
    private var retainedArticleIDs: Set<Article.ID> = [] { didSet { scheduleArticleFilter(debounced: true) } }
    public var selectedArticleID: Article.ID?
    /// The raw text bound to the search field; updates instantly as the user types.
    public var searchText = ""
    /// The query actually used to filter articles. Trails `searchText` by a
    /// short debounce so filtering doesn't run on every keystroke.
    public private(set) var activeSearchQuery = "" { didSet { scheduleArticleFilter(animated: false) } }
    private var searchDebounceTask: Task<Void, Never>?

    /// Per-category sort order (SmartSource rawValue → order), persisted locally
    /// as a device UI preference. Feed drill-downs share the "feed" bucket.
    private var sortOrders: [String: ArticleSortOrder] = ReaderStore.loadSortOrders()
    private static let sortOrdersKey = "articleSortOrders"

    /// The filtered, sorted articles shown in the list. Recomputed off the main
    /// thread for large libraries so typing/scrolling never blocks the UI.
    private(set) var displayedArticles: [Article] = []
    private var filterTask: Task<Void, Never>?
    /// Coalesces data-driven recomputes (a sync streams articles in bursts, each
    /// mutation firing `didSet`) so the expensive filter+sort runs at most once
    /// per quiet window instead of dozens of times a second.
    private var filterDebounceTask: Task<Void, Never>?
    private static let filterDebounceInterval: Duration = .milliseconds(300)
    /// Above this many articles, filtering runs on a background executor.
    private static let backgroundFilterThreshold = 600
    var lastRefreshedAt: Date?
    public var errorMessage: String?
    /// Mirrors the "show unread badge" preference. Held in the store (not only
    /// the view) so the Dock badge is a deterministic function of store state
    /// rather than of SwiftUI view-lifecycle timing.
    public var showsUnreadBadge = true { didSet { updateUnreadBadge() } }
    /// Whether the app is currently foreground-active, set by each platform app
    /// on scene/activation changes. While active, articles surfaced in the list
    /// are marked "seen" so they never fire a later "new article" notification
    /// (on this device or, via shard sync, any other). Defaults `false` so a
    /// background refresh — the one path that *should* notify — never marks seen.
    public private(set) var isForegroundActive = false
    public private(set) var syncFolderDisplayPath: String?
    private(set) var feedIcons: [Feed.ID: PlatformImage] = [:]
    private(set) var folders: [String] = []

    // Favicon fetching is deduplicated by host and rate-limited so a large
    // library doesn't spawn a storm of concurrent requests on launch.
    private var faviconAttemptedKeys: Set<String> = []
    private var faviconQueue: [Feed] = []
    private var activeFaviconFetches = 0
    private static let maxConcurrentFaviconFetches = 4

    /// How a full refresh should spend resources. An explicit, user-triggered
    /// refresh wants results fast; automatic refreshes that may run while the
    /// user is interacting stay quiet and light so content trickles in without
    /// jolting the UI, while the UI-less iOS background task fetches fast to fit
    /// the OS's time budget.
    public enum RefreshMode: Sendable {
        /// User asked (Refresh All, pull-to-refresh): fast, animated.
        case interactive
        /// Automatic and possibly concurrent with app use (activation sync,
        /// macOS periodic timer): low concurrency/priority, no animation.
        case ambient
        /// iOS background task: no visible UI, so fetch fast (fit the budget) but
        /// don't animate.
        case background

        /// Feeds fetched over the network at once. Higher = faster but heavier.
        var maxConcurrentFetches: Int {
            switch self {
            case .interactive, .background: 6
            case .ambient: 2
            }
        }

        /// QoS for the network fetch + XML parse, so an automatic refresh yields
        /// to interactive UI work instead of competing with it.
        var fetchPriority: TaskPriority {
            switch self {
            case .interactive: .userInitiated
            case .ambient, .background: .utility
            }
        }

        /// Whether newly arrived articles animate into the list. Off for
        /// automatic refreshes so rows appear quietly rather than sliding under
        /// the user mid-scroll.
        var animatesInsertion: Bool {
            switch self {
            case .interactive: true
            case .ambient, .background: false
            }
        }

        /// Whether the per-feed sidebar spinner shows while fetching. On only for
        /// user-initiated refreshes; automatic (ambient/background) refreshes stay
        /// visually silent so returning to Nook or a periodic tick doesn't flip
        /// every feed icon to a spinner. New content is signalled by a brief
        /// per-feed flash instead (see `feedUpdateTokens`).
        var showsSpinner: Bool {
            switch self {
            case .interactive: true
            case .ambient, .background: false
            }
        }
    }

    private let feedService = RSSFeedService()
    private let faviconService = FaviconService()
    private let opmlService = OPMLService()
    private var storage: ReaderStorage?
    private var securityScopedDirectoryURL: URL?

    // File events are rescan hints for legacy input and v2 shard directories;
    // correctness comes from the durable replica merge, not event delivery.
    private var fileObservers: [LibraryFileObserver] = []
    private var lastKnownLibraryModDate: Date?
    private var lastKnownStateModDate: Date?
    private var lastKnownContentModDate: Date?
    private var lastKnownBodiesModDate: Date?
    private var externalReloadTask: Task<Void, Never>?

    // Coalesced background persistence: the latest snapshot waiting to be
    // written, and whether a writer task is already draining them.
    private var pendingSave: ReaderLibrary?
    private var isDrainingSaves = false
    // While a full refresh runs, per-feed saves are held so the whole (large)
    // library isn't re-encoded and rewritten once per feed; one write flushes
    // the final state when the refresh finishes.
    private var isBatchRefreshing = false
    private var isAccessingSecurityScopedResource = false
    // Every feed with a network fetch in flight, in any mode. Drives the global
    // `isRefreshing` (concurrency guards, disabled buttons) so an automatic
    // refresh still coalesces with user-initiated ones.
    private var refreshingFeedIDs: Set<Feed.ID> = []
    // Feeds whose per-feed spinner should show — populated only for user-initiated
    // (interactive) refreshes, so automatic ones update content without flipping
    // feed icons to a spinner on every tick.
    private var spinningFeedIDs: Set<Feed.ID> = []
    // A per-feed counter bumped every time a refresh brings in new articles. The
    // sidebar animates a flash whenever a feed's token changes; a refresh that
    // adds nothing leaves the token — and the UI — untouched.
    private(set) var feedUpdateTokens: [Feed.ID: Int] = [:]

    /// The state of reader-mode extraction for an article, driving the native
    /// reader when the "reader content by default" experiment is on.
    public enum ReaderContentState: Equatable, Sendable {
        case loading
        case ready(String)
        case failed
        /// The original page returned 404/410 — it's gone from the source, so the
        /// reader offers to delete the lingering local copy.
        case gone
    }

    /// Per-article reader-mode extraction state, observed by the reader views.
    /// Rebuilt per session; the durable results live in the CRDT reader shards.
    private(set) var readerContentStates: [Article.ID: ReaderContentState] = [:]
    /// The CRDT-synced cache of extracted reader content (separate from every
    /// other store; see `ReaderContentStore`). Created with storage.
    private var readerContentStore: ReaderContentStore?
    /// Headless Readability extractor, created on first use.
    private var readerModeExtractor: ReaderModeExtractor?

    // Article bodies live in a separate sidecar so the launch baseline stays
    // small. This in-memory cache lets a re-merge (which reloads the light
    // baseline) restore bodies without re-reading the sidecar each time.
    private var bodyCache: [Article.ID: ArticleBody] = [:]
    private var didLoadBodyCache = false
    private var isLoadingBodyCache = false
    /// Bodies are kept on disk for at most this many of the most-recent articles.
    private nonisolated static let bodyRetentionLimit = 600

    // Git-like per-device sync. This device authors its own shard of user state
    // (read/starred flags, folders, per-feed overrides, feed deletions), each
    // change stamped with a monotonic HLC and materialized over content shards.
    private var deviceID = ""
    private var lastHLC: HLC = .zero
    private var ownShard = DeviceStateDocument(deviceID: "")
    private var pendingShard: DeviceStateDocument?
    private var isDrainingShardSaves = false
    private var replicaStore: ReplicaStore?
    private var appliedReplicaRevision: UInt64 = 0

    /// App-global instance. A singleton so the separate Settings scene can reach
    /// the same feeds/state as the main window (SwiftUI scenes can't share a
    /// view's `@State`).
    public static let shared = ReaderStore()

    private var didBootstrap = false

    private init() {}

    /// Loads the persisted library and starts filtering. Runs its heavy work
    /// only once, no matter how often it is called.
    ///
    /// Kept out of `init()` on purpose: SwiftUI re-evaluates the app/window body
    /// many times while the graph settles, re-running `ContentView.init()`. With
    /// the JSON load in `init()`, that decoded `NookLibrary.json` synchronously on
    /// the main thread repeatedly and pinned the CPU near 100%. Deferring it to a
    /// one-time call from `.task` keeps those re-evaluations cheap.
    public func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true
        deviceID = DeviceIdentity.current()
        ownShard = DeviceStateDocument(deviceID: deviceID)
        await restoreStorageIfPossible()
        scheduleArticleFilter()
    }

    public var isStorageConfigured: Bool {
        storage != nil
    }

    public var isRefreshing: Bool {
        !refreshingFeedIDs.isEmpty
    }

    public var selectedArticle: Article? {
        guard let selectedArticleID else { return nil }
        return articles.first { $0.id == selectedArticleID }
    }

    /// The list-backing articles. Backed by `displayedArticles`, which is
    /// recomputed (off-main for large libraries) whenever a filter input changes.
    public var visibleArticles: [Article] { displayedArticles }

    /// Recomputes `displayedArticles` from the current inputs.
    ///
    /// User-driven changes (source/feed selection, search) pass `debounced:
    /// false` for an instant response. Data-driven changes that arrive in
    /// bursts (articles/feeds streaming in during a sync) pass `debounced: true`
    /// so the recompute is deferred until the burst settles, capturing the
    /// latest snapshot once instead of re-sorting on every mutation.
    private func scheduleArticleFilter(debounced: Bool = false, animated: Bool = true) {
        guard debounced else {
            filterDebounceTask?.cancel()
            filterDebounceTask = nil
            performArticleFilter(animated: animated)
            return
        }

        filterDebounceTask?.cancel()
        filterDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: Self.filterDebounceInterval)
            guard !Task.isCancelled, let self else { return }
            self.performArticleFilter(animated: animated)
        }
    }

    /// Captures the current inputs and recomputes `displayedArticles`. Small
    /// libraries are filtered synchronously (instant, animatable); large ones
    /// are filtered on a background executor so the main thread stays responsive.
    private func performArticleFilter(animated: Bool = true) {
        filterTask?.cancel()

        let snapshot = articles
        let feedTitles = Dictionary(feeds.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        let feedSelection = self.feedSelection
        let smartSelection = self.smartSelection
        let retained = retainedArticleIDs
        let query = activeSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let order = currentSortOrder

        // Only the empty-query, small-library path filters synchronously (cheap set
        // /enum checks + sort, and it should stay sync so it can still animate). Any
        // text query does an O(n·paragraphs) locale scan, so route it off the main
        // actor even under the threshold, so search never hitches the main thread.
        if query.isEmpty && snapshot.count < Self.backgroundFilterThreshold {
            applyDisplayed(Self.computeVisibleArticles(
                snapshot, feedTitles: feedTitles, feedSelection: feedSelection,
                smartSelection: smartSelection, retained: retained, query: query, order: order
            ), animated: animated)
            return
        }

        filterTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Self.computeVisibleArticles(
                    snapshot, feedTitles: feedTitles, feedSelection: feedSelection,
                    smartSelection: smartSelection, retained: retained, query: query, order: order
                )
            }.value
            guard !Task.isCancelled, let self else { return }
            self.applyDisplayed(result, animated: animated)
        }
    }

    private func applyDisplayed(_ result: [Article], animated: Bool = true) {
        // Animate only when the visible rows actually change and still overlap
        // the current list — i.e. articles arriving (or filtering out) — so new
        // stories slide in instead of the list snapping/jumping. A full swap
        // (switching source) or the very first fill isn't animated, which would
        // otherwise look like a jarring reshuffle. This runs for both the sync
        // and background filter paths, so large libraries animate too.
        let oldIDs = displayedArticles.map(\.id)
        let newIDs = result.map(\.id)
        let oldSet = Set(oldIDs)
        if animated, oldIDs != newIDs, !oldSet.isEmpty, !oldSet.isDisjoint(with: newIDs) {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                displayedArticles = result
            }
        } else {
            displayedArticles = result
        }
        pruneSelectionIfHidden()
        // The list the user is looking at now counts as "seen"; suppress future
        // notifications for it (no-op unless the app is foreground-active).
        markVisibleArticlesSeen()
    }

    /// Pure filtering + sorting over a snapshot. `nonisolated` so it can run on
    /// a background executor; all inputs are value types (`Sendable`).
    nonisolated private static func computeVisibleArticles(
        _ articles: [Article],
        feedTitles: [Feed.ID: String],
        feedSelection: Set<Feed.ID>,
        smartSelection: SmartSource?,
        retained: Set<Article.ID>,
        query: String,
        order: ArticleSortOrder
    ) -> [Article] {
        func matchesSource(_ article: Article) -> Bool {
            if !feedSelection.isEmpty { return feedSelection.contains(article.feedID) }
            if let smartSelection { return article.matches(.smart(smartSelection)) }
            return true
        }

        func matchesSourceIgnoringReadState(_ article: Article) -> Bool {
            if !feedSelection.isEmpty { return feedSelection.contains(article.feedID) }
            switch smartSelection {
            case .some(.unread), .some(.all), .none: return true
            case .some(.today): return Calendar.current.isDateInToday(article.publishedAt)
            case .some(.starred): return article.isStarred
            }
        }

        func matchesQuery(_ article: Article) -> Bool {
            guard !query.isEmpty else { return true }
            if article.title.localizedStandardContains(query) { return true }
            if article.summary.localizedStandardContains(query) { return true }
            if let title = feedTitles[article.feedID], title.localizedStandardContains(query) { return true }
            // Scan paragraphs lazily instead of joining the whole body up front.
            return article.bodyParagraphs.contains { $0.localizedStandardContains(query) }
        }

        return articles
            .filter { (matchesSource($0) || (retained.contains($0.id) && matchesSourceIgnoringReadState($0))) && matchesQuery($0) }
            .sorted { Article.isOrdered($0, $1, by: order) }
    }

    public var syncFolderName: String? {
        guard let syncFolderDisplayPath, !syncFolderDisplayPath.isEmpty else { return nil }
        return (syncFolderDisplayPath as NSString).lastPathComponent
    }

    public var selectedSourceTitle: String {
        if !feedSelection.isEmpty {
            if feedSelection.count == 1, let id = feedSelection.first {
                return feed(for: id)?.title ?? String(localized: "Feed", bundle: Bundle.module)
            }
            return String(localized: "\(feedSelection.count) selected", bundle: Bundle.module)
        }
        return smartSelection?.title ?? String(localized: "Articles", bundle: Bundle.module)
    }

    /// The feed IDs currently selected, for batch feed actions.
    public var selectedFeedIDs: [Feed.ID] { Array(feedSelection) }

    /// Selecting a smart source is single-select navigation and clears any
    /// feed selection, keeping the two scopes independent.
    public func selectSmartSource(_ source: SmartSource) {
        smartSelection = source
        feedSelection = []
        clearRetainedArticles()
        pruneSelectionIfHidden()
    }

    // MARK: - Sort order (per category, persisted)

    /// The saved sort order for a category (defaults to newest-first).
    public func sortOrder(for source: SmartSource) -> ArticleSortOrder {
        sortOrders[source.rawValue] ?? .newest
    }

    /// Toggles a category's sort order (re-tapping its segment), persists it, and
    /// re-sorts the list immediately.
    public func toggleSortOrder(for source: SmartSource) {
        sortOrders[source.rawValue] = sortOrder(for: source).toggled()
        persistSortOrders()
        scheduleArticleFilter()
    }

    /// The order to apply to the list currently on screen: the selected smart
    /// source's, or the shared "feed" bucket when a specific feed is shown.
    private var currentSortOrder: ArticleSortOrder {
        if let smartSelection { return sortOrders[smartSelection.rawValue] ?? .newest }
        return sortOrders["feed"] ?? .newest
    }

    private func persistSortOrders() {
        UserDefaults.standard.set(sortOrders.mapValues(\.rawValue), forKey: Self.sortOrdersKey)
    }

    private static func loadSortOrders() -> [String: ArticleSortOrder] {
        guard let raw = UserDefaults.standard.dictionary(forKey: sortOrdersKey) as? [String: String] else { return [:] }
        return raw.reduce(into: [:]) { result, pair in
            if let order = ArticleSortOrder(rawValue: pair.value) { result[pair.key] = order }
        }
    }

    func handleSyncFolderSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let directoryURL = urls.first else { return }
            configureSyncFolder(directoryURL)
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }

    public func configureSyncFolder(_ directoryURL: URL) {
        do {
            try ReaderStorage.saveBookmark(for: directoryURL)
            startAccessing(directoryURL)

            let storage = ReaderStorage(directoryURL: directoryURL)
            self.storage = storage
            syncFolderDisplayPath = directoryURL.path(percentEncoded: false)

            restoreOwnShard(storage: storage)
            let replica = try ReplicaStore(syncDirectory: directoryURL, deviceID: deviceID)
            replicaStore = replica
            let snapshot = try replica.reconcile(storage: storage)
            try migrateLegacyUserStateIfNeeded(replica: replica, storage: storage)
            applyReplicaSnapshot(snapshot, storage: storage)
            try replica.publishIfNeeded(to: storage)

            errorMessage = nil
            pruneSelectionIfHidden()
            lastKnownLibraryModDate = storage.libraryModificationDate
            lastKnownStateModDate = storage.stateDirectoryModificationDate
            lastKnownContentModDate = storage.contentDirectoryModificationDate
            lastKnownBodiesModDate = storage.bodiesDirectoryModificationDate
            startObservingLibrary()
            Task { await loadBodyCacheIfNeeded() }
            let readerStore = ReaderContentStore(storage: storage, deviceID: deviceID)
            readerContentStore = readerStore
            Task { await readerStore.reload() }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Cross-device sync

    /// Begins watching the library file so another device's edits (arriving via
    /// iCloud) are applied while the app is open, and asks iCloud to download
    /// the latest copy now.
    private func startObservingLibrary() {
        guard let storage else { return }
        storage.startDownloadingLibraryIfNeeded()
        storage.startDownloadingStateIfNeeded()

        stopObservingLibrary()
        let onChange: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in self?.scheduleExternalReload() }
        }
        // Watch legacy input and all three v2 shard directories.
        fileObservers = [
            LibraryFileObserver(fileURL: storage.libraryURL, onChange: onChange),
            LibraryFileObserver(fileURL: storage.contentDirectoryURL, onChange: onChange),
            LibraryFileObserver(fileURL: storage.bodiesDirectoryURL, onChange: onChange),
            LibraryFileObserver(fileURL: storage.stateDirectoryURL, onChange: onChange),
        ]
    }

    private func stopObservingLibrary() {
        for observer in fileObservers { observer.stop() }
        fileObservers.removeAll()
    }

    /// iOS removes file presenters while backgrounded; foreground activation
    /// re-registers them and requests an idempotent rescan. Correctness never
    /// depends on receiving every presenter callback.
    public func setSyncObservationActive(_ active: Bool) {
        if active {
            startObservingLibrary()
            scheduleExternalReload()
        } else {
            stopObservingLibrary()
        }
    }

    /// Coalesces a burst of file-change notifications into a single re-merge,
    /// skipping this device's own writes by comparing modification dates. Fires
    /// for legacy and shard changes, so a read on another device shows up
    /// live without a relaunch.
    private func scheduleExternalReload() {
        externalReloadTask?.cancel()
        externalReloadTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self, let storage = self.storage, !self.isRefreshing else { return }

            let baselineDate = storage.libraryModificationDate
            let stateDate = storage.stateDirectoryModificationDate
            let contentDate = storage.contentDirectoryModificationDate
            let bodiesDate = storage.bodiesDirectoryModificationDate
            guard Self.isNewer(baselineDate, than: self.lastKnownLibraryModDate)
                || Self.isNewer(stateDate, than: self.lastKnownStateModDate)
                || Self.isNewer(contentDate, than: self.lastKnownContentModDate)
                || Self.isNewer(bodiesDate, than: self.lastKnownBodiesModDate) else {
                return
            }

            // reloadMerged decodes off-main and records the mod dates itself.
            await self.reloadMerged()
        }
    }

    /// Whether `date` is strictly newer than the last one we recorded — treating
    /// "no recorded date yet" as a change and "item gone" as no change.
    private static func isNewer(_ date: Date?, than known: Date?) -> Bool {
        guard let date else { return false }
        guard let known else { return true }
        return date > known
    }

    /// Restores this device's shard (its clock and authored registers) from disk,
    /// or seeds an empty one on first run — the one-time migration for an existing
    /// `NookLibrary.json`, whose read/starred state stays valid as the merge
    /// baseline. Seeding also registers this device so peers can see it.
    private func restoreOwnShard(storage: ReaderStorage) {
        if let own = storage.loadOwnShard(deviceID: deviceID) {
            ownShard = own
            lastHLC = own.clock
        } else {
            ownShard = DeviceStateDocument(deviceID: deviceID)
            lastHLC = .zero
            try? storage.saveShard(ownShard)
        }
    }

    /// v1 stored untouched read/starred flags and folder membership only in the
    /// shared baseline. v2 content intentionally has no user state, so seed any
    /// still-missing registers before the first v2 materialization. Existing
    /// registers always win and the completion marker is written only after the
    /// device shard is durable.
    private func migrateLegacyUserStateIfNeeded(replica: ReplicaStore, storage: ReaderStorage) throws {
        guard let legacy = try replica.pendingLegacyStateSeed(from: storage) else { return }
        let peerShards = ((try? storage.loadShards()) ?? []).filter { $0.deviceID != deviceID }
        witness(peerShards + [ownShard])
        lastHLC = ownShard.seedLegacyUserState(
            from: legacy,
            whereMissingFrom: peerShards,
            after: lastHLC,
            node: deviceID
        )
        ownShard.updatedAt = Date()
        ownShard.generation &+= 1
        try storage.saveShard(ownShard)
        try replica.markLegacyStateSeedComplete()
        lastKnownStateModDate = storage.stateDirectoryModificationDate
    }

    /// Merges the content baseline with every device's shard and applies the
    /// result, advancing this device's clock past everything it has observed so
    /// its next write beats any peer's latest edit.
    private func mergeShardsAndApply(base: ReaderLibrary, storage: ReaderStorage) {
        let shards = observedShards(from: storage)
        witness(shards)
        apply(DeviceStateDocument.materialize(base: base, shards: shards))
    }

    /// All shards on disk, but with this device's on-disk shard replaced by the
    /// authoritative in-memory `ownShard` so a not-yet-flushed local edit is
    /// never dropped when re-merging.
    private func observedShards(from storage: ReaderStorage) -> [DeviceStateDocument] {
        var shards = (try? storage.loadShards()) ?? []
        shards.removeAll { $0.deviceID == deviceID }
        shards.append(ownShard)
        return shards
    }

    private func witness(_ shards: [DeviceStateDocument]) {
        for shard in shards where shard.deviceID != deviceID {
            lastHLC = lastHLC.witnessed(shard.maxObservedHLC)
        }
        ownShard.clock = lastHLC
    }

    /// Re-scans legacy input + all shards, merges, and applies the result only
    /// when it differs from what's in memory — so peer edits show up without
    /// churning the UI on our own writes. Preserves UI state (selection, search).
    ///
    /// The disk read and JSON decode (the baseline can be several MB) run off the
    /// main actor so a foreground/observer wake never stalls the UI; only the
    /// merge with our in-memory shard and the apply run on the main actor.
    private func reloadMerged() async {
        guard let storage else { return }

        // Pull any peer's reader-mode extractions (CRDT-merged) so content a
        // sibling device already extracted shows here without re-fetching.
        await readerContentStore?.reload()

        guard let replicaStore else { return }
        let loaded = await Task.detached(priority: .userInitiated) { () -> (ReplicaSnapshot, [DeviceStateDocument])? in
            guard let snapshot = try? replicaStore.reconcile(storage: storage) else { return nil }
            try? replicaStore.publishIfNeeded(to: storage)
            return (snapshot, (try? storage.loadShards()) ?? [])
        }.value
        guard let (snapshot, peerShards) = loaded, snapshot.revision >= appliedReplicaRevision else { return }
        // A refresh may have started during the off-main decode; its in-memory
        // articles would be newer than this disk snapshot, so don't clobber them.
        guard !isRefreshing else { return }

        // Fold in this device's authoritative in-memory shard (a not-yet-flushed
        // local edit must never be dropped) and advance the clock.
        var shards = peerShards.filter { $0.deviceID != deviceID }
        shards.append(ownShard)
        witness(shards)
        // Fill bodies from the cache so the (list-light) baseline's stripped
        // bodies don't read as a change and the applied result keeps content.
        if !snapshot.bodies.isEmpty { bodyCache.merge(snapshot.bodies) { _, new in new } }
        let merged = hydratedFromCache(DeviceStateDocument.materialize(base: snapshot.library, shards: shards))

        // Compare against the same folder normalization `apply` produces.
        let impliedFolders = merged.feeds.map(\.folderName).filter { !$0.isEmpty }
        let mergedFolders = Set(merged.folders).union(impliedFolders)
        if merged.feeds != feeds || merged.articles != articles || mergedFolders != Set(folders) {
            apply(merged)
            pruneSelectionIfHidden()
        }
        lastKnownLibraryModDate = storage.libraryModificationDate
        lastKnownStateModDate = storage.stateDirectoryModificationDate
        lastKnownContentModDate = storage.contentDirectoryModificationDate
        lastKnownBodiesModDate = storage.bodiesDirectoryModificationDate
        appliedReplicaRevision = max(appliedReplicaRevision, snapshot.revision)
    }

    private func applyReplicaSnapshot(_ snapshot: ReplicaSnapshot, storage: ReaderStorage) {
        guard snapshot.revision >= appliedReplicaRevision else { return }
        if !snapshot.bodies.isEmpty { bodyCache.merge(snapshot.bodies) { _, new in new } }
        mergeShardsAndApply(base: snapshot.library, storage: storage)
        appliedReplicaRevision = snapshot.revision
    }

    /// Loads the content sidecar once (off-main) into the in-memory body cache,
    /// then fills the current articles' bodies from it. The list already shows
    /// from the light baseline, so this runs after launch without blocking it.
    private func loadBodyCacheIfNeeded() async {
        guard !didLoadBodyCache, !isLoadingBodyCache, let storage else { applyBodyCache(); return }
        isLoadingBodyCache = true
        let bodies = await Task.detached(priority: .userInitiated) { storage.loadContent() }.value
        isLoadingBodyCache = false
        didLoadBodyCache = true
        if !bodies.isEmpty {
            bodyCache.merge(bodies) { current, _ in current }
            scheduleSave()
        }
        applyBodyCache()
    }

    /// Fills bodies into any in-memory article that is missing one, from the
    /// cache. Bodies aren't shown in the list, so this never churns it.
    private func applyBodyCache() {
        guard !bodyCache.isEmpty else { return }
        // Mutate a local copy and assign once: `articles` has a didSet that
        // recomputes counts and the filter, so per-element writes would make
        // this O(n²) and stall the main actor.
        var updated = articles
        var changed = false
        for index in updated.indices where !updated[index].hasBody {
            if let body = bodyCache[updated[index].id] {
                updated[index].bodyParagraphs = body.bodyParagraphs
                updated[index].contentHTML = body.contentHTML
                changed = true
            }
        }
        if changed { articles = updated }
    }

    /// Returns `library` with each article's body filled in from the cache where
    /// the (list-light) baseline left it empty, so a re-merge comparison ignores
    /// the stripped bodies and the applied result keeps its content.
    private func hydratedFromCache(_ library: ReaderLibrary) -> ReaderLibrary {
        guard !bodyCache.isEmpty else { return library }
        var library = library
        for index in library.articles.indices where !library.articles[index].hasBody {
            if let body = bodyCache[library.articles[index].id] {
                library.articles[index].bodyParagraphs = body.bodyParagraphs
                library.articles[index].contentHTML = body.contentHTML
            }
        }
        return library
    }

    /// The ids whose bodies are worth persisting: the most recent articles, so
    /// the content sidecar stays bounded.
    nonisolated static func recentArticleIDs(from articles: [Article]) -> Set<Article.ID> {
        guard articles.count > bodyRetentionLimit else { return Set(articles.map(\.id)) }
        let recent = articles.sorted(by: Article.isOrderedBefore).prefix(bodyRetentionLimit)
        return Set(recent.map(\.id))
    }

    /// Pulls the latest legacy input and every peer shard, then re-merges.
    /// Call this when the app returns to the foreground so device switches sync
    /// promptly — it bypasses the baseline mtime gate so shard-only edits (a read
    /// on another device) are pulled even when the baseline is unchanged.
    public func syncFromDisk() {
        guard let storage, !isRefreshing else { return }
        storage.startDownloadingLibraryIfNeeded()
        storage.startDownloadingStateIfNeeded()
        // reloadMerged decodes off-main and records the mod dates itself.
        Task { await reloadMerged() }
    }

    public func feed(for feedID: Feed.ID) -> Feed? {
        feeds.first { $0.id == feedID }
    }

    public func faviconImage(for feed: Feed) -> Image? {
        feedIcons[feed.id].map(Image.init(platformImage:))
    }

    /// All folder names (including empty ones), in natural order.
    public var feedFolders: [String] {
        folders.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    public func feeds(inFolder folder: String) -> [Feed] {
        feeds.filter { $0.folderName == folder }
            .sorted { $0.displayTitle.localizedStandardCompare($1.displayTitle) == .orderedAscending }
    }

    func feedCount(inFolder folder: String) -> Int {
        feeds.reduce(0) { $1.folderName == folder ? $0 + 1 : $0 }
    }

    public var ungroupedFeeds: [Feed] {
        feeds.filter { $0.folderName.isEmpty }
            .sorted { $0.displayTitle.localizedStandardCompare($1.displayTitle) == .orderedAscending }
    }

    public func createFolder(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !folders.contains(trimmed) else { return }
        folders.append(trimmed)
        recordFolder(trimmed, present: true)
        scheduleShardSave()
        saveAfterMutation()
    }

    /// Removes a folder and every feed inside it.
    public func removeFolder(_ name: String) {
        let removedIDs = Set(feeds.filter { $0.folderName == name }.map(\.id))
        feeds.removeAll { removedIDs.contains($0.id) }
        articles.removeAll { removedIDs.contains($0.feedID) }
        for id in removedIDs {
            feedIcons[id] = nil
            feedSelection.remove(id)
        }
        folders.removeAll { $0 == name }
        for id in removedIDs { recordFeedDeleted(id) }
        recordFolder(name, present: false)
        scheduleShardSave()
        pruneSelectionIfHidden()
        saveAfterMutation()
    }

    /// Renames a folder, moving every feed inside it to the new name. No-op if
    /// the new name is empty, unchanged, or already taken by another folder.
    public func renameFolder(_ oldName: String, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != oldName,
              folders.contains(oldName), !folders.contains(trimmed) else {
            return
        }
        for index in feeds.indices where feeds[index].folderName == oldName {
            feeds[index].category = trimmed
            recordCategory(feeds[index].id, trimmed)
        }
        if let index = folders.firstIndex(of: oldName) {
            folders[index] = trimmed
        }
        recordFolder(oldName, present: false)
        recordFolder(trimmed, present: true)
        scheduleShardSave()
        saveAfterMutation()
    }

    /// Moves a feed into a folder (empty string moves it back to top level).
    public func moveFeed(_ feedID: Feed.ID, toFolder folder: String) {
        guard let index = feeds.firstIndex(where: { $0.id == feedID }),
              feeds[index].category != folder else {
            return
        }
        feeds[index].category = folder
        recordCategory(feedID, folder)
        if !folder.isEmpty, !folders.contains(folder) {
            folders.append(folder)
            recordFolder(folder, present: true)
        }
        scheduleShardSave()
        saveAfterMutation()
    }

    /// Renames a feed. A trimmed non-empty name becomes the feed's custom title;
    /// an empty name clears the override so the feed-provided title is used again
    /// (and keeps updating on refresh). No-op if nothing changed.
    public func renameFeed(_ feedID: Feed.ID, to newName: String) {
        guard let index = feeds.firstIndex(where: { $0.id == feedID }) else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmed.isEmpty ? nil : trimmed
        guard feeds[index].customTitle != value else { return }
        feeds[index].customTitle = value
        recordCustomTitle(feedID, value)
        scheduleShardSave()
        saveAfterMutation()
    }

    public func isRefreshing(feedID: Feed.ID) -> Bool {
        spinningFeedIDs.contains(feedID)
    }

    /// A value that changes each time the feed gains new articles. The sidebar
    /// uses it as an animation trigger to flash the feed; a stable token means no
    /// new content, so no flash.
    public func feedUpdateToken(feedID: Feed.ID) -> Int {
        feedUpdateTokens[feedID] ?? 0
    }

    /// Marks a feed's fetch as in flight. `spinner` shows the per-feed spinner;
    /// automatic refreshes pass false so the icon stays put.
    private func beginFeedFetch(_ id: Feed.ID, spinner: Bool) {
        refreshingFeedIDs.insert(id)
        if spinner { spinningFeedIDs.insert(id) }
    }

    private func endFeedFetch(_ id: Feed.ID) {
        refreshingFeedIDs.remove(id)
        spinningFeedIDs.remove(id)
    }

    /// Bumps a feed's update token so the sidebar flashes it once. The token only
    /// moves when real new content arrives, so the flash never repeats on an
    /// unchanged refresh and needs no timer to clear.
    private func flashFeedUpdate(_ feedID: Feed.ID) {
        feedUpdateTokens[feedID, default: 0] += 1
    }

    /// Sets the per-feed reading-view override (`nil` = follow the global
    /// default) for one or more feeds, so their articles always open in the
    /// chosen mode without toggling each time.
    public func setPreferredViewMode(_ mode: ReaderViewMode?, feedIDs: [Feed.ID]) {
        var changed = false
        for id in feedIDs {
            guard let index = feeds.firstIndex(where: { $0.id == id }),
                  feeds[index].preferredViewMode != mode else { continue }
            feeds[index].preferredViewMode = mode
            recordViewMode(id, mode)
            changed = true
        }
        if changed {
            scheduleShardSave()
            saveAfterMutation()
        }
    }

    /// Total unread across every feed, used for the app icon badge.
    var totalUnreadCount: Int { totalUnread }

    /// Recomputes every sidebar count in one pass over `articles`. Called from
    /// the `articles` didSet so the cached values stay exact without the sidebar
    /// re-scanning all articles per badge, per render.
    private func recomputeCounts() {
        var byFeed: [Feed.ID: Int] = [:]
        var total = 0
        var today = 0
        var starred = 0
        let calendar = Calendar.current
        // Compute today's [start, next-midnight) once instead of re-deriving
        // calendar components per article via isDateInToday. Half-open interval
        // matches isDateInToday exactly (and the .today filter at line ~359).
        let startOfToday = calendar.startOfDay(for: Date())
        let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday)
        for article in articles {
            if !article.isRead {
                byFeed[article.feedID, default: 0] += 1
                total += 1
            }
            if article.isStarred { starred += 1 }
            if let startOfTomorrow {
                if article.publishedAt >= startOfToday && article.publishedAt < startOfTomorrow { today += 1 }
            } else if calendar.isDateInToday(article.publishedAt) {
                today += 1
            }
        }
        unreadByFeed = byFeed
        totalUnread = total
        todayCount = today
        starredCount = starred
    }

    /// Installed by the platform app to reflect the unread badge (macOS Dock,
    /// iOS app icon). Called with the count to show, or 0 to clear.
    @ObservationIgnored public var onUnreadBadgeChange: ((Int) -> Void)?

    /// The single writer of the unread badge. Invoked automatically whenever the
    /// article set or the preference changes (via their `didSet`), so the badge
    /// can never drift out of sync with the unread count — on launch, during a
    /// refresh, or when read state changes — regardless of view timing. The
    /// actual Dock/app-icon update is delegated to `onUnreadBadgeChange` so the
    /// core stays platform-agnostic.
    private func updateUnreadBadge() {
        onUnreadBadgeChange?(showsUnreadBadge ? totalUnreadCount : 0)
    }

    // MARK: - "Seen" tracking (notification suppression)

    /// Called by the platform app when foreground-active state changes. Becoming
    /// active marks the articles already on screen as seen (the user is looking
    /// at the synced list right now), so a later background refresh won't
    /// re-announce them.
    public func setForegroundActive(_ active: Bool) {
        guard active != isForegroundActive else { return }
        isForegroundActive = active
        if active { markVisibleArticlesSeen() }
    }

    /// While the app is foreground-active, records every currently-visible unread
    /// article as "seen" in this device's shard, so it never triggers a
    /// new-article notification later. Reads only in-memory `ownShard` (no disk
    /// I/O) and writes a register only for articles not already seen, so the
    /// common "nothing new on screen" case is a cheap scan. Seen state syncs to
    /// peers via the shard, suppressing the notification on the other device too.
    private func markVisibleArticlesSeen() {
        guard isForegroundActive, storage != nil else { return }
        var wrote = false
        for article in displayedArticles where !article.isRead {
            if ownShard.articleState[article.id]?.seen?.value == true { continue }
            ownShard.setArticleSeen(article.id, true, hlc: nextHLC())
            wrote = true
        }
        if wrote { scheduleShardSave() }
    }

    /// Article ids marked "seen" across every device's shard (peers + this
    /// device's authoritative in-memory shard). Used by the background refresh to
    /// skip notifying about articles the user already saw on any device.
    private func mergedSeenArticleIDs(storage: ReaderStorage) -> Set<Article.ID> {
        let merged = DeviceStateDocument.mergedState(from: observedShards(from: storage))
        var ids: Set<Article.ID> = []
        for (id, state) in merged.articles where state.seen?.value == true { ids.insert(id) }
        return ids
    }

    public func unreadCount(feedID: Feed.ID? = nil) -> Int {
        guard let feedID else { return totalUnread }
        return unreadByFeed[feedID] ?? 0
    }

    public func unreadCount(inFolder folder: String) -> Int {
        feeds.reduce(0) { $1.folderName == folder ? $0 + (unreadByFeed[$1.id] ?? 0) : $0 }
    }

    /// Selecting a folder selects all feeds inside it, so the article list
    /// shows the folder's combined articles.
    public func selectFolder(_ folder: String) {
        feedSelection = Set(feeds.filter { $0.folderName == folder }.map(\.id))
        clearRetainedArticles()
        pruneSelectionIfHidden()
    }

    public func isFolderSelected(_ folder: String) -> Bool {
        let ids = Set(feeds.filter { $0.folderName == folder }.map(\.id))
        return !ids.isEmpty && feedSelection == ids
    }

    public func count(for source: SmartSource) -> Int {
        switch source {
        case .unread: totalUnread
        case .today: todayCount
        case .starred: starredCount
        case .all: articles.count
        }
    }

    public func addFeed(urlString: String, toFolder folder: String = "") async throws {
        guard isStorageConfigured else {
            throw ReaderStorageError.noDirectorySelected
        }

        // Adding a feed takes priority over a full refresh: cancel any in-flight
        // one so the add isn't queued behind dozens of feed fetches (and its save
        // isn't held by the batch). Re-run the refresh afterward so the rest of
        // the feeds still update.
        let interruptedRefresh = isBatchRefreshing
        allFeedsRefreshTask?.cancel()

        let url = try feedService.normalizedFeedURL(from: urlString)
        // Reuse an existing feed's id when this URL normalizes to one we already
        // have (trailing slash / casing), so re-adding it doesn't split into a
        // duplicate feed identity. (OPML import already dedupes this way.)
        let existingFeedID = feeds.first {
            $0.feedURL.feedIdentityKey == url.feedIdentityKey || $0.siteURL.feedIdentityKey == url.feedIdentityKey
        }?.id
        let parsedFeed = try await fetch(url: url, existingFeedID: existingFeedID)
        if !folder.isEmpty {
            moveFeed(parsedFeed.feed.id, toFolder: folder)
        }
        feedSelection = [parsedFeed.feed.id]
        selectedArticleID = parsedFeed.articles.first?.id
        errorMessage = nil

        if interruptedRefresh {
            startAllFeedsRefresh()
        }
    }

    /// Result of a background refresh: how many genuinely new (previously
    /// unseen, unread) articles arrived, and their titles (most-recent first) for
    /// the notification summarizer.
    public struct BackgroundRefreshResult: Sendable {
        public let newArticleCount: Int
        public let sampleTitles: [String]
        public let articleIDs: [Article.ID]
        /// The value the app-icon badge should show — total unread (or 0 when the
        /// unread-badge preference is off). The delivered notification carries
        /// this so the badge reflects *all* unread articles, not just how many
        /// arrived this run, and stays correct even on a cold background launch
        /// where the store's badge callback isn't wired up.
        public let badgeCount: Int

        public init(
            newArticleCount: Int,
            sampleTitles: [String],
            articleIDs: [Article.ID] = [],
            badgeCount: Int = 0
        ) {
            self.newArticleCount = newArticleCount
            self.sampleTitles = sampleTitles
            self.articleIDs = articleIDs
            self.badgeCount = badgeCount
        }
    }

    /// Refreshes all feeds from a background launch and reports newly-arrived
    /// unread articles. Loads the library first if the process is fresh, and
    /// writes it synchronously so the result is saved before the OS suspends
    /// the app again.
    public func refreshForBackground() async -> BackgroundRefreshResult {
        if !didBootstrap { await bootstrap() }
        // The iOS background task runs with no visible UI but a tight OS time
        // budget, so fetch fast (like interactive) yet without animation.
        let result = await refreshAllReportingNew(mode: .background)
        // Write synchronously so the result is saved before the OS suspends the
        // app again (the iOS background-task caller depends on this).
        try? persistReplica()
        return result
    }

    /// Refreshes all feeds and reports the genuinely new (previously unseen,
    /// unread) articles that arrived, so a background refresher can decide
    /// whether to notify. Assumes the library is already loaded.
    public func refreshAllReportingNew(mode: RefreshMode = .ambient) async -> BackgroundRefreshResult {
        guard isStorageConfigured, !feeds.isEmpty else {
            return BackgroundRefreshResult(newArticleCount: 0, sampleTitles: [])
        }

        // Sync every content/state shard first, so an article
        // another device already fetched (and possibly read) is already known
        // here and isn't re-announced as new.
        await reloadMerged()
        // Already synced above; skip the redundant reload inside refreshAllFeeds.
        await refreshAllFeeds(syncFirst: false, mode: mode)
        try? persistReplica()
        // Never notify about an article the user already saw in the list on any
        // device — "seen" syncs via the shards, so it suppresses across devices.
        let seen = storage.map { mergedSeenArticleIDs(storage: $0) } ?? []
        let candidates = articles.filter { !$0.isRead && !seen.contains($0.id) }
        let fresh = (try? replicaStore?.reserveNotifications(for: candidates)) ?? []
        let sorted = fresh.sorted(by: Article.isOrderedBefore)
        return BackgroundRefreshResult(
            newArticleCount: fresh.count,
            // Carry enough titles for the summarizer to condense; it caps its own
            // input, and the plain-list fallback trims to a few lines.
            sampleTitles: sorted.prefix(12).map(\.title),
            articleIDs: fresh.map(\.id),
            badgeCount: showsUnreadBadge ? totalUnreadCount : 0
        )
    }

    public func markNotificationsDelivered(_ articleIDs: [Article.ID]) {
        try? replicaStore?.markNotificationsDelivered(articleIDs)
    }

    /// Article ids marked read in any device's on-disk shard. The read registers
    /// are keyed by article id, so this catches a peer's read even before the
    /// article itself has synced into this device's baseline.
    private func readArticleIDsAcrossShards() async -> Set<Article.ID> {
        guard let storage else { return [] }
        let shards = await Task.detached(priority: .userInitiated) {
            (try? storage.loadShards()) ?? []
        }.value
        var ids: Set<Article.ID> = []
        for shard in shards {
            for (id, state) in shard.articleState where state.isRead?.value == true {
                ids.insert(id)
            }
        }
        return ids
    }

    /// Parses an OPML file into feed candidates for the import preview. Returns
    /// an empty array (and sets `errorMessage`) on failure.
    public func parseOPML(at fileURL: URL) -> [OPMLFeed] {
        guard isStorageConfigured else {
            errorMessage = ReaderStorageError.noDirectorySelected.localizedDescription
            return []
        }

        let isAccessing = fileURL.startAccessingSecurityScopedResource()
        defer {
            if isAccessing {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let candidates = try opmlService.importFeeds(from: fileURL)
            errorMessage = nil
            return candidates
        } catch {
            errorMessage = error.localizedDescription
            return []
        }
    }

    /// Fetches and merges only the feeds the user chose in the import preview,
    /// deduplicating against existing feeds (their read/starred state is kept).
    public func importFeeds(_ opmlFeeds: [OPMLFeed]) {
        guard isStorageConfigured, !opmlFeeds.isEmpty else { return }

        Task {
            await importSelectedFeeds(opmlFeeds)
        }
    }

    public func handleOPMLExport(_ result: Result<URL, Error>) {
        switch result {
        case .success:
            errorMessage = nil
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }

    public func refreshAll() {
        guard !feeds.isEmpty else { return }
        startAllFeedsRefresh()
    }

    /// The in-flight full refresh, held so a higher-priority action (adding a
    /// feed) can cancel it and re-run it afterward.
    private var allFeedsRefreshTask: Task<Void, Never>?

    /// Feed items seen without a real publish date; a background pass tries to
    /// recover the real date from each article's page (see `resolveMissingDates`).
    private var datelessArticleIDs: Set<Article.ID> = []
    private var dateResolutionTask: Task<Void, Never>?
    private static let maxConcurrentDateResolutions = 4
    /// `UserDefaults` key for the "recover missing article dates" preference.
    public static let resolveMissingDatesKey = "resolveMissingArticleDates"

    private var resolvesMissingDates: Bool {
        UserDefaults.standard.object(forKey: Self.resolveMissingDatesKey) as? Bool ?? true
    }

    // MARK: - Reader-mode content (experimental)

    /// `UserDefaults` key for the "show reader-mode content by default"
    /// experiment. Shared so both platforms read the same flag. Defaults on.
    public static let readerContentByDefaultKey = "readerContentByDefault"

    /// `UserDefaults` key for the opt-in "press-and-hold the article body to open
    /// the in-app browser" gesture (iOS). Defaults off.
    public static let longPressOpensBrowserKey = "longPressOpensBrowser"

    /// Whether the native reader should show reader-mode-extracted content
    /// instead of the raw feed body by default.
    public var usesReaderContentByDefault: Bool {
        UserDefaults.standard.object(forKey: Self.readerContentByDefaultKey) as? Bool ?? true
    }

    /// The current reader-mode extraction state for an article (nil = not started).
    public func readerContentState(for article: Article) -> ReaderContentState? {
        readerContentStates[article.id]
    }

    /// Kicks off reader-mode extraction for an article when the experiment is on
    /// and we haven't already started (or finished) it this session. Idempotent.
    public func ensureReaderContent(for article: Article) {
        guard usesReaderContentByDefault else { return }
        guard readerContentStates[article.id] == nil else { return }
        readerContentStates[article.id] = .loading
        Task { await loadReaderContent(for: article, forceRefresh: false) }
    }

    /// Re-runs extraction for an article, bypassing the cache (the "Try Again"
    /// action on the fallback notice).
    public func retryReaderContent(for article: Article) {
        readerContentStates[article.id] = .loading
        Task { await loadReaderContent(for: article, forceRefresh: true) }
    }

    private func loadReaderContent(for article: Article, forceRefresh: Bool) async {
        if readerContentStore == nil, let storage {
            readerContentStore = ReaderContentStore(storage: storage, deviceID: deviceID)
        }

        // Let the reader's open/push transition finish before doing any heavy
        // main-thread work — the styled-text import (cache path) and the
        // extractor's offscreen WKWebView (miss path) both stall the slide-in if
        // run on the transition frame. The loading placeholder is already showing,
        // so this is invisible.
        try? await Task.sleep(for: .milliseconds(350))
        if Task.isCancelled { return }

        // Serve a synced/cached result first (from this device or a peer), so a
        // page already extracted anywhere isn't re-fetched.
        if !forceRefresh, let cached = await readerContentStore?.value(for: article.id) {
            if cached.status == .success, let html = cached.html, !html.isEmpty {
                await warmReaderContent(html: html, baseURL: article.url)
                readerContentStates[article.id] = .ready(html)
                // Cached content can outlive the source page. Check the original's
                // status in the background (non-blocking) and offer deletion if it
                // now returns 404/410 — a fresh extraction would catch this, but a
                // cache hit never re-fetches.
                revalidateCachedOriginal(article: article)
            } else {
                readerContentStates[article.id] = .failed
            }
            return
        }

        // Check the original's status up front. WKWebView can be served a cached
        // 200 for a page that's really gone (so extraction "succeeds" on the error
        // page and Try Again would show it as content) — an explicit HEAD 404/410
        // is authoritative, so treat it as gone without extracting.
        if await originalIsGone(url: article.url) {
            readerContentStates[article.id] = .gone
            await readerContentStore?.record(ReaderContentValue(status: .failed, html: nil), for: article.id)
            return
        }

        if readerModeExtractor == nil { readerModeExtractor = ReaderModeExtractor() }
        let outcome = await readerModeExtractor?.extract(url: article.url) ?? .failed
        switch outcome {
        case .success(let html) where !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
            // Parse into native blocks AND import their styled text into the caches
            // BEFORE flipping to .ready, so the reader renders fully styled from a
            // warm cache on the first frame — no parse or importer burst on the
            // transition frame, and no placeholder→styled reflow.
            await warmReaderContent(html: html, baseURL: article.url)
            readerContentStates[article.id] = .ready(html)
            await readerContentStore?.record(ReaderContentValue(status: .success, html: html), for: article.id)
        case .gone:
            // The original is gone (404/410); the reader will offer to delete it.
            readerContentStates[article.id] = .gone
            await readerContentStore?.record(ReaderContentValue(status: .failed, html: nil), for: article.id)
        default:
            readerContentStates[article.id] = .failed
            await readerContentStore?.record(ReaderContentValue(status: .failed, html: nil), for: article.id)
        }
    }

    /// Background HEAD check of a cached article's original URL. If the source now
    /// returns 404/410 the page is gone, so flip to `.gone` (offering deletion)
    /// while leaving the cached content up until then. Only ever downgrades from
    /// `.ready`.
    private func revalidateCachedOriginal(article: Article) {
        let id = article.id
        let url = article.url
        Task { [weak self] in
            guard let gone = await self?.originalIsGone(url: url), gone, let self else { return }
            if case .ready = self.readerContentStates[id] {
                self.readerContentStates[id] = .gone
            }
        }
    }

    /// Whether the article's original URL explicitly reports gone (404/410) via a
    /// lightweight HEAD request. Conservative: any other status, a rejected HEAD,
    /// or a transient error returns false, so a live page is never flagged.
    private func originalIsGone(url: URL) async -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 12
        let status = (try? await URLSession.shared.data(for: request))
            .flatMap { ($0.1 as? HTTPURLResponse)?.statusCode }
        return status == 404 || status == 410
    }

    /// Warms both caches the reader reads from before content is shown: the block
    /// parse (off-main) and the styled-text import for the above-the-fold blocks
    /// (main actor, but done here while the loading placeholder shows). By the time
    /// the state flips to `.ready`, the first screenful renders styled on the first
    /// frame — the transition carries no parse and no importer burst.
    private func warmReaderContent(html: String, baseURL: URL?) async {
        await warmReaderBlocks(html: html, baseURL: baseURL)
        // Only the first blocks matter for a burst-free open; the rest import
        // lazily as they scroll into view (off the entry frame).
        await HTMLContentText.warmReaderAttributedCache(html: html, baseURL: baseURL, maxBlocks: 14)
    }

    /// Parses reader HTML into native blocks off the main actor and stores them in
    /// the shared block cache, so `HTMLContentView` renders from a synchronous
    /// cache hit instead of parsing on the render/transition frame.
    private func warmReaderBlocks(html: String, baseURL: URL?) async {
        await Task.detached(priority: .userInitiated) {
            if HTMLBlockCache.shared.blocks(html: html, baseURL: baseURL) == nil {
                HTMLBlockCache.shared.store(
                    HTMLContentParser.parse(html, baseURL: baseURL),
                    html: html, baseURL: baseURL
                )
            }
        }.value
    }

    /// Starts (or restarts) a full refresh, replacing any in-flight one.
    private func startAllFeedsRefresh() {
        allFeedsRefreshTask?.cancel()
        allFeedsRefreshTask = Task { [weak self] in
            await self?.refreshAllFeeds()
        }
    }

    /// Shortest gap between activation-triggered syncs. Prevents rapidly
    /// switching focus back to Nook from refetching every feed on each focus
    /// change; the periodic auto-refresh still keeps content current.
    private static let activationRefreshThrottle: TimeInterval = 300

    private var activationRefreshInFlight = false

    /// Syncs all feeds in response to the app launching or returning to the
    /// foreground. `honorThrottle` skips the sync when the last refresh was very
    /// recent, so refocusing Nook repeatedly doesn't refetch every feed each
    /// time. Launch passes `false` so opening the app always fetches.
    ///
    /// `activationRefreshInFlight` is set synchronously before the async work
    /// starts so the launch sync and the initial `didBecomeActive` (which both
    /// fire at startup) coalesce into a single refresh instead of two.
    public func refreshOnActivation(honorThrottle: Bool) {
        guard isStorageConfigured, !feeds.isEmpty, !isRefreshing, !activationRefreshInFlight else { return }

        if honorThrottle, let lastRefreshedAt,
           Date.now.timeIntervalSince(lastRefreshedAt) < Self.activationRefreshThrottle {
            return
        }

        activationRefreshInFlight = true
        allFeedsRefreshTask?.cancel()
        allFeedsRefreshTask = Task { [weak self] in
            // Automatic focus-driven sync: stay quiet and light so returning to
            // Nook doesn't jolt the UI while content trickles in.
            await self?.refreshAllFeeds(mode: .ambient)
            self?.activationRefreshInFlight = false
            // Re-opening after a long background can hit a network that isn't
            // ready yet, failing some feeds transiently. Retry just those once,
            // quietly, after a short delay — so a long-suspended launch still ends
            // up refreshed without any user action or alert.
            await self?.retryFailedFeedsOnce()
        }
    }

    private var isRetryingFailedFeeds = false

    /// One quiet retry of the feeds that failed the last refresh (marked
    /// unhealthy), a few seconds later. Recovers transient post-background
    /// failures; a persistently-broken feed just re-flags itself (no alert).
    private func retryFailedFeedsOnce() async {
        guard !isRetryingFailedFeeds else { return }
        let failed = feeds.filter { $0.healthScore <= 0 }.map(\.id)
        guard !failed.isEmpty else { return }
        isRetryingFailedFeeds = true
        defer { isRetryingFailedFeeds = false }
        try? await Task.sleep(for: .seconds(4))
        guard !Task.isCancelled else { return }
        for feed in failed.compactMap(feed(for:)) {
            if Task.isCancelled { return }
            await refreshFeed(feed)
        }
    }

    func refresh(feedID: Feed.ID) {
        guard feed(for: feedID) != nil else { return }
        feedSelection = [feedID]

        Task {
            // Sync first so the save can't drop a peer-added feed; re-resolve the
            // feed after the merge in case its stored URL changed.
            await reloadMerged()
            if let feed = feed(for: feedID) { await refreshFeed(feed) }
        }
    }

    public func refreshFeeds(ids: [Feed.ID]) {
        guard ids.contains(where: { feed(for: $0) != nil }) else { return }
        Task {
            await reloadMerged()
            for feed in ids.compactMap(feed(for:)) {
                await refreshFeed(feed)
            }
        }
    }

    /// Awaitable refresh of all feeds, for pull-to-refresh (the spinner stays
    /// until the fetch actually finishes).
    public func refreshAllAndWait() async {
        guard !feeds.isEmpty else { return }
        await refreshAllFeeds()
    }

    /// Awaitable refresh of specific feeds, for pull-to-refresh in a single
    /// feed's article list.
    public func refreshFeedsAndWait(ids: [Feed.ID]) async {
        await reloadMerged()
        for feed in ids.compactMap(feed(for:)) {
            await refreshFeed(feed)
        }
    }

    public func markFeedsRead(ids: [Feed.ID]) {
        ids.forEach { markFeedRead(feedID: $0) }
    }

    public func removeFeeds(ids: [Feed.ID]) {
        ids.forEach { removeFeed(feedID: $0) }
    }

    /// Deletes a single article the user no longer wants — used when the original
    /// page is gone (404/410) but the local copy lingers. Records a tombstone in
    /// this device's shard so the deletion syncs and the baseline (which still
    /// carries the article) can't resurrect it at the next merge.
    public func deleteArticle(articleID: Article.ID) {
        guard articles.contains(where: { $0.id == articleID }) else { return }
        if selectedArticleID == articleID { selectedArticleID = nil }
        articles.removeAll { $0.id == articleID }
        readerContentStates[articleID] = nil
        retainedArticleIDs.remove(articleID)
        recordArticleDeleted(articleID)
        scheduleShardSave()
    }

    public func markArticleOpened(articleID: Article.ID) {
        setRead(articleID: articleID, isRead: true)
    }

    /// Keeps an article visible in the current source even once it is read, so
    /// it does not vanish out from under the reader while it is being viewed.
    public func retainArticle(id: Article.ID) {
        retainedArticleIDs.insert(id)
    }

    /// Drops the retained set so the list recomputes fresh; called when the
    /// selected source changes.
    public func clearRetainedArticles() {
        guard !retainedArticleIDs.isEmpty else { return }
        retainedArticleIDs.removeAll()
    }

    /// Opens an article by ID (used by the widget deep link): makes it visible
    /// and selects it so the reader displays it. The reader then marks it read.
    func openArticle(id: Article.ID) {
        guard articles.contains(where: { $0.id == id }) else { return }
        smartSelection = .all
        feedSelection = []
        searchText = ""
        searchDebounceTask?.cancel()
        activeSearchQuery = ""
        selectedArticleID = id
    }

    public func setRead(articleID: Article.ID, isRead: Bool) {
        guard let index = articles.firstIndex(where: { $0.id == articleID }),
              articles[index].isRead != isRead else { return }

        articles[index].isRead = isRead
        recordRead(articleID, isRead)
        // Read state is user state: it lives in this device's shard and is
        // overlaid on the baseline at materialize, so there's no need to rewrite
        // content shards for a read toggle.
        scheduleShardSave()
    }

    public func markSelectedRead() {
        guard let selectedArticleID else { return }
        setRead(articleID: selectedArticleID, isRead: true)
    }

    func removeFeed(feedID: Feed.ID) {
        feeds.removeAll { $0.id == feedID }
        articles.removeAll { $0.feedID == feedID }
        feedIcons[feedID] = nil
        endFeedFetch(feedID)
        feedUpdateTokens[feedID] = nil

        feedSelection.remove(feedID)

        recordFeedDeleted(feedID)
        scheduleShardSave()
        pruneSelectionIfHidden()
        saveAfterMutation()
    }

    func markFeedRead(feedID: Feed.ID) {
        var didChange = false
        for index in articles.indices where articles[index].feedID == feedID {
            if !articles[index].isRead {
                articles[index].isRead = true
                recordRead(articles[index].id, true)
                didChange = true
            }
        }

        if didChange {
            // Per-article read state is shard-backed; no baseline rewrite needed.
            scheduleShardSave()
        }
    }

    public func toggleSelectedStarred() {
        guard let selectedArticleID else { return }
        toggleStarred(articleID: selectedArticleID)
    }

    public func toggleStarred(articleID: Article.ID) {
        guard let article = articles.first(where: { $0.id == articleID }) else { return }
        setStarred(articleID: articleID, isStarred: !article.isStarred)
    }

    public func setStarred(articleID: Article.ID, isStarred: Bool) {
        guard let index = articles.firstIndex(where: { $0.id == articleID }),
              articles[index].isStarred != isStarred else { return }

        articles[index].isStarred = isStarred
        recordStarred(articleID, isStarred)
        // Starred state is user state (shard-backed, overlaid at materialize);
        // no baseline rewrite needed.
        scheduleShardSave()
    }

    /// Clears the article selection if it is no longer in the visible list.
    ///
    /// It deliberately does NOT auto-select the first article. Launching the app
    /// (or changing source/filter) should show the list with the reader empty
    /// until the user picks an article — otherwise an article opens on its own
    /// and gets marked read via `markReadOnOpen` every time the app starts.
    public func pruneSelectionIfHidden() {
        guard let selectedArticleID else { return }
        if !visibleArticles.contains(where: { $0.id == selectedArticleID }) {
            self.selectedArticleID = nil
        }
    }

    public func selectNextArticle() {
        moveSelection(offset: 1)
        syncBrowserModeToSelection()
    }

    /// When the in-app browser is open, advancing to another article must
    /// re-resolve the reading mode for the new article's feed; otherwise it keeps
    /// the previous article's mode instead of following the feed/global setting.
    private func syncBrowserModeToSelection() {
        guard isBrowserPresented, let article = selectedArticle else { return }
        browserMode = resolvedBrowserMode(for: article)
    }

    /// The live article for an ID from the full set (not the filtered visible
    /// list), so a reader driven by a captured snapshot can re-resolve fresh
    /// read/starred state even after the article leaves the current scope.
    public func article(withID id: Article.ID) -> Article? {
        articles.first { $0.id == id }
    }

    /// The article shown right after `id` in the current visible list, or nil if
    /// `id` is the last one. Lets the UI preview what "next" would open.
    public func article(after id: Article.ID) -> Article? {
        let visible = visibleArticles
        guard let index = visible.firstIndex(where: { $0.id == id }), index + 1 < visible.count else {
            return nil
        }
        return visible[index + 1]
    }

    /// The article shown right before `id` in the current visible list, or nil if
    /// `id` is the first one. Lets the native reader preview "previous".
    public func article(before id: Article.ID) -> Article? {
        let visible = visibleArticles
        guard let index = visible.firstIndex(where: { $0.id == id }), index > 0 else {
            return nil
        }
        return visible[index - 1]
    }

    public func selectPreviousArticle() {
        moveSelection(offset: -1)
        syncBrowserModeToSelection()
    }

    public func readBinding(articleID: Article.ID) -> Binding<Bool> {
        Binding {
            self.articles.first { $0.id == articleID }?.isRead ?? false
        } set: { isRead in
            self.setRead(articleID: articleID, isRead: isRead)
        }
    }

    public func starredBinding(articleID: Article.ID) -> Binding<Bool> {
        Binding {
            self.articles.first { $0.id == articleID }?.isStarred ?? false
        } set: { isStarred in
            self.setStarred(articleID: articleID, isStarred: isStarred)
        }
    }

    private func restoreStorageIfPossible() async {
        do {
            guard let directoryURL = try ReaderStorage.resolveBookmarkedDirectory() else {
                syncFolderDisplayPath = UserDefaults.standard.string(forKey: ReaderStorage.displayPathDefaultsKey)
                return
            }

            startAccessing(directoryURL)
            let storage = ReaderStorage(directoryURL: directoryURL)
            self.storage = storage
            syncFolderDisplayPath = directoryURL.path(percentEncoded: false)

            restoreOwnShard(storage: storage)
            let replica = try ReplicaStore(syncDirectory: directoryURL, deviceID: deviceID)
            replicaStore = replica
            let snapshot = try await Task.detached(priority: .userInitiated) {
                let snapshot = try replica.reconcile(storage: storage)
                try replica.publishIfNeeded(to: storage)
                return snapshot
            }.value
            try migrateLegacyUserStateIfNeeded(replica: replica, storage: storage)
            applyReplicaSnapshot(snapshot, storage: storage)
            lastKnownLibraryModDate = storage.libraryModificationDate
            lastKnownStateModDate = storage.stateDirectoryModificationDate
            lastKnownContentModDate = storage.contentDirectoryModificationDate
            lastKnownBodiesModDate = storage.bodiesDirectoryModificationDate
            startObservingLibrary()
            // The list is up from the light baseline; pull the (heavier) article
            // bodies in from the sidecar in the background so it never blocks.
            Task { await loadBodyCacheIfNeeded() }
            let readerStore = ReaderContentStore(storage: storage, deviceID: deviceID)
            readerContentStore = readerStore
            Task { await readerStore.reload() }
        } catch {
            errorMessage = error.localizedDescription
            syncFolderDisplayPath = UserDefaults.standard.string(forKey: ReaderStorage.displayPathDefaultsKey)
        }
    }

    private func startAccessing(_ directoryURL: URL) {
        if isAccessingSecurityScopedResource {
            securityScopedDirectoryURL?.stopAccessingSecurityScopedResource()
        }

        securityScopedDirectoryURL = directoryURL
        isAccessingSecurityScopedResource = directoryURL.startAccessingSecurityScopedResource()
    }

    private func importSelectedFeeds(_ opmlFeeds: [OPMLFeed]) async {
        var failures: [String] = []

        for opmlFeed in opmlFeeds {
            do {
                let existingFeedID = feeds.first { existing in
                    existing.feedURL.feedIdentityKey == opmlFeed.feedURL.feedIdentityKey
                        || existing.id == opmlFeed.feedURL.absoluteString
                        || (opmlFeed.siteURL.map { existing.siteURL.feedIdentityKey == $0.feedIdentityKey } ?? false)
                }?.id
                let parsed = try await fetch(url: opmlFeed.feedURL, existingFeedID: existingFeedID)

                // Carry the OPML folder over as the feed's category/folder.
                if let category = opmlFeed.category, !category.isEmpty,
                   let index = feeds.firstIndex(where: { $0.id == parsed.feed.id }) {
                    feeds[index].category = category
                    if !folders.contains(category) {
                        folders.append(category)
                    }
                }
            } catch {
                failures.append(error.localizedDescription)
            }
        }

        errorMessage = failures.isEmpty ? nil : String(localized: "Couldn't add \(failures.count) feeds", bundle: Bundle.module)
        scheduleSave()
    }

    private func refreshAllFeeds(syncFirst: Bool = true, mode: RefreshMode = .interactive) async {
        // Pull the latest content + state shards before fetching, so the save at
        // the end can't clobber a feed another device just added but that hasn't
        // reached this device's in-memory list yet. (Callers that already synced
        // — e.g. the background reporter — pass false to avoid a redundant read.)
        if syncFirst { await reloadMerged() }
        // Hold per-feed writes and flush once at the end, so a refresh of many
        // feeds doesn't rewrite the whole library repeatedly. `defer` guarantees
        // the flag clears and the final state is saved even on early exit.
        isBatchRefreshing = true
        defer {
            isBatchRefreshing = false
            // One immediate (non-debounced) filter now that the whole batch has
            // merged, so the list settles at once instead of after the debounce.
            // Counts/badge already stayed live via the `articles` didSet.
            scheduleArticleFilter()
            scheduleSave()
        }

        // Fetch feeds concurrently (bounded) — the network is the slow part and
        // `RSSFeedService` is a `Sendable` value, so fetches run off the main
        // actor in parallel while each result is merged back here serially. This
        // keeps a many-feed refresh inside iOS's background budget; a sequential
        // fetch serialized every feed's up-to-15s timeout and timed out first.
        let targets = feeds.map { (id: $0.id, url: $0.feedURL) }
        guard !targets.isEmpty else { return }
        let service = feedService
        // `Error` isn't `Sendable`, so a child task returns the parsed feed or an
        // error message string across the actor boundary, never the error itself.
        await withTaskGroup(of: (Feed.ID, ParsedFeed?, String?).self) { group in
            // Only the network fetch runs off the main actor; touching
            // `refreshingFeedIDs` stays in the main-isolated group body below.
            func launch(_ target: (id: Feed.ID, url: URL)) {
                group.addTask(priority: mode.fetchPriority) {
                    do {
                        var parsed = try await service.fetch(url: target.url)
                        parsed.feed.id = target.id
                        return (target.id, parsed, nil)
                    } catch {
                        return (target.id, nil, error.localizedDescription)
                    }
                }
            }
            var next = 0
            let limit = min(mode.maxConcurrentFetches, targets.count)
            while next < limit {
                // Mark in-flight so `isRefreshing` tracks the concurrent fetch; the
                // per-feed spinner shows only for user-initiated refreshes.
                beginFeedFetch(targets[next].id, spinner: mode.showsSpinner)
                launch(targets[next])
                next += 1
            }
            while let (feedID, parsed, _) = await group.next() {
                endFeedFetch(feedID)
                // Cancelled (e.g. the user tapped "Add Feed"): stop launching more
                // fetches and drain the in-flight ones without touching state, so
                // a cancel yields promptly and doesn't mark feeds unhealthy on the
                // way out. The interrupted refresh re-runs on the next turn.
                if Task.isCancelled {
                    continue
                }
                if let parsed {
                    merge(parsed, animated: mode.animatesInsertion)
                    ensureFavicon(for: parsed.feed)
                    lastRefreshedAt = Date.now
                    pruneSelectionIfHidden()
                } else {
                    // A refresh failure (offline, HTTP host down, parse error) must
                    // never interrupt the user: don't surface a global alert. Just
                    // flag the feed unhealthy so the list can show a quiet
                    // sync-failed indicator; the flag clears on the next successful
                    // refresh (merge resets healthScore).
                    markFeedUnhealthy(feedID: feedID)
                }
                if next < targets.count {
                    beginFeedFetch(targets[next].id, spinner: mode.showsSpinner)
                    launch(targets[next])
                    next += 1
                }
            }
        }

        // Recover real dates for any dateless items just merged — but not on the
        // iOS background task, whose tight time budget is for fetching + notifying.
        if mode != .background { resolveMissingDates() }
    }

    @discardableResult
    private func fetch(url: URL, existingFeedID: Feed.ID?) async throws -> ParsedFeed {
        let refreshID = existingFeedID ?? url.absoluteString
        // Single-feed fetches are always user-initiated (add feed, refresh this
        // feed), so the spinner is expected feedback.
        beginFeedFetch(refreshID, spinner: true)
        defer {
            endFeedFetch(refreshID)
        }

        var parsedFeed = try await feedService.fetch(url: url)
        if let existingFeedID, existingFeedID != parsedFeed.feed.id {
            // Re-key onto the existing feed's id atomically: the article ids are
            // built as "\(feed.id)#\(seed)", so re-keying only the feed would leave
            // every article pointing at the old (now absent) feed id — an orphan
            // ("Unknown Feed"). Re-key the feed AND every article's feedID/id.
            let oldID = parsedFeed.feed.id
            let oldPrefix = oldID + "#"
            parsedFeed.feed.id = existingFeedID
            parsedFeed.articles = parsedFeed.articles.map { article in
                var article = article
                let seed = article.id.hasPrefix(oldPrefix) ? String(article.id.dropFirst(oldPrefix.count)) : article.id
                article.feedID = existingFeedID
                article.id = "\(existingFeedID)#\(seed)"
                return article
            }
        }

        merge(parsedFeed)
        ensureFavicon(for: parsedFeed.feed)
        lastRefreshedAt = Date.now
        scheduleSave()
        pruneSelectionIfHidden()
        return parsedFeed
    }

    private func refreshFeed(_ feed: Feed) async {
        do {
            _ = try await fetch(url: feed.feedURL, existingFeedID: feed.id)
        } catch {
            // A refresh failure stays quiet (no global alert) — just flag the feed
            // so the list shows a sync-failed indicator; it clears on next success.
            markFeedUnhealthy(feedID: feed.id)
        }
    }

    /// For feed items that shipped no date, fetch each article page once (bounded,
    /// low priority) and read a real publish date from it. Fills in the article's
    /// timestamp when found; every page is fetched at most once (attempts are
    /// recorded), and network failures stay unrecorded so a later pass retries.
    private func resolveMissingDates() {
        guard resolvesMissingDates, let replicaStore, isStorageConfigured else { return }
        let candidates = Array(datelessArticleIDs)
        guard !candidates.isEmpty else { return }
        dateResolutionTask?.cancel()
        dateResolutionTask = Task { [weak self] in
            await self?.performDateResolution(candidates: candidates, replicaStore: replicaStore)
        }
    }

    private func performDateResolution(candidates: [Article.ID], replicaStore: ReplicaStore) async {
        let pending = (try? replicaStore.articleIDsNeedingDateResolution(candidates)) ?? []
        guard !pending.isEmpty else { return }
        let urlByID = Dictionary(articles.map { ($0.id, $0.url) }, uniquingKeysWith: { first, _ in first })
        let targets = pending.compactMap { id in urlByID[id].map { (id: id, url: $0) } }
        guard !targets.isEmpty else { return }

        let session = URLSession.shared
        var resolved: [Article.ID: Date] = [:]
        var attempted: [Article.ID] = []
        // Bool = the page actually loaded (mark attempted); a network failure
        // leaves it unmarked so a later pass retries.
        await withTaskGroup(of: (Article.ID, Date?, Bool).self) { group in
            func launch(_ target: (id: Article.ID, url: URL)) {
                group.addTask(priority: .utility) {
                    do {
                        let date = try await ArticleDateResolver.publishedDate(for: target.url, session: session)
                        return (target.id, date, true)
                    } catch {
                        return (target.id, nil, false)
                    }
                }
            }
            var next = 0
            let limit = min(Self.maxConcurrentDateResolutions, targets.count)
            while next < limit { launch(targets[next]); next += 1 }
            while let (id, date, loaded) = await group.next() {
                if Task.isCancelled { break }
                if loaded {
                    attempted.append(id)
                    if let date { resolved[id] = date }
                }
                if next < targets.count { launch(targets[next]); next += 1 }
            }
        }

        guard !Task.isCancelled else { return }
        if !resolved.isEmpty {
            articles = articles.map { article in
                guard let date = resolved[article.id] else { return article }
                var updated = article
                updated.publishedAt = date
                updated.hasExplicitPublishDate = true
                return updated
            }
            scheduleSave()
        }
        if !attempted.isEmpty {
            try? replicaStore.markDateResolutionAttempted(attempted)
            for id in attempted { datelessArticleIDs.remove(id) }
        }
    }

    private func merge(_ parsedFeed: ParsedFeed, animated: Bool = true) {
        let feedID = parsedFeed.feed.id
        // Whether this feed already had articles before the merge. A brand-new
        // feed's first batch shouldn't flash (nothing "arrived" for the user yet);
        // only a feed that already existed and now gains items should.
        let feedHadArticles = articles.contains { $0.feedID == feedID }

        if let feedIndex = feeds.firstIndex(where: { $0.id == parsedFeed.feed.id }) {
            var updated = parsedFeed.feed
            // Preserve the user's per-feed settings across refreshes; a freshly
            // parsed feed always has an empty category and no view preference.
            updated.category = feeds[feedIndex].category
            updated.preferredViewMode = feeds[feedIndex].preferredViewMode
            updated.customTitle = feeds[feedIndex].customTitle
            feeds[feedIndex] = updated
            // Keep the shard's seed current so every known feed's membership is
            // CRDT-protected (deduplicated, so an unchanged refresh is a no-op).
            recordFeedSeed(updated)
        } else {
            feeds.append(parsedFeed.feed)
            // A feed appearing for the first time in memory clears any stale
            // deletion tombstone for the same URL (feed ids are the URL), so
            // re-adding a previously removed feed isn't suppressed at materialize
            // by the old delete. The fresh HLC also beats a peer's older delete.
            recordFeedRestored(parsedFeed.feed.id)
            recordFeedSeed(parsedFeed.feed)
            scheduleShardSave()
        }

        // Last-writer-wins on a duplicate ID rather than trapping — a dupe slipping
        // through the baseline/shard merge must degrade, not crash the next refresh.
        var existingArticlesByID = Dictionary(articles.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        let knownIDs = Set(existingArticlesByID.keys)
        var hasNewArticles = false
        for newArticle in parsedFeed.articles {
            var article = newArticle
            if let existing = existingArticlesByID[article.id] {
                article.isRead = existing.isRead
                article.isStarred = existing.isStarred
                // Only pin the timestamp when the feed gave no real date (we
                // stamped a synthetic first-seen time): re-stamping it each
                // refresh would jump the article to "now" and reshuffle the list.
                // When the feed DOES supply a date, keep the freshly parsed one —
                // it's authoritative and stable, and self-corrects a value that a
                // past parse got wrong.
                if !article.hasExplicitPublishDate {
                    article.publishedAt = existing.publishedAt
                }
            } else {
                hasNewArticles = true
            }
            // Track feed items that shipped no date so a background pass can try
            // to recover the real one from the article page.
            if !article.hasExplicitPublishDate {
                datelessArticleIDs.insert(article.id)
            }
            existingArticlesByID[article.id] = article
        }

        let merged = Array(existingArticlesByID.values)
        // Animate the list only for interactive refreshes that bring in new
        // stories, so rows slide/fade in like Apple Mail. Automatic (ambient/
        // background) refreshes pass `animated: false` so new rows appear quietly
        // instead of sliding under the user mid-scroll.
        if animated && hasNewArticles && !knownIDs.isEmpty {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                articles = merged
            }
        } else {
            articles = merged
        }

        // Flash the feed in the sidebar when a refresh actually brought in new
        // articles. This is the only visual signal for automatic refreshes (they
        // show no spinner), so an unchanged refresh stays completely silent.
        if hasNewArticles && feedHadArticles {
            flashFeedUpdate(feedID)
        }

        // Keep the body cache current with freshly fetched content, so a later
        // re-merge (which reloads the list-light baseline) restores these bodies
        // rather than blanking them until the next refresh.
        for article in parsedFeed.articles where article.hasBody {
            bodyCache[article.id] = article.body
        }
    }

    private func markFeedUnhealthy(feedID: Feed.ID) {
        guard let index = feeds.firstIndex(where: { $0.id == feedID }) else { return }
        feeds[index].healthScore = 0
        saveAfterMutation()
    }

    private func moveSelection(offset: Int) {
        let visible = visibleArticles
        guard !visible.isEmpty else {
            selectedArticleID = nil
            return
        }

        guard let selectedArticleID,
              let currentIndex = visible.firstIndex(where: { $0.id == selectedArticleID }) else {
            self.selectedArticleID = visible.first?.id
            return
        }

        let nextIndex = min(max(currentIndex + offset, visible.startIndex), visible.index(before: visible.endIndex))
        self.selectedArticleID = visible[nextIndex].id
    }

    /// Debounces search input: an empty query clears instantly for a snappy
    /// reset, otherwise the filter waits until the user pauses typing. Setting
    /// `activeSearchQuery` triggers the (possibly background) refilter.
    public func debounceSearch() {
        searchDebounceTask?.cancel()

        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            searchDebounceTask = nil
            activeSearchQuery = ""
            return
        }

        searchDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            self.activeSearchQuery = self.searchText
        }
    }

    private func apply(_ library: ReaderLibrary) {
        // Repair any feeds whose stored URLs have a doubled scheme (from an
        // earlier bug) so they fetch correctly instead of flooding failed
        // requests. `id` is left untouched so existing articles stay linked.
        var repairedFeeds = library.feeds
        var didRepair = false
        for index in repairedFeeds.indices {
            let fixedFeed = RSSFeedService.repairedWebURL(repairedFeeds[index].feedURL)
            let fixedSite = RSSFeedService.repairedWebURL(repairedFeeds[index].siteURL)
            if fixedFeed != repairedFeeds[index].feedURL { repairedFeeds[index].feedURL = fixedFeed; didRepair = true }
            if fixedSite != repairedFeeds[index].siteURL { repairedFeeds[index].siteURL = fixedSite; didRepair = true }
        }

        feeds = repairedFeeds
        articles = library.articles
        lastRefreshedAt = library.lastRefreshedAt
        // Merge explicit folders with any folders implied by feed categories.
        let feedFolderNames = feeds.map(\.folderName).filter { !$0.isEmpty }
        folders = Array(Set(library.folders + feedFolderNames))
        loadCachedFavicons()

        if didRepair { scheduleSave() }
    }

    private func loadCachedFavicons() {
        guard let storage else { return }
        // Only feeds without an in-memory icon need any disk work. Re-reading
        // every favicon on each merge (apply runs on every sync) needlessly
        // thrashed iCloud — and did the reads synchronously on the main actor,
        // which blocked (a spinning cursor) whenever a file had been evicted.
        let missing = feeds.filter { feedIcons[$0.id] == nil }
        guard !missing.isEmpty else { return }
        let items = missing.map { (id: $0.id, key: faviconKey(for: $0)) }

        Task { [weak self] in
            // Read the cached bytes (and the TTL check) off the main actor; the
            // small PNG decode then happens back on the main actor (Data is
            // Sendable, the platform image type isn't).
            let outcome = await Task.detached(priority: .userInitiated) { () -> [(id: Feed.ID, key: String, data: Data?, needsFetch: Bool)] in
                items.map { item in
                    let data = storage.cachedFaviconData(forKey: item.key)
                    let needsFetch = data == nil && storage.faviconNeedsRefresh(forKey: item.key)
                    return (item.id, item.key, data, needsFetch)
                }
            }.value
            guard let self else { return }

            for entry in outcome {
                if let data = entry.data, let image = makePlatformImage(data: data) {
                    self.feedIcons[entry.id] = image
                }
            }
            // Fetch over the network only when there's no cached icon at all and
            // the TTL allows a retry — a cached icon is used as-is, never
            // re-downloaded just because the app synced again.
            for entry in outcome where entry.needsFetch && !self.faviconAttemptedKeys.contains(entry.key) {
                guard let feed = self.feed(for: entry.id) else { continue }
                self.faviconAttemptedKeys.insert(entry.key)
                self.faviconQueue.append(feed)
            }
            self.pumpFaviconQueue()
        }
    }

    /// Shows any cached favicon immediately, then queues a background refresh
    /// when it is missing or older than the 1-day TTL. Refreshes are keyed by
    /// host, deduplicated, and rate-limited so opening a large library doesn't
    /// fire hundreds of concurrent (and often duplicate) network requests.
    private func ensureFavicon(for feed: Feed) {
        guard let storage else { return }
        let key = faviconKey(for: feed)

        if feedIcons[feed.id] == nil,
           let data = storage.cachedFaviconData(forKey: key),
           let image = makePlatformImage(data: data) {
            feedIcons[feed.id] = image
        }

        // One attempt per host per session: many feeds can share a host, and a
        // host that failed shouldn't be retried repeatedly.
        guard storage.faviconNeedsRefresh(forKey: key), !faviconAttemptedKeys.contains(key) else {
            return
        }
        faviconAttemptedKeys.insert(key)
        faviconQueue.append(feed)
        pumpFaviconQueue()
    }

    /// Starts queued favicon fetches up to the concurrency cap.
    private func pumpFaviconQueue() {
        while activeFaviconFetches < Self.maxConcurrentFaviconFetches, !faviconQueue.isEmpty {
            let feed = faviconQueue.removeFirst()
            activeFaviconFetches += 1
            Task { [weak self] in
                await self?.refreshFavicon(for: feed)
                guard let self else { return }
                self.activeFaviconFetches -= 1
                self.pumpFaviconQueue()
            }
        }
    }

    private func refreshFavicon(for feed: Feed) async {
        let key = faviconKey(for: feed)
        guard let data = await faviconService.fetchFavicon(for: feed.siteURL),
              let image = makePlatformImage(data: data) else {
            // Remember the failure so we don't re-hammer this host next launch.
            storage?.recordFaviconMiss(forKey: key)
            return
        }

        let pngData = image.pngData() ?? data
        try? storage?.writeFaviconData(pngData, forKey: key)
        let finalImage = makePlatformImage(data: pngData) ?? image
        // Apply to every feed that shares this host, so we fetch each icon once.
        for sibling in feeds where faviconKey(for: sibling) == key {
            feedIcons[sibling.id] = finalImage
        }
    }

    private func faviconKey(for feed: Feed) -> String {
        let base = feed.siteURL.host(percentEncoded: false) ?? feed.id
        let sanitized = base.map { character -> Character in
            character.isLetter || character.isNumber || character == "." || character == "-" ? character : "_"
        }
        return String(sanitized)
    }

    private func snapshotLibrary() -> ReaderLibrary {
        ReaderLibrary(
            feeds: feeds,
            articles: articles,
            lastRefreshedAt: lastRefreshedAt,
            folders: folders
        )
    }

    private func saveAfterMutation() {
        scheduleSave()
    }

    /// Schedules a background write of the latest library snapshot. Encoding
    /// and the coordinated file write happen off the main actor, and rapid
    /// mutations (e.g. during a full refresh) are coalesced so only the most
    /// recent state is written — keeping the UI lag-free while syncing.
    private func scheduleSave() {
        guard let storage else { return }
        // Always capture the latest snapshot (cheap: arrays are copy-on-write)...
        pendingSave = snapshotLibrary()
        // ...but hold the actual write until a batch refresh flushes it once.
        guard !isBatchRefreshing else { return }
        guard !isDrainingSaves else { return }
        isDrainingSaves = true
        Task { await drainSaves(storage: storage) }
    }

    private func drainSaves(storage: ReaderStorage) async {
        // Pause if a batch refresh starts mid-drain; the held snapshot stays in
        // `pendingSave` and is flushed once when the batch finishes.
        while !isBatchRefreshing, let library = pendingSave {
            pendingSave = nil
            guard let replicaStore else { continue }
            let outcome = await Task.detached(priority: .utility) { () -> (ReplicaSnapshot?, Date?) in
                let snapshot = try? replicaStore.recordLocal(
                    library,
                    retainBodies: ReaderStore.recentArticleIDs(from: library.articles)
                )
                try? replicaStore.publishIfNeeded(to: storage)
                return (snapshot, storage.contentDirectoryModificationDate)
            }.value
            if let revision = outcome.0?.revision { appliedReplicaRevision = max(appliedReplicaRevision, revision) }
            lastKnownContentModDate = outcome.1
            errorMessage = nil
        }
        isDrainingSaves = false
    }

    /// Writes the library immediately on the calling actor. Used only for the
    /// initial file creation when configuring a folder, where later code
    /// depends on the file already existing.
    private func persistReplica() throws {
        guard let storage, let replicaStore else {
            throw ReaderStorageError.noDirectorySelected
        }
        let snapshot = try replicaStore.recordLocal(
            snapshotLibrary(),
            retainBodies: Self.recentArticleIDs(from: articles)
        )
        try replicaStore.publishIfNeeded(to: storage)
        appliedReplicaRevision = max(appliedReplicaRevision, snapshot.revision)
        lastKnownContentModDate = storage.contentDirectoryModificationDate
    }

    // MARK: - Recording user-state changes into this device's shard

    /// Issues the next monotonic HLC for a local write, always strictly greater
    /// than anything this device has issued or observed.
    private func nextHLC() -> HLC {
        lastHLC = HLC.next(after: lastHLC, node: deviceID)
        ownShard.clock = lastHLC
        return lastHLC
    }

    private func recordRead(_ id: Article.ID, _ value: Bool) {
        ownShard.setArticleRead(id, value, hlc: nextHLC())
    }

    private func recordStarred(_ id: Article.ID, _ value: Bool) {
        ownShard.setArticleStarred(id, value, hlc: nextHLC())
    }

    private func recordArticleDeleted(_ id: Article.ID) {
        ownShard.setArticleTombstone(id, true, hlc: nextHLC())
    }

    private func recordCategory(_ id: Feed.ID, _ value: String) {
        ownShard.setFeedCategory(id, value, hlc: nextHLC())
    }

    private func recordViewMode(_ id: Feed.ID, _ value: ReaderViewMode?) {
        ownShard.setFeedViewMode(id, value, hlc: nextHLC())
    }

    private func recordCustomTitle(_ id: Feed.ID, _ value: String?) {
        ownShard.setFeedTitle(id, value, hlc: nextHLC())
    }

    private func recordFeedDeleted(_ id: Feed.ID) {
        ownShard.setFeedTombstone(id, true, hlc: nextHLC())
    }

    /// Records that a feed is present again (tombstone cleared), so a re-add
    /// beats any earlier deletion of the same URL under last-writer-wins.
    private func recordFeedRestored(_ id: Feed.ID) {
        ownShard.setFeedTombstone(id, false, hlc: nextHLC())
    }

    /// Seeds a feed's identity into this device's shard so its membership is CRDT
    /// state, immune to a baseline-file overwrite by another device. Deduplicated
    /// so a refresh that changes nothing doesn't churn the shard.
    private func recordFeedSeed(_ feed: Feed) {
        let seed = FeedSeed(from: feed)
        guard ownShard.feedState[feed.id]?.seed?.value != seed else { return }
        ownShard.setFeedSeed(feed.id, seed, hlc: nextHLC())
        scheduleShardSave()
    }

    private func recordFolder(_ name: String, present: Bool) {
        ownShard.setFolderPresent(name, present, hlc: nextHLC())
    }

    /// Schedules a coalesced background write of this device's shard. Runs off
    /// the main actor and, like the baseline save, only ever writes the latest
    /// snapshot. The shard is a separate file from `NookLibrary.json`, so the two
    /// writers never contend.
    private func scheduleShardSave() {
        guard let storage else { return }
        ownShard.updatedAt = Date()
        ownShard.generation &+= 1
        pendingShard = ownShard
        guard !isDrainingShardSaves else { return }
        isDrainingShardSaves = true
        Task { await drainShardSaves(storage: storage) }
    }

    private func drainShardSaves(storage: ReaderStorage) async {
        while let shard = pendingShard {
            pendingShard = nil
            let modDate = await Task.detached(priority: .utility) { () -> Date? in
                try? storage.saveShard(shard)
                return storage.stateDirectoryModificationDate
            }.value
            // Record our own write so the directory observer doesn't treat it as
            // an external (another-device) change and re-merge it back.
            lastKnownStateModDate = modDate
        }
        isDrainingShardSaves = false
    }
}
