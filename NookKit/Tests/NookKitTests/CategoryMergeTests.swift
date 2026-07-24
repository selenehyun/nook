import Foundation
import Testing
@testable import NookKit

@Suite("Article category sync (per-item CRDT + per-article assignment)")
struct CategoryMergeTests {
    private func shard(_ deviceID: String, _ build: (inout DeviceStateDocument) -> Void) -> DeviceStateDocument {
        var doc = DeviceStateDocument(deviceID: deviceID)
        build(&doc)
        return doc
    }

    private func category(_ id: String, _ name: String, order: Int = 0, hidden: Bool = false) -> ArticleCategory {
        ArticleCategory(id: id, name: name, order: order, hidden: hidden)
    }

    @Test("Definitions: concurrent adds of different categories both survive, sorted")
    func concurrentDefinitionsSurvive() {
        let base = Fixture.library(feeds: [], articles: [])
        let a = shard("A") { $0.setCategory("a", category("a", "Apple", order: 0), hlc: Fixture.hlc(1000, node: "A")) }
        let b = shard("B") { $0.setCategory("b", category("b", "AI", order: 1), hlc: Fixture.hlc(1000, node: "B")) }
        let ab = DeviceStateDocument.materialize(base: base, shards: [a, b])
        let ba = DeviceStateDocument.materialize(base: base, shards: [b, a])
        #expect(ab.categories.map(\.name) == ["Apple", "AI"])
        #expect(ba.categories.map(\.name) == ["Apple", "AI"])
    }

    @Test("Definitions: higher-HLC edit wins; tombstone removes")
    func definitionEditAndDelete() {
        let base = Fixture.library(feeds: [], articles: [])
        let early = shard("A") { $0.setCategory("a", category("a", "Old", order: 0), hlc: Fixture.hlc(1000, node: "A")) }
        let renamed = shard("B") { $0.setCategory("a", category("a", "New", order: 0), hlc: Fixture.hlc(2000, node: "B")) }
        #expect(DeviceStateDocument.materialize(base: base, shards: [early, renamed]).categories.map(\.name) == ["New"])

        let deleted = shard("C") { $0.setCategoryTombstone("a", true, hlc: Fixture.hlc(3000, node: "C")) }
        #expect(DeviceStateDocument.materialize(base: base, shards: [early, renamed, deleted]).categories.isEmpty)
    }

    @Test("Per-article assignment merges across devices by HLC and materializes onto the article")
    func perArticleAssignment() {
        let base = Fixture.library(feeds: [Fixture.feed("f1")], articles: [Fixture.article("a1", feedID: "f1")])
        let early = shard("A") { $0.setArticleCategories("a1", ["x"], hlc: Fixture.hlc(1000, node: "A")) }
        let late = shard("B") { $0.setArticleCategories("a1", ["x", "y"], hlc: Fixture.hlc(2000, node: "B")) }
        let merged = DeviceStateDocument.materialize(base: base, shards: [early, late])
        #expect(merged.articles.first?.categories == ["x", "y"])
        // Order-independent.
        let merged2 = DeviceStateDocument.materialize(base: base, shards: [late, early])
        #expect(merged2.articles.first?.categories == ["x", "y"])
    }

    @Test("Category keyword matching is a plain case-optional substring test")
    func keywordMatching() {
        let apple = ArticleCategory(name: "Apple", keywords: ["WWDC", "iPhone"], keywordMatchTarget: .titleAndSummary)
        #expect(apple.matchesKeywords(title: "Everything at WWDC 2026", summary: ""))
        #expect(apple.matchesKeywords(title: "cheap wwdc tickets", summary: ""))       // case-insensitive by default
        #expect(!apple.matchesKeywords(title: "Android news", summary: "Pixel event"))
        let caseSensitive = ArticleCategory(name: "Apple", keywords: ["WWDC"], keywordCaseSensitive: true)
        #expect(!caseSensitive.matchesKeywords(title: "wwdc lowercase", summary: ""))
    }
}
