import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
public final class ReaderStore {
    public var feeds: [Feed] = [] { didSet { scheduleArticleFilter() } }
    var articles: [Article] = [] { didSet { scheduleArticleFilter(); updateUnreadBadge() } }
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
    // Articles kept visible in the current source even after being read, until
    // the user navigates to another source (Chrome-tab-close heuristic).
    private var retainedArticleIDs: Set<Article.ID> = [] { didSet { scheduleArticleFilter() } }
    public var selectedArticleID: Article.ID?
    /// The raw text bound to the search field; updates instantly as the user types.
    public var searchText = ""
    /// The query actually used to filter articles. Trails `searchText` by a
    /// short debounce so filtering doesn't run on every keystroke.
    public private(set) var activeSearchQuery = "" { didSet { scheduleArticleFilter() } }
    private var searchDebounceTask: Task<Void, Never>?

    /// The filtered, sorted articles shown in the list. Recomputed off the main
    /// thread for large libraries so typing/scrolling never blocks the UI.
    private(set) var displayedArticles: [Article] = []
    private var filterTask: Task<Void, Never>?
    /// Above this many articles, filtering runs on a background executor.
    private static let backgroundFilterThreshold = 600
    var lastRefreshedAt: Date?
    public var errorMessage: String?
    /// Mirrors the "show unread badge" preference. Held in the store (not only
    /// the view) so the Dock badge is a deterministic function of store state
    /// rather than of SwiftUI view-lifecycle timing.
    public var showsUnreadBadge = true { didSet { updateUnreadBadge() } }
    public private(set) var syncFolderDisplayPath: String?
    private(set) var feedIcons: [Feed.ID: PlatformImage] = [:]
    private(set) var folders: [String] = []

    // Favicon fetching is deduplicated by host and rate-limited so a large
    // library doesn't spawn a storm of concurrent requests on launch.
    private var faviconAttemptedKeys: Set<String> = []
    private var faviconQueue: [Feed] = []
    private var activeFaviconFetches = 0
    private static let maxConcurrentFaviconFetches = 4

    private let feedService = RSSFeedService()
    private let faviconService = FaviconService()
    private let opmlService = OPMLService()
    private var storage: ReaderStorage?
    private var securityScopedDirectoryURL: URL?

    // Live cross-device sync: watch the library file for external (iCloud)
    // changes and reload, ignoring the app's own writes by modification date.
    private var libraryObserver: LibraryFileObserver?
    private var lastKnownLibraryModDate: Date?
    private var externalReloadTask: Task<Void, Never>?

