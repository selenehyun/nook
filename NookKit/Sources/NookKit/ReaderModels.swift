import Foundation

public struct ReaderLibrary: Codable, Sendable {
    public var feeds: [Feed]
    public var articles: [Article]
    public var lastRefreshedAt: Date?
    /// Explicit folder names, including empty folders, so they persist and sync
    /// even with no feeds inside (the ".gitkeep" role for folders).
    public var folders: [String]

    enum CodingKeys: String, CodingKey {
        case feeds, articles, lastRefreshedAt, folders
    }

    public init(feeds: [Feed], articles: [Article], lastRefreshedAt: Date?, folders: [String]) {
        self.feeds = feeds
        self.articles = articles
        self.lastRefreshedAt = lastRefreshedAt
        self.folders = folders
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        feeds = try container.decode([Feed].self, forKey: .feeds)
        articles = try container.decode([Article].self, forKey: .articles)
        lastRefreshedAt = try container.decodeIfPresent(Date.self, forKey: .lastRefreshedAt)
        folders = try container.decodeIfPresent([String].self, forKey: .folders) ?? []
    }
}

public struct Feed: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var siteDescription: String
    public var category: String
    public var systemImage: String
    public var feedURL: URL
    public var siteURL: URL
    public var healthScore: Double
    public var lastFetchedAt: Date?
    /// Per-feed override for the in-app browser's reading view. `nil` follows the
    /// global default (`readerViewMode`); set it when a feed reads better in one
    /// mode so its articles always open that way.
    public var preferredViewMode: ReaderViewMode? = nil
    /// A user-chosen name that overrides the feed-provided `title`. `nil` (or
    /// empty) uses `title`, which keeps updating from the feed on refresh.
    public var customTitle: String? = nil

    public init(
        id: String,
        title: String,
        siteDescription: String,
        category: String,
        systemImage: String,
        feedURL: URL,
        siteURL: URL,
        healthScore: Double,
        lastFetchedAt: Date? = nil,
        preferredViewMode: ReaderViewMode? = nil,
        customTitle: String? = nil
    ) {
        self.id = id
        self.title = title
        self.siteDescription = siteDescription
        self.category = category
        self.systemImage = systemImage
        self.feedURL = feedURL
        self.siteURL = siteURL
        self.healthScore = healthScore
        self.lastFetchedAt = lastFetchedAt
        self.preferredViewMode = preferredViewMode
        self.customTitle = customTitle
    }

    /// The name to show for this feed: the user's custom name when set,
    /// otherwise the feed-provided title.
    public var displayTitle: String {
        if let customTitle, !customTitle.isEmpty { return customTitle }
        return title
    }

    /// The folder this feed lives in, or empty for a top-level feed. The legacy
    /// default category "Feeds" is treated as no folder.
    public var folderName: String {
        (category == "Feeds") ? "" : category
    }
}

extension URL {
    /// A normalized key for comparing feed/site URLs so trivial differences
    /// (trailing slash, casing) don't split one feed into duplicates.
    public var feedIdentityKey: String {
        var value = absoluteString.lowercased()
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }
}

public struct Article: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var feedID: Feed.ID
    public var title: String
    public var summary: String
    public var bodyParagraphs: [String]
    public var publishedAt: Date
    public var url: URL
    public var estimatedReadMinutes: Int
    public var isRead: Bool
    public var isStarred: Bool
    /// The item's content as HTML when the feed declares (or ships) HTML, so
    /// the reader can render it richly. `nil` for plain-text content.
    public var contentHTML: String?

    public init(
        id: String,
        feedID: Feed.ID,
        title: String,
        summary: String,
        bodyParagraphs: [String],
        publishedAt: Date,
        url: URL,
        estimatedReadMinutes: Int,
        isRead: Bool,
        isStarred: Bool,
        contentHTML: String? = nil
    ) {
        self.id = id
        self.feedID = feedID
        self.title = title
        self.summary = summary
        self.bodyParagraphs = bodyParagraphs
        self.publishedAt = publishedAt
        self.url = url
        self.estimatedReadMinutes = estimatedReadMinutes
        self.isRead = isRead
        self.isStarred = isStarred
        self.contentHTML = contentHTML
    }
}

extension Article {
    public func matches(_ source: SourceSelection) -> Bool {
        switch source {
        case .smart(.all): true
        case .smart(.unread): !isRead
        case .smart(.today): Calendar.current.isDateInToday(publishedAt)
        case .smart(.starred): isStarred
        case .feed(let feedID): self.feedID == feedID
        }
    }
}

public struct ParsedFeed: Sendable {
    public var feed: Feed
    public var articles: [Article]

    public init(feed: Feed, articles: [Article]) {
        self.feed = feed
        self.articles = articles
    }
}

public enum SourceSelection: Hashable, Sendable {
    case smart(SmartSource)
    case feed(Feed.ID)
}

public enum SmartSource: String, CaseIterable, Identifiable, Sendable {
    case unread
    case today
    case starred
    case all

    public var id: Self { self }

    public var title: String {
        switch self {
        case .unread: String(localized: "Unread", bundle: Bundle.module)
        case .today: String(localized: "Today", bundle: Bundle.module)
        case .starred: String(localized: "Starred", bundle: Bundle.module)
        case .all: String(localized: "All Articles", bundle: Bundle.module)
        }
    }

    public var systemImage: String {
        switch self {
        case .unread: "largecircle.fill.circle"
        case .today: "calendar"
        case .starred: "star"
        case .all: "tray.full"
        }
    }
}

extension Article {
    public static func readingMinutes(for paragraphs: [String]) -> Int {
        let wordCount = paragraphs
            .joined(separator: " ")
            .split { $0.isWhitespace || $0.isNewline }
            .count
        return max(1, Int(ceil(Double(wordCount) / 220.0)))
    }
}
