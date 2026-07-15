import Foundation

/// Immutable, sync-worthy feed fields. User overrides and refresh diagnostics
/// deliberately live outside the content replica.
public struct FeedContent: Codable, Sendable, Equatable {
    public var id: Feed.ID
    public var title: String
    public var siteDescription: String
    public var systemImage: String
    public var feedURL: URL
    public var siteURL: URL

    public init(_ feed: Feed) {
        id = feed.id
        title = feed.title
        siteDescription = feed.siteDescription
        systemImage = feed.systemImage
        feedURL = feed.feedURL
        siteURL = feed.siteURL
    }

    public func makeFeed() -> Feed {
        Feed(
            id: id, title: title, siteDescription: siteDescription,
            category: "Feeds", systemImage: systemImage,
            feedURL: feedURL, siteURL: siteURL, healthScore: 1
        )
    }
}

/// Grow-only article metadata. Read/starred state stays in DeviceStateDocument;
/// the regenerable body stays in a bounded per-device body shard.
public struct ArticleContent: Codable, Sendable, Equatable {
    public var id: Article.ID
    public var feedID: Feed.ID
    public var title: String
    public var summary: String
    public var publishedAt: Date
    public var url: URL
    public var estimatedReadMinutes: Int

    public init(_ article: Article) {
        id = article.id
        feedID = article.feedID
        title = article.title
        summary = article.summary
        publishedAt = article.publishedAt
        url = article.url
        estimatedReadMinutes = article.estimatedReadMinutes
    }

    public func makeArticle(body: ArticleBody? = nil) -> Article {
        Article(
            id: id, feedID: feedID, title: title, summary: summary,
            bodyParagraphs: body?.bodyParagraphs ?? [], publishedAt: publishedAt,
            url: url, estimatedReadMinutes: estimatedReadMinutes,
            isRead: false, isStarred: false, contentHTML: body?.contentHTML
        )
    }
}

/// A state-based content CRDT. Every device publishes only its own file, but
/// republishes the accumulated register set after learning peer state.
public struct ContentShardDocument: Codable, Sendable, Equatable {
    public static let currentSchema = 2

    public var schema: Int
    public var deviceID: String
    public var generation: UInt64
    public var clock: HLC
    public var feeds: [Feed.ID: LWWRegister<FeedContent>]
    public var articles: [Article.ID: LWWRegister<ArticleContent>]

    public init(
        deviceID: String,
        generation: UInt64 = 0,
        clock: HLC = .zero,
        feeds: [Feed.ID: LWWRegister<FeedContent>] = [:],
        articles: [Article.ID: LWWRegister<ArticleContent>] = [:]
    ) {
        schema = Self.currentSchema
        self.deviceID = deviceID
        self.generation = generation
        self.clock = clock
        self.feeds = feeds
        self.articles = articles
    }

    enum CodingKeys: String, CodingKey { case schema, deviceID, generation, clock, feeds, articles }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decodeIfPresent(Int.self, forKey: .schema) ?? Self.currentSchema
        deviceID = try c.decode(String.self, forKey: .deviceID)
        generation = try c.decodeIfPresent(UInt64.self, forKey: .generation) ?? 0
        clock = try c.decodeIfPresent(HLC.self, forKey: .clock) ?? .zero
        feeds = try c.decodeIfPresent([Feed.ID: LWWRegister<FeedContent>].self, forKey: .feeds) ?? [:]
        articles = try c.decodeIfPresent([Article.ID: LWWRegister<ArticleContent>].self, forKey: .articles) ?? [:]
    }

    public func merged(with other: ContentShardDocument, as deviceID: String) -> ContentShardDocument {
        var result = self
        result.deviceID = deviceID
        result.clock = result.clock.witnessed(other.clock)
        for (id, register) in other.feeds {
            result.feeds[id] = result.feeds[id]?.merged(with: register) ?? register
        }
        for (id, register) in other.articles {
            result.articles[id] = result.articles[id]?.merged(with: register) ?? register
        }
        return result
    }

    public func materialize(bodies: [Article.ID: ArticleBody] = [:]) -> ReaderLibrary {
        ReaderLibrary(
            feeds: feeds.values.map { $0.value.makeFeed() },
            articles: articles.values.map { $0.value.makeArticle(body: bodies[$0.value.id]) },
            lastRefreshedAt: nil,
            folders: []
        )
    }
}

public struct BodyShardDocument: Codable, Sendable, Equatable {
    public static let currentSchema = 2
    public var schema = currentSchema
    public var deviceID: String
    public var generation: UInt64
    public var bodies: [Article.ID: ArticleBody]

    public init(deviceID: String, generation: UInt64 = 0, bodies: [Article.ID: ArticleBody] = [:]) {
        self.deviceID = deviceID
        self.generation = generation
        self.bodies = bodies
    }
}
