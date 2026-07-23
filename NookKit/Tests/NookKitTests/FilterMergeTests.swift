import Foundation
import Testing
@testable import NookKit

@Suite("Article filter sync (whole-list LWW register)")
struct FilterMergeTests {
    private func shard(_ deviceID: String, _ build: (inout DeviceStateDocument) -> Void) -> DeviceStateDocument {
        var doc = DeviceStateDocument(deviceID: deviceID)
        build(&doc)
        return doc
    }

    private func filter(_ id: String, _ pattern: String) -> ArticleFilter {
        ArticleFilter(id: id, kind: .plainText, pattern: pattern)
    }

    @Test("materialize carries the merged filter list onto the library")
    func materializeCarriesFilters() {
        let base = Fixture.library(feeds: [Fixture.feed("f1")], articles: [])
        let device = shard("A") {
            $0.setFilters([filter("1", "ads"), filter("2", "sponsored")], hlc: Fixture.hlc(1000, node: "A"))
        }
        let merged = DeviceStateDocument.materialize(base: base, shards: [device])
        #expect(merged.filters.map(\.pattern) == ["ads", "sponsored"])
    }

    @Test("The higher-HLC filter list wins")
    func higherClockWins() {
        let base = Fixture.library(feeds: [], articles: [])
        let early = shard("A") { $0.setFilters([filter("1", "old")], hlc: Fixture.hlc(1000, node: "A")) }
        let late = shard("B") { $0.setFilters([filter("2", "new")], hlc: Fixture.hlc(2000, node: "B")) }

        // Merge is order-independent: both permutations converge to the later write.
        let ab = DeviceStateDocument.materialize(base: base, shards: [early, late])
        let ba = DeviceStateDocument.materialize(base: base, shards: [late, early])
        #expect(ab.filters.map(\.pattern) == ["new"])
        #expect(ba.filters.map(\.pattern) == ["new"])
    }

    @Test("A shard that never wrote filters doesn't erase a peer's")
    func presentBeatsMissing() {
        let base = Fixture.library(feeds: [], articles: [])
        let withFilters = shard("A") { $0.setFilters([filter("1", "spam")], hlc: Fixture.hlc(1000, node: "A")) }
        let without = shard("B") { $0.setArticleRead("x", true, hlc: Fixture.hlc(5000, node: "B")) }

        let merged = DeviceStateDocument.materialize(base: base, shards: [withFilters, without])
        #expect(merged.filters.map(\.pattern) == ["spam"])
    }

    @Test("No filters anywhere materializes to an empty list")
    func emptyByDefault() {
        let base = Fixture.library(feeds: [Fixture.feed("f1")], articles: [])
        let merged = DeviceStateDocument.materialize(base: base, shards: [shard("A") { _ in }])
        #expect(merged.filters.isEmpty)
    }

    @Test("Clearing filters later (higher HLC) wins over an earlier non-empty list")
    func clearWins() {
        let base = Fixture.library(feeds: [], articles: [])
        let added = shard("A") { $0.setFilters([filter("1", "x")], hlc: Fixture.hlc(1000, node: "A")) }
        let cleared = shard("A") { $0.setFilters([], hlc: Fixture.hlc(2000, node: "A")) }
        let merged = DeviceStateDocument.materialize(base: base, shards: [added, cleared])
        #expect(merged.filters.isEmpty)
    }
}