    // Coalesced background persistence: the latest snapshot waiting to be
    // written, and whether a writer task is already draining them.
    private var pendingSave: ReaderLibrary?
    private var isDrainingSaves = false
    private var isAccessingSecurityScopedResource = false
    private var refreshingFeedIDs: Set<Feed.ID> = []

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
    public func bootstrap() {
        guard !didBootstrap else { return }
        didBootstrap = true
        restoreStorageIfPossible()
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

    /// Recomputes `displayedArticles` from the current inputs. Coalesces rapid
    /// input changes by cancelling any in-flight recompute. Small libraries are
    /// filtered synchronously (instant, animatable); large ones are filtered on
    /// a background executor so the main thread stays responsive.
    private func scheduleArticleFilter() {
        filterTask?.cancel()

        let snapshot = articles
        let feedTitles = Dictionary(feeds.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        let feedSelection = self.feedSelection
        let smartSelection = self.smartSelection
        let retained = retainedArticleIDs
        let query = activeSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)

        if snapshot.count < Self.backgroundFilterThreshold {
            applyDisplayed(Self.computeVisibleArticles(
                snapshot, feedTitles: feedTitles, feedSelection: feedSelection,
                smartSelection: smartSelection, retained: retained, query: query
            ))
            return
        }

        filterTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Self.computeVisibleArticles(
                    snapshot, feedTitles: feedTitles, feedSelection: feedSelection,
                    smartSelection: smartSelection, retained: retained, query: query
                )
            }.value
            guard !Task.isCancelled, let self else { return }
            self.applyDisplayed(result)
        }
    }

    private func applyDisplayed(_ result: [Article]) {
        displayedArticles = result
        pruneSelectionIfHidden()
    }

    /// Pure filtering + sorting over a snapshot. `nonisolated` so it can run on
    /// a background executor; all inputs are value types (`Sendable`).
    nonisolated private static func computeVisibleArticles(
        _ articles: [Article],
        feedTitles: [Feed.ID: String],
        feedSelection: Set<Feed.ID>,
        smartSelection: SmartSource?,
        retained: Set<Article.ID>,
        query: String
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
            .sorted { $0.publishedAt > $1.publishedAt }
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

            if let library = try storage.load() {
                apply(library)
            } else {
                try persistLibrary()
            }

            errorMessage = nil
            pruneSelectionIfHidden()
            lastKnownLibraryModDate = storage.libraryModificationDate
            startObservingLibrary()
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

        libraryObserver?.stop()
        let fileURL = storage.libraryURL
        libraryObserver = LibraryFileObserver(fileURL: fileURL) { [weak self] in
            Task { @MainActor in self?.scheduleExternalReload() }
        }
    }

    /// Coalesces a burst of file-change notifications into a single reload.
    private func scheduleExternalReload() {
        externalReloadTask?.cancel()
        externalReloadTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.reloadFromDiskIfChanged()
        }
    }

    /// Re-reads the library from disk and applies it when the file is newer than
    /// what we last loaded or wrote — so it reflects another device's changes
    /// but ignores our own saves. UI state (selection, search) is preserved.
    public func reloadFromDiskIfChanged() {
        guard let storage, !isRefreshing else { return }
        let diskDate = storage.libraryModificationDate
        if let diskDate, let known = lastKnownLibraryModDate, diskDate <= known {
            return
        }
        guard let library = try? storage.load() else { return }
        apply(library)
        pruneSelectionIfHidden()
        lastKnownLibraryModDate = storage.libraryModificationDate
    }

    /// Pulls the latest library from iCloud and reloads it. Call this when the
    /// app returns to the foreground so device switches sync promptly.
    public func syncFromDisk() {
        guard let storage else { return }
        storage.startDownloadingLibraryIfNeeded()
        reloadFromDiskIfChanged()
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
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    func feedCount(inFolder folder: String) -> Int {
        feeds.reduce(0) { $1.folderName == folder ? $0 + 1 : $0 }
    }

    public var ungroupedFeeds: [Feed] {
        feeds.filter { $0.folderName.isEmpty }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    public func createFolder(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !folders.contains(trimmed) else { return }
        folders.append(trimmed)
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
        }
        if let index = folders.firstIndex(of: oldName) {
            folders[index] = trimmed
        }
        saveAfterMutation()
    }

    /// Moves a feed into a folder (empty string moves it back to top level).
    public func moveFeed(_ feedID: Feed.ID, toFolder folder: String) {
        guard let index = feeds.firstIndex(where: { $0.id == feedID }),
              feeds[index].category != folder else {
            return
        }
        feeds[index].category = folder
        if !folder.isEmpty, !folders.contains(folder) {
            folders.append(folder)
        }
        saveAfterMutation()
    }

    public func isRefreshing(feedID: Feed.ID) -> Bool {
        refreshingFeedIDs.contains(feedID)
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
            changed = true
        }
        if changed { saveAfterMutation() }
    }

    /// Total unread across every feed, used for the app icon badge.
    var totalUnreadCount: Int {
        articles.reduce(0) { $1.isRead ? $0 : $0 + 1 }
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

    public func unreadCount(feedID: Feed.ID? = nil) -> Int {
        articles.filter { article in
            !article.isRead && (feedID == nil || article.feedID == feedID)
        }.count
    }

    public func unreadCount(inFolder folder: String) -> Int {
        let ids = Set(feeds.filter { $0.folderName == folder }.map(\.id))
        return articles.reduce(0) { $1.isRead || !ids.contains($1.feedID) ? $0 : $0 + 1 }
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
        case .unread:
            unreadCount()
        case .today:
            articles.filter { Calendar.current.isDateInToday($0.publishedAt) }.count
        case .starred:
            articles.filter(\.isStarred).count
        case .all:
            articles.count
        }
    }

    public func addFeed(urlString: String) {
        guard isStorageConfigured else {
            errorMessage = ReaderStorageError.noDirectorySelected.localizedDescription
            return
        }

        Task {
            await addFeedFromURLString(urlString)
        }
    }

    /// Result of a background refresh: how many genuinely new (previously
    /// unseen, unread) articles arrived, and a few of their titles for a
    /// notification.
    public struct BackgroundRefreshResult: Sendable {
        public let newArticleCount: Int
        public let sampleTitles: [String]
    }

    /// Refreshes all feeds from a background launch and reports newly-arrived
    /// unread articles. Loads the library first if the process is fresh, and
    /// writes it synchronously so the result is saved before the OS suspends
    /// the app again.
    public func refreshForBackground() async -> BackgroundRefreshResult {
        if !didBootstrap { bootstrap() }
        guard isStorageConfigured, !feeds.isEmpty else {
            return BackgroundRefreshResult(newArticleCount: 0, sampleTitles: [])
        }

        let knownIDs = Set(articles.map(\.id))
        await refreshAllFeeds()
        try? persistLibrary()

        let fresh = articles.filter { !knownIDs.contains($0.id) && !$0.isRead }
        let sorted = fresh.sorted { $0.publishedAt > $1.publishedAt }
        return BackgroundRefreshResult(
            newArticleCount: fresh.count,
            sampleTitles: sorted.prefix(3).map(\.title)
        )
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

        Task {
            await refreshAllFeeds()
        }
    }

    /// Shortest gap between activation-triggered syncs. Prevents rapidly
    /// switching focus back to Nook from hammering feed servers.
    private static let activationRefreshThrottle: TimeInterval = 60

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
        Task {
            await refreshAllFeeds()
            activationRefreshInFlight = false
        }
    }

    public func runAutoRefreshLoop(intervalMinutes: Int) async {
        let seconds = max(5, intervalMinutes * 60)

        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(seconds))
            } catch {
                return
            }

            guard !Task.isCancelled, isStorageConfigured, !feeds.isEmpty, !isRefreshing else {
                continue
            }

            await refreshAllFeeds()
        }
    }

    func refresh(feedID: Feed.ID) {
        guard let feed = feed(for: feedID) else { return }
        feedSelection = [feedID]

        Task {
            await refreshFeed(feed)
        }
    }

    public func refreshFeeds(ids: [Feed.ID]) {
        let targets = ids.compactMap(feed(for:))
        guard !targets.isEmpty else { return }
        Task {
            for feed in targets {
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
        let targets = ids.compactMap(feed(for:))
        for feed in targets {
            await refreshFeed(feed)
        }
    }

    public func markFeedsRead(ids: [Feed.ID]) {
        ids.forEach { markFeedRead(feedID: $0) }
    }

    public func removeFeeds(ids: [Feed.ID]) {
        ids.forEach { removeFeed(feedID: $0) }
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
        saveAfterMutation()
    }

    public func markSelectedRead() {
        guard let selectedArticleID else { return }
        setRead(articleID: selectedArticleID, isRead: true)
    }

    func removeFeed(feedID: Feed.ID) {
        feeds.removeAll { $0.id == feedID }
        articles.removeAll { $0.feedID == feedID }
        feedIcons[feedID] = nil
        refreshingFeedIDs.remove(feedID)

        feedSelection.remove(feedID)

        pruneSelectionIfHidden()
        saveAfterMutation()
    }

    func markFeedRead(feedID: Feed.ID) {
        var didChange = false
        for index in articles.indices where articles[index].feedID == feedID {
            if !articles[index].isRead {
                articles[index].isRead = true
                didChange = true
            }
        }

        if didChange {
            saveAfterMutation()
        }
    }

    public func toggleSelectedStarred() {
        guard let selectedArticleID else { return }
        toggleStarred(articleID: selectedArticleID)
    }

    public func toggleStarred(articleID: Article.ID) {
        updateArticle(articleID) { article in
            article.isStarred.toggle()
        }
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
    }

    public func selectPreviousArticle() {
        moveSelection(offset: -1)
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
            self.updateArticle(articleID) { article in
                article.isStarred = isStarred
            }
        }
    }

    private func restoreStorageIfPossible() {
        do {
            guard let directoryURL = try ReaderStorage.resolveBookmarkedDirectory() else {
                syncFolderDisplayPath = UserDefaults.standard.string(forKey: ReaderStorage.displayPathDefaultsKey)
                return
            }

            startAccessing(directoryURL)
            let storage = ReaderStorage(directoryURL: directoryURL)
            self.storage = storage
            syncFolderDisplayPath = directoryURL.path(percentEncoded: false)

            if let library = try storage.load() {
                apply(library)
            }
            lastKnownLibraryModDate = storage.libraryModificationDate
            startObservingLibrary()
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

    private func addFeedFromURLString(_ urlString: String) async {
        do {
            let url = try feedService.normalizedFeedURL(from: urlString)
            let parsedFeed = try await fetch(url: url, existingFeedID: nil)
            feedSelection = [parsedFeed.feed.id]
            selectedArticleID = parsedFeed.articles.first?.id
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
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

    private func refreshAllFeeds() async {
        for feed in feeds {
            await refreshFeed(feed)
        }
    }

    @discardableResult
    private func fetch(url: URL, existingFeedID: Feed.ID?) async throws -> ParsedFeed {
        let refreshID = existingFeedID ?? url.absoluteString
        refreshingFeedIDs.insert(refreshID)
        defer {
            refreshingFeedIDs.remove(refreshID)
        }

        var parsedFeed = try await feedService.fetch(url: url)
        if let existingFeedID {
            parsedFeed.feed.id = existingFeedID
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
            errorMessage = nil
        } catch {
            markFeedUnhealthy(feedID: feed.id)
            errorMessage = error.localizedDescription
        }
    }

    private func merge(_ parsedFeed: ParsedFeed) {
        if let feedIndex = feeds.firstIndex(where: { $0.id == parsedFeed.feed.id }) {
            var updated = parsedFeed.feed
            // Preserve the user's per-feed settings across refreshes; a freshly
            // parsed feed always has an empty category and no view preference.
            updated.category = feeds[feedIndex].category
            updated.preferredViewMode = feeds[feedIndex].preferredViewMode
            feeds[feedIndex] = updated
        } else {
            feeds.append(parsedFeed.feed)
        }

        var existingArticlesByID = Dictionary(uniqueKeysWithValues: articles.map { ($0.id, $0) })
        let knownIDs = Set(existingArticlesByID.keys)
        var hasNewArticles = false
        for newArticle in parsedFeed.articles {
            var article = newArticle
            if let existing = existingArticlesByID[article.id] {
                article.isRead = existing.isRead
                article.isStarred = existing.isStarred
            } else {
                hasNewArticles = true
            }
            existingArticlesByID[article.id] = article
        }

        let merged = Array(existingArticlesByID.values)
        // Animate the list only when a refresh actually brings in new stories,
        // so rows slide/fade in like Apple Mail. Batch and single arrivals are
        // both handled by the List's built-in insertion animation.
        if hasNewArticles && !knownIDs.isEmpty {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                articles = merged
            }
        } else {
            articles = merged
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

    private func updateArticle(_ articleID: Article.ID, update: (inout Article) -> Void) {
        guard let index = articles.firstIndex(where: { $0.id == articleID }) else { return }
        update(&articles[index])
        saveAfterMutation()
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
        for feed in feeds {
            ensureFavicon(for: feed)
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
        pendingSave = snapshotLibrary()
        guard !isDrainingSaves else { return }
        isDrainingSaves = true
        Task { await drainSaves(storage: storage) }
    }

    private func drainSaves(storage: ReaderStorage) async {
        while let library = pendingSave {
            pendingSave = nil
            let modificationDate = await Task.detached(priority: .utility) { () -> Date? in
                try? storage.save(library)
                return storage.libraryModificationDate
            }.value
            // Record our own write so the file observer doesn't treat it as an
            // external (another-device) change and reload it back.
            lastKnownLibraryModDate = modificationDate
            errorMessage = nil
        }
        isDrainingSaves = false
    }

    /// Writes the library immediately on the calling actor. Used only for the
    /// initial file creation when configuring a folder, where later code
    /// depends on the file already existing.
    private func persistLibrary() throws {
        guard let storage else {
            throw ReaderStorageError.noDirectorySelected
        }
        try storage.save(snapshotLibrary())
        lastKnownLibraryModDate = storage.libraryModificationDate
    }
}
