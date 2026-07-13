import Foundation
@testable import NookKit

/// Builders that keep the CRDT tests focused on merge behaviour rather than
/// model boilerplate.
enum Fixture {
    static func hlc(_ millis: Int64, _ counter: UInt32 = 0, node: String = "n") -> HLC {
        HLC(physicalMillis: millis, counter: counter, node: node)
    }

    static func feed(_ id: String, category: String = "Feeds") -> Feed {
        Feed(
            id: id,
            title: id,
            siteDescription: "",
            category: category,
            systemImage: "dot.radiowaves.left.and.right",
            feedURL: URL(string: "https://example.com/\(id)/feed.xml")!,
            siteURL: URL(string: "https://example.com/\(id)")!,
            healthScore: 1
        )
    }

    static func article(_ id: String, feedID: String, isRead: Bool = false, isStarred: Bool = false) -> Article {
        Article(
            id: id,
            feedID: feedID,
            title: id,
            summary: "",
            bodyParagraphs: [],
            publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
            url: URL(string: "https://example.com/\(id)")!,
            estimatedReadMinutes: 1,
            isRead: isRead,
            isStarred: isStarred
        )
    }

    static func library(feeds: [Feed], articles: [Article], folders: [String] = []) -> ReaderLibrary {
        ReaderLibrary(feeds: feeds, articles: articles, lastRefreshedAt: nil, folders: folders)
    }
}
