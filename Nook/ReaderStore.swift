import AppKit
import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class ReaderStore {
    var feeds: [Feed] = [] { didSet { scheduleArticleFilter() } }
    var articles: [Article] = [] { didSet { scheduleArticleFilter(); updateDockBadge() } }
    // Library and Feeds are independent selection scopes: a single smart
    // source acts as navigation, while feeds support multiple selection.
    var smartSelection: SmartSource? = .all { didSet { scheduleArticleFilter() } }
    var feedSelection: Set<Feed.ID> = [] { didSet { scheduleArticleFilter() } }
    /// Whether the window-wide in-app browser bottom sheet is showing.
    var isBrowserPresented = false
    /// The in-app browser's current view mode (reader vs original). Toggled
    /// instantly without changing the saved default.
    var browserMode: ReaderViewMode = .reader

    func toggleBrowserMode() {
        guard isBrowserPresented else { return }
        browserMode = (browserMode == .reader) ? .original : .reader
    }
    // Articles kept visible in the current source even after being read, until
    // the user navigates to another source (Chrome-tab-close heuristic).
    private var retainedArticleIDs: Set<Article.ID> = [] { didSet { scheduleArticleFilter() } }
    var selectedArticleID: Article.ID?
    /// The raw text bound to the search field; updates instantly as the user types.
    var searchText = ""
    /// The query actually used to filter articles. Trails `searchText` by a
    /// short debounce so filtering doesn't run on every keystroke.
    private(set) var activeSearchQuery = "" { didSet { scheduleArticleFilter() } }
    private var searchDebounceTask: Task<Void, Never>?

    /// The filtered, sorted articles shown in the list. Recomputed off the main
    /// thread for large libraries so typing/scrolling never blocks the UI.
    private(set) var displayedArticles: [Article] = []
    private var filterTask: Task<Void, Never>?
    /// Above this many articles, filtering runs on a background executor.
    private static let backgroundFilterThreshold = 600
    var lastRefreshedAt: Date?
    var errorMessage: String?
    /// Mirrors the "show unread badge" preference. Held in the store (not only
    /// the view) so the Dock badge is a deterministic function of store state
    /// rather than of SwiftUI view-lifecycle timing.
    var showsUnreadBadge = true { didSet { updateDockBadge() } }
    private(set) var syncFolderDisplayPath: String?
    private(set) var feedIcons: [Feed.ID: NSImage] = [:]
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
    private var isAccessingSecurityScopedResource = false
    private var refreshingFeedIDs: Set<Feed.ID> = []

    private var didBootstrap = false

    init() {}

    /// Loads the persisted library and starts filtering. Runs its heavy work
    /// only once, no matter how often it is called.
    ///
    /// This is intentionally kept out of `init()`. `ContentView` holds the store
    /// in `@State`, and SwiftUI re-evaluates the app/window body many times while
    /// the graph settles. Each evaluation re-runs `ContentView.init()`, which the
    /// compiler expands to `_store = State(wrappedValue: ReaderStore())` — so a
    /// throwaway `ReaderStore` is allocated every time even though `@State` keeps
    /// only the first. With the JSON load in `init()`, every one of those
    /// throwaway allocations decoded `NookLibrary.json` synchronously on the main
    /// thread, pinning the CPU near 100%. Deferring it here to a one-time call
    /// from `.task` makes the throwaway allocations cheap.
    func bootstrap() {
        guard !didBootstrap else { return }
        didBootstrap = true
        restoreStorageIfPossible()
        scheduleArticleFilter()
    }

    var isStorageConfigured: Bool {
        storage != nil
    }

    var isRefreshing: Bool {
        !refreshingFeedIDs.isEmpty
    }

    var selectedArticle: Article? {
        guard let selectedArticleID else { return nil }
        return articles.first { $0.id == selectedArticleID }
    }

    /// The list-backing articles. Backed by `displayedArticles`, which is
    /// recomputed (off-main for large libraries) whenever a filter input changes.
    var visibleArticles: [Article] { displayedArticles }

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

    var syncFolderName: String? {
        guard let syncFolderDisplayPath, !syncFolderDisplayPath.isEmpty else { return nil }
        return (syncFolderDisplayPath as NSString).lastPathComponent
    }

    var selectedSourceTitle: String {
        if !feedSelection.isEmpty {
            if feedSelection.count == 1, let id = feedSelection.first {
                return feed(for: id)?.title ?? String(localized: "Feed")
            }
            return String(localized: "\(feedSelection.count) selected")
        }
        return smartSelection?.title ?? String(localized: "Articles")
    }

    /// The feed IDs currently selected, for batch feed actions.
    var selectedFeedIDs: [Feed.ID] { Array(feedSelection) }

    /// Selecting a smart source is single-select navigation and clears any
    /// feed selection, keeping the two scopes independent.
    func selectSmartSource(_ source: SmartSource) {
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

    func configureSyncFolder(_ directoryURL: URL) {
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
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func feed(for feedID: Feed.ID) -> Feed? {
        feeds.first { $0.id == feedID }
    }

    func faviconImage(for feed: Feed) -> Image? {
        feedIcons[feed.id].map(Image.init(nsImage:))
    }

    /// All folder names (including empty ones), in natural order.
    var feedFolders: [String] {
        folders.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func feeds(inFolder folder: String) -> [Feed] {
        feeds.filter { $0.folderName == folder }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    func feedCount(inFolder folder: String) -> Int {
        feeds.reduce(0) { $1.folderName == folder ? $0 + 1 : $0 }
    }

    var ungroupedFeeds: [Feed] {
        feeds.filter { $0.folderName.isEmpty }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    func createFolder(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !folders.contains(trimmed) else { return }
        folders.append(trimmed)
        saveAfterMutation()
    }

    /// Removes a folder and every feed inside it.
    func removeFolder(_ name: String) {
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

    /// Moves a feed into a folder (empty string moves it back to top level).
    func moveFeed(_ feedID: Feed.ID, toFolder folder: String) {
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

    func isRefreshing(feedID: Feed.ID) -> Bool {
        refreshingFeedIDs.contains(feedID)
    }

    /// Total unread across every feed, used for the app icon badge.
    var totalUnreadCount: Int {
        articles.reduce(0) { $1.isRead ? $0 : $0 + 1 }
    }

    /// The single writer of the Dock badge. Invoked automatically whenever the
    /// article set or the preference changes (via their `didSet`), so the badge
    /// can never drift out of sync with the unread count — on launch, during a
    /// refresh, or when read state changes — regardless of view timing.
    private func updateDockBadge() {
        let count = totalUnreadCount
        NSApp.dockTile.badgeLabel = (showsUnreadBadge && count > 0) ? String(count) : nil
    }

    func unreadCount(feedID: Feed.ID? = nil) -> Int {
        articles.filter { article in
            !article.isRead && (feedID == nil || article.feedID == feedID)
        }.count
    }

    func unreadCount(inFolder folder: String) -> Int {
        let ids = Set(feeds.filter { $0.folderName == folder }.map(\.id))
        return articles.reduce(0) { $1.isRead || !ids.contains($1.feedID) ? $0 : $0 + 1 }
    }

    /// Selecting a folder selects all feeds inside it, so the article list
    /// shows the folder's combined articles.
    func selectFolder(_ folder: String) {
        feedSelection = Set(feeds.filter { $0.folderName == folder }.map(\.id))
        clearRetainedArticles()
        pruneSelectionIfHidden()
    }

    func isFolderSelected(_ folder: String) -> Bool {
        let ids = Set(feeds.filter { $0.folderName == folder }.map(\.id))
        return !ids.isEmpty && feedSelection == ids
    }

    func count(for source: SmartSource) -> Int {
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

    func addFeed(urlString: String) {
        guard isStorageConfigured else {
            errorMessage = ReaderStorageError.noDirectorySelected.localizedDescription
            return
        }

        Task {
            await addFeedFromURLString(urlString)
        }
    }

    /// Parses an OPML file into feed candidates for the import preview. Returns
    /// an empty array (and sets `errorMessage`) on failure.
    func parseOPML(at fileURL: URL) -> [OPMLFeed] {
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
    func importFeeds(_ opmlFeeds: [OPMLFeed]) {
        guard isStorageConfigured, !opmlFeeds.isEmpty else { return }

        Task {
            await importSelectedFeeds(opmlFeeds)
        }
    }

    func handleOPMLExport(_ result: Result<URL, Error>) {
        switch result {
        case .success:
            errorMessage = nil
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }

    func refreshAll() {
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
    func refreshOnActivation(honorThrottle: Bool) {
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

    func runAutoRefreshLoop(intervalMinutes: Int) async {
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

    func refreshFeeds(ids: [Feed.ID]) {
        let targets = ids.compactMap(feed(for:))
        guard !targets.isEmpty else { return }
        Task {
            for feed in targets {
                await refreshFeed(feed)
            }
        }
    }

    func markFeedsRead(ids: [Feed.ID]) {
        ids.forEach { markFeedRead(feedID: $0) }
    }

    func removeFeeds(ids: [Feed.ID]) {
        ids.forEach { removeFeed(feedID: $0) }
    }

    func markArticleOpened(articleID: Article.ID) {
        setRead(articleID: articleID, isRead: true)
    }

    /// Keeps an article visible in the current source even once it is read, so
    /// it does not vanish out from under the reader while it is being viewed.
    func retainArticle(id: Article.ID) {
        retainedArticleIDs.insert(id)
    }

    /// Drops the retained set so the list recomputes fresh; called when the
    /// selected source changes.
    func clearRetainedArticles() {
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

    func setRead(articleID: Article.ID, isRead: Bool) {
        guard let index = articles.firstIndex(where: { $0.id == articleID }),
              articles[index].isRead != isRead else { return }

        articles[index].isRead = isRead
        saveAfterMutation()
    }

    func markSelectedRead() {
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

    func toggleSelectedStarred() {
        guard let selectedArticleID else { return }
        toggleStarred(articleID: selectedArticleID)
    }

    func toggleStarred(articleID: Article.ID) {
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
    func pruneSelectionIfHidden() {
        guard let selectedArticleID else { return }
        if !visibleArticles.contains(where: { $0.id == selectedArticleID }) {
            self.selectedArticleID = nil
        }
    }

    func selectNextArticle() {
        moveSelection(offset: 1)
    }

    func selectPreviousArticle() {
        moveSelection(offset: -1)
    }

    func readBinding(articleID: Article.ID) -> Binding<Bool> {
        Binding {
            self.articles.first { $0.id == articleID }?.isRead ?? false
        } set: { isRead in
            self.setRead(articleID: articleID, isRead: isRead)
        }
    }

    func starredBinding(articleID: Article.ID) -> Binding<Bool> {
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

        errorMessage = failures.isEmpty ? nil : String(localized: "Couldn't add \(failures.count) feeds")
        try? persistLibrary()
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
        try persistLibrary()
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
            // Preserve the user's folder assignment across refreshes; a freshly
            // parsed feed always has an empty category.
            updated.category = feeds[feedIndex].category
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
    func debounceSearch() {
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

        if didRepair { try? persistLibrary() }
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
           let image = NSImage(data: data) {
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
              let image = NSImage(data: data) else {
            // Remember the failure so we don't re-hammer this host next launch.
            storage?.recordFaviconMiss(forKey: key)
            return
        }

        let pngData = image.pngData() ?? data
        try? storage?.writeFaviconData(pngData, forKey: key)
        let finalImage = NSImage(data: pngData) ?? image
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

    private func saveAfterMutation() {
        do {
            try persistLibrary()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func persistLibrary() throws {
        guard let storage else {
            throw ReaderStorageError.noDirectorySelected
        }

        let library = ReaderLibrary(
            feeds: feeds,
            articles: articles,
            lastRefreshedAt: lastRefreshedAt,
            folders: folders
        )
        try storage.save(library)
    }
}
