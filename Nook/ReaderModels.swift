import Foundation

struct ReaderLibrary: Codable {
    var feeds: [Feed]
    var articles: [Article]
    var lastRefreshedAt: Date?
    /// Explicit folder names, including empty folders, so they persist and sync
    /// even with no feeds inside (the ".gitkeep" role for folders).
    var folders: [String]

    enum CodingKeys: String, CodingKey {
        case feeds, articles, lastRefreshedAt, folders
    }

    init(feeds: [Feed], articles: [Article], lastRefreshedAt: Date?, folders: [String]) {
        self.feeds = feeds
        self.articles = articles
        self.lastRefreshedAt = lastRefreshedAt
        self.folders = folders
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        feeds = try container.decode([Feed].self, forKey: .feeds)
        articles = try container.decode([Article].self, forKey: .articles)
        lastRefreshedAt = try container.decodeIfPresent(Date.self, forKey: .lastRefreshedAt)
        folders = try container.decodeIfPresent([String].self, forKey: .folders) ?? []
    }
}

struct Feed: Identifiable, Codable, Hashable {
    var id: String
    var title: String
    var siteDescription: String
    var category: String
    var systemImage: String
    var feedURL: URL
    var siteURL: URL
    var healthScore: Double
    var lastFetchedAt: Date?
    /// Per-feed override for the in-app browser's reading view. `nil` follows the
    /// global default (`readerViewMode`); set it when a feed reads better in one
    /// mode so its articles always open that way.
    var preferredViewMode: ReaderViewMode? = nil

    /// The folder this feed lives in, or empty for a top-level feed. The legacy
    /// default category "Feeds" is treated as no folder.
    var folderName: String {
        (category == "Feeds") ? "" : category
    }
}

extension URL {
    /// A normalized key for comparing feed/site URLs so trivial differences
    /// (trailing slash, casing) don't split one feed into duplicates.
    var feedIdentityKey: String {
        var value = absoluteString.lowercased()
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }
}

struct Article: Identifiable, Codable, Hashable {
    var id: String
    var feedID: Feed.ID
    var title: String
    var summary: String
    var bodyParagraphs: [String]
    var publishedAt: Date
    var url: URL
    var estimatedReadMinutes: Int
    var isRead: Bool
    var isStarred: Bool
    /// The item's content as HTML when the feed declares (or ships) HTML, so
    /// the reader can render it richly. `nil` for plain-text content.
    var contentHTML: String?
}

extension Article {
    func matches(_ source: SourceSelection) -> Bool {
        switch source {
        case .smart(.all): true
        case .smart(.unread): !isRead
        case .smart(.today): Calendar.current.isDateInToday(publishedAt)
        case .smart(.starred): isStarred
        case .feed(let feedID): self.feedID == feedID
        }
    }
}

struct ParsedFeed {
    var feed: Feed
    var articles: [Article]
}

enum SourceSelection: Hashable {
    case smart(SmartSource)
    case feed(Feed.ID)
}

enum SmartSource: String, CaseIterable, Identifiable {
    case unread
    case today
    case starred
    case all

    var id: Self { self }

    var title: String {
        switch self {
        case .unread: String(localized: "Unread")
        case .today: String(localized: "Today")
        case .starred: String(localized: "Starred")
        case .all: String(localized: "All Articles")
        }
    }

    var systemImage: String {
        switch self {
        case .unread: "largecircle.fill.circle"
        case .today: "calendar"
        case .starred: "star"
        case .all: "tray.full"
        }
    }
}

extension Article {
    static func readingMinutes(for paragraphs: [String]) -> Int {
        let wordCount = paragraphs
            .joined(separator: " ")
            .split { $0.isWhitespace || $0.isNewline }
            .count
        return max(1, Int(ceil(Double(wordCount) / 220.0)))
    }
}
