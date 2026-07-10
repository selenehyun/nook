import AppKit
import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class ReaderStore {
    var feeds: [Feed] = []
    var articles: [Article] = []
    // Library and Feeds are independent selection scopes: a single smart
    // source acts as navigation, while feeds support multiple selection.
    var smartSelection: SmartSource? = .all
    var feedSelection: Set<Feed.ID> = []
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
    private var retainedArticleIDs: Set<Article.ID> = []
    var selectedArticleID: Article.ID?
    var searchText = ""
    var lastRefreshedAt: Date?
    var errorMessage: String?
    private(set) var syncFolderDisplayPath: String?
    private(set) var feedIcons: [Feed.ID: NSImage] = [:]
    private(set) var folders: [String] = []

    private let feedService = RSSFeedService()
    private let faviconService = FaviconService()
    private let opmlService = OPMLService()
    private var storage: ReaderStorage?
    private var securityScopedDirectoryURL: URL?
    private var isAccessingSecurityScopedResource = false
    private var refreshingFeedIDs: Set<Feed.ID> = []

    init() {
        restoreStorageIfPossible()
        selectFirstVisibleArticleIfNeeded()
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

    var visibleArticles: [Article] {
        articles
            .filter { matchesSelectedSource($0) || (retainedArticleIDs.contains($0.id) && matchesSourceIgnoringReadState($0)) }
            .filter(matchesSearch)
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
        selectFirstVisibleArticleIfNeeded()
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
            selectFirstVisibleArticleIfNeeded()
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
        selectFirstVisibleArticleIfNeeded()
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
        selectFirstVisibleArticleIfNeeded()
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

        selectFirstVisibleArticleIfNeeded()
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

    func selectFirstVisibleArticleIfNeeded() {
        let visibleIDs = Set(visibleArticles.map(\.id))
        if let selectedArticleID, visibleIDs.contains(selectedArticleID) {
            return
        }

        selectedArticleID = visibleArticles.first?.id
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
        selectFirstVisibleArticleIfNeeded()
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
        for newArticle in parsedFeed.articles {
            var article = newArticle
            if let existing = existingArticlesByID[article.id] {
                article.isRead = existing.isRead
                article.isStarred = existing.isStarred
            }
            existingArticlesByID[article.id] = article
        }

        articles = Array(existingArticlesByID.values)
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

    private func matchesSelectedSource(_ article: Article) -> Bool {
        if !feedSelection.isEmpty {
            return feedSelection.contains(article.feedID)
        }
        if let smartSelection {
            return article.matches(.smart(smartSelection))
        }
        return true
    }

    /// Whether the article belongs to the current source ignoring the
    /// read-state condition (so a just-read article can stay in the Unread
    /// list). Only the Unread source filters on read state.
    private func matchesSourceIgnoringReadState(_ article: Article) -> Bool {
        if !feedSelection.isEmpty {
            return feedSelection.contains(article.feedID)
        }
        switch smartSelection {
        case .some(.unread), .some(.all), .none:
            return true
        case .some(.today):
            return Calendar.current.isDateInToday(article.publishedAt)
        case .some(.starred):
            return article.isStarred
        }
    }

    private func matchesSearch(_ article: Article) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }

        return article.title.localizedStandardContains(query)
            || article.summary.localizedStandardContains(query)
            || article.bodyParagraphs.joined(separator: " ").localizedStandardContains(query)
            || (feed(for: article.feedID)?.title.localizedStandardContains(query) ?? false)
    }

    private func apply(_ library: ReaderLibrary) {
        feeds = library.feeds
        articles = library.articles
        lastRefreshedAt = library.lastRefreshedAt
        // Merge explicit folders with any folders implied by feed categories.
        let feedFolderNames = feeds.map(\.folderName).filter { !$0.isEmpty }
        folders = Array(Set(library.folders + feedFolderNames))
        loadCachedFavicons()
    }

    private func loadCachedFavicons() {
        for feed in feeds {
            ensureFavicon(for: feed)
        }
    }

    /// Shows any cached favicon immediately, then refreshes it in the
    /// background when it is missing or older than the 1-day TTL.
    private func ensureFavicon(for feed: Feed) {
        guard let storage else { return }
        let key = faviconKey(for: feed)

        if feedIcons[feed.id] == nil,
           let data = storage.cachedFaviconData(forKey: key),
           let image = NSImage(data: data) {
            feedIcons[feed.id] = image
        }

        if storage.faviconNeedsRefresh(forKey: key) {
            Task { await refreshFavicon(for: feed) }
        }
    }

    private func refreshFavicon(for feed: Feed) async {
        guard let data = await faviconService.fetchFavicon(for: feed.siteURL),
              let image = NSImage(data: data) else {
            return
        }

        let pngData = image.pngData() ?? data
        try? storage?.writeFaviconData(pngData, forKey: faviconKey(for: feed))
        feedIcons[feed.id] = NSImage(data: pngData) ?? image
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
