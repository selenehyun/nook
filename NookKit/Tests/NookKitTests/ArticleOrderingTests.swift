import Foundation
import Testing
@testable import NookKit

@Suite("Article ordering")
struct ArticleOrderingTests {
    @Test("Identical timestamps keep a stable order regardless of input order")
    func stableWithEqualTimestamps() {
        // Fixture.article stamps every article with the same publishedAt.
        let ids = ["a", "b", "c", "d", "e"]
        let articles = ids.map { Fixture.article($0, feedID: "f") }

        let forward = articles.sorted(by: Article.isOrderedBefore).map(\.id)
        let reversed = articles.reversed().sorted(by: Article.isOrderedBefore).map(\.id)

        #expect(forward == reversed)
        // Tie-break is by id descending (newest-first primary order).
        #expect(forward == ["e", "d", "c", "b", "a"])
    }

    @Test("Newer publish time still wins over the id tie-break")
    func newerTimestampFirst() {
        var older = Fixture.article("z", feedID: "f")
        older.publishedAt = Date(timeIntervalSince1970: 1_600_000_000)
        let newer = Fixture.article("a", feedID: "f") // later timestamp via fixture default

        let sorted = [older, newer].sorted(by: Article.isOrderedBefore).map(\.id)
        #expect(sorted == ["a", "z"])
    }
}
