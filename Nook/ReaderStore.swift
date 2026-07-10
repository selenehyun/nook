import AppKit
import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class ReaderStore {
    var feeds: [Feed] = []
    var articles: [Article] = []
    var selectedSource: SourceSelection? = .smart(.all)
    var selectedArticleID: Article.ID?
    var searchText = ""
    var lastRefreshedAt: Date?
    var errorMessage: String?
    private(set) var syncFolderDisplayPath: String?
    private(set) var feedIcons: [Feed.ID: NSImage] = [:]

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
            .filter(matchesSelectedSource)
            .filter(matchesSearch)
            .sorted { $0.publishedAt > $1.publishedAt }
    }

    var syncFolderName: String? {
        guard let syncFolderDisplayPath, !syncFolderDisplayPath.isEmpty else { return nil }
        return (syncFolderDisplayPath as NSString).lastPathComponent
    }

    var selectedSourceTitle: String {
        switch selectedSource {
        case .smart(let source):
            source.title
        case .feed(let feedID):
            feed(for: feedID)?.title ?? String(localized: "Feed")
        case nil:
            String(localized: "Articles")
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

    func isRefreshing(feedID: Feed.ID) -> Bool {
        refreshingFeedIDs.contains(feedID)
    }

    func unreadCount(feedID: Feed.ID? = nil) -> Int {
        articles.filter { article in
            !article.isRead && (feedID == nil || article.feedID == feedID)
        }.count
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
        selectedSource = .feed(feedID)

        Task {
            await refreshFeed(feed)
        }
    }

    func markArticleOpened(articleID: Article.ID) {
        setRead(articleID: articleID, isRead: true)
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

        if selectedSource == .feed(feedID) {
            selectedSource = .smart(.all)
        }

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
            selectedSource = .feed(parsedFeed.feed.id)
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
                let existingFeedID = feeds.first {
                    $0.feedURL == opmlFeed.feedURL || $0.id == opmlFeed.feedURL.absoluteString
                }?.id
                let parsed = try await fetch(url: opmlFeed.feedURL, existingFeedID: existingFeedID)

                // Carry the OPML folder over as the feed's category.
                if let category = opmlFeed.category,
                   let index = feeds.firstIndex(where: { $0.id == parsed.feed.id }) {
                    feeds[index].category = category
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
            feeds[feedIndex] = parsedFeed.feed
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
        switch selectedSource {
        case .smart(.all), nil:
            true
        case .smart(.unread):
            !article.isRead
        case .smart(.today):
            Calendar.current.isDateInToday(article.publishedAt)
        case .smart(.starred):
            article.isStarred
        case .feed(let feedID):
            article.feedID == feedID
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
            lastRefreshedAt: lastRefreshedAt
        )
        try storage.save(library)
    }
}
