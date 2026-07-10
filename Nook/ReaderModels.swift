import Foundation

struct ReaderLibrary: Codable {
    var feeds: [Feed]
    var articles: [Article]
    var lastRefreshedAt: Date?
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
