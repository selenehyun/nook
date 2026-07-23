import Foundation

public extension CodingUserInfoKey {
    /// When set to `true` in an encoder's `userInfo`, `Article` omits its heavy
    /// body fields (`bodyParagraphs`, `contentHTML`) so the content baseline
    /// (`NookLibrary.json`) stays list-light. The bodies persist separately in
    /// the content sidecar and are re-hydrated after launch.
    static let stripArticleContent = CodingUserInfoKey(rawValue: "nook.stripArticleContent")!
}

/// A feed's identity/content, recorded in the per-device shard so a feed a
/// device added survives even if the shared baseline file is overwritten by
/// another device before the add propagates. Small (no articles), so keeping it
/// in every shard is cheap; it lets `materialize` reconstruct a usable feed when
/// the baseline lost it (its articles refetch on the next refresh).
public struct FeedSeed: Codable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var siteDescription: String
    public var category: String
    public var systemImage: String
    public var feedURL: URL
    public var siteURL: URL

    public init(from feed: Feed) {
        id = feed.id
        title = feed.title
        siteDescription = feed.siteDescription
        category = feed.category
        systemImage = feed.systemImage
        feedURL = feed.feedURL
        siteURL = feed.siteURL
    }

    /// A Feed rebuilt from the seed, healthy by default; user overrides
    /// (folder/view-mode/custom title) are applied over it from the shard.
    public func makeFeed() -> Feed {
        Feed(
            id: id, title: title, siteDescription: siteDescription, category: category,
            systemImage: systemImage, feedURL: feedURL, siteURL: siteURL, healthScore: 1
        )
    }
}

/// An article's heavy body, stored apart from the list metadata in the content
/// sidecar so the launch-critical baseline stays small.
public struct ArticleBody: Codable, Sendable, Equatable {
    public var bodyParagraphs: [String]
    public var contentHTML: String?

    public init(bodyParagraphs: [String], contentHTML: String?) {
        self.bodyParagraphs = bodyParagraphs
        self.contentHTML = contentHTML
    }
}

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
    /// A normalized key for comparing feed/site URLs so trivial differences don't
    /// split one feed into duplicates. Only scheme and host are case-folded (they
    /// are case-insensitive); the path and query keep their case (they can be
    /// case-sensitive on the server). Default ports, the fragment, and a trailing
    /// slash on the path are dropped.
    public var feedIdentityKey: String {
        guard var comps = URLComponents(url: self, resolvingAgainstBaseURL: false), comps.scheme != nil else {
            var value = absoluteString
            while value.hasSuffix("/") { value.removeLast() }
            return value.lowercased()
        }
        comps.scheme = comps.scheme?.lowercased()
        comps.host = comps.host?.lowercased()
        comps.fragment = nil
        if (comps.scheme == "http" && comps.port == 80) || (comps.scheme == "https" && comps.port == 443) {
            comps.port = nil
        }
        var path = comps.percentEncodedPath
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        comps.percentEncodedPath = path
        return comps.string ?? absoluteString
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
    /// Whether the feed actually supplied a parseable publish/updated date for
    /// this item. `false` means `publishedAt` is a synthetic first-seen stamp.
    /// Transient (set by the parser, not persisted): on refresh it tells `merge`
    /// to keep the fresh authoritative date for dated feeds — self-correcting a
    /// previously wrong value — while preserving the stamp for dateless ones.
    public var hasExplicitPublishDate: Bool = true

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
        contentHTML: String? = nil,
        hasExplicitPublishDate: Bool = true
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
        self.hasExplicitPublishDate = hasExplicitPublishDate
    }

    enum CodingKeys: String, CodingKey {
        case id, feedID, title, summary, bodyParagraphs, publishedAt
        case url, estimatedReadMinutes, isRead, isStarred, contentHTML
    }

    /// Tolerant of a list-light baseline (bodies absent) as well as the legacy
    /// inline form, so the migration from the old single-file layout is lossless.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        feedID = try c.decode(Feed.ID.self, forKey: .feedID)
        title = try c.decode(String.self, forKey: .title)
        summary = try c.decode(String.self, forKey: .summary)
        bodyParagraphs = try c.decodeIfPresent([String].self, forKey: .bodyParagraphs) ?? []
        publishedAt = try c.decode(Date.self, forKey: .publishedAt)
        url = try c.decode(URL.self, forKey: .url)
        estimatedReadMinutes = try c.decode(Int.self, forKey: .estimatedReadMinutes)
        isRead = try c.decode(Bool.self, forKey: .isRead)
        isStarred = try c.decode(Bool.self, forKey: .isStarred)
        contentHTML = try c.decodeIfPresent(String.self, forKey: .contentHTML)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(feedID, forKey: .feedID)
        try c.encode(title, forKey: .title)
        try c.encode(summary, forKey: .summary)
        try c.encode(publishedAt, forKey: .publishedAt)
        try c.encode(url, forKey: .url)
        try c.encode(estimatedReadMinutes, forKey: .estimatedReadMinutes)
        try c.encode(isRead, forKey: .isRead)
        try c.encode(isStarred, forKey: .isStarred)
        // The content baseline is persisted list-light; the bodies live in the
        // sidecar. Any other encoder (e.g. the sidecar itself) keeps them.
        let strip = encoder.userInfo[.stripArticleContent] as? Bool ?? false
        if !strip {
            try c.encode(bodyParagraphs, forKey: .bodyParagraphs)
            try c.encodeIfPresent(contentHTML, forKey: .contentHTML)
        }
    }

    /// The article's body, for persisting to / hydrating from the sidecar.
    public var body: ArticleBody {
        ArticleBody(bodyParagraphs: bodyParagraphs, contentHTML: contentHTML)
    }

    /// Whether this article actually carries body content worth persisting.
    public var hasBody: Bool {
        contentHTML != nil || !bodyParagraphs.isEmpty
    }
}

extension Article {
    /// Deterministic newest-first ordering. When two articles share the exact
    /// same publish time, their `id` breaks the tie so the order never shuffles
    /// between syncs (feeds often stamp identical timestamps on a batch).
    public static func isOrderedBefore(_ lhs: Article, _ rhs: Article) -> Bool {
        if lhs.publishedAt != rhs.publishedAt { return lhs.publishedAt > rhs.publishedAt }
        return lhs.id > rhs.id
    }

    /// Orders two articles by the given sort order (a stable id tiebreak keeps the
    /// order deterministic when publish dates match).
    public static func isOrdered(_ lhs: Article, _ rhs: Article, by order: ArticleSortOrder) -> Bool {
        switch order {
        case .newest:
            return isOrderedBefore(lhs, rhs)
        case .oldest:
            if lhs.publishedAt != rhs.publishedAt { return lhs.publishedAt < rhs.publishedAt }
            return lhs.id < rhs.id
        }
    }

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

/// How an article list is ordered. Toggled per category and persisted.
public enum ArticleSortOrder: String, CaseIterable, Sendable {
    /// Most recently published first (the default).
    case newest
    /// Oldest published first.
    case oldest

    /// The next order when the user re-taps the active segment.
    public func toggled() -> ArticleSortOrder { self == .newest ? .oldest : .newest }

    /// A glyph indicating the current direction (newest = descending).
    public var systemImage: String {
        switch self {
        case .newest: "arrow.down"
        case .oldest: "arrow.up"
        }
    }
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
