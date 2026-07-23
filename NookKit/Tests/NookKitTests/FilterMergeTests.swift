import Foundation
import Testing
@testable import NookKit

@Suite("Article filter sync (per-item CRDT)")
struct FilterMergeTests {
    private func shard(_ deviceID: String, _ build: (inout DeviceStateDocument) -> Void) -> DeviceStateDocument {
        var doc = DeviceStateDocument(deviceID: deviceID)
        build(&doc)
        return doc
    }

    private func filter(_ id: String, _ pattern: String, order: Int = 0) -> ArticleFilter {
        ArticleFilter(id: id, kind: .plainText, pattern: pattern, order: order)
    }

    @Test("materialize carries the merged filters, sorted by (order, id)")
    func materializeCarriesFilters() {
        let base = Fixture.library(feeds: [Fixture.feed("f1")], articles: [])
        let device = shard("A") {
            $0.setFilter("b", filter("b", "sponsored", order: 1), hlc: Fixture.hlc(1000, node: "A"))
            $0.setFilter("a", filter("a", "ads", order: 0), hlc: Fixture.hlc(1001, node: "A"))
        }
        let merged = DeviceStateDocument.materialize(base: base, shards: [device])
        #expect(merged.filters.map(\.pattern) == ["ads", "sponsored"])
    }

    @Test("Concurrent edits to DIFFERENT filters both survive")
    func concurrentDifferentFiltersBothSurvive() {
        let base = Fixture.library(feeds: [], articles: [])
        let deviceA = shard("A") { $0.setFilter("a", filter("a", "ads", order: 0), hlc: Fixture.hlc(1000, node: "A")) }
        let deviceB = shard("B") { $0.setFilter("b", filter("b", "spam", order: 1), hlc: Fixture.hlc(1000, node: "B")) }

        // Order-independent: both permutations keep BOTH filters — the exact win
        // over whole-list LWW, which would have dropped one.
        let ab = DeviceStateDocument.materialize(base: base, shards: [deviceA, deviceB])
        let ba = DeviceStateDocument.materialize(base: base, shards: [deviceB, deviceA])
        #expect(ab.filters.map(\.pattern) == ["ads", "spam"])
        #expect(ba.filters.map(\.pattern) == ["ads", "spam"])
    }

    @Test("The higher-HLC edit wins on the SAME filter")
    func higherClockWinsSameFilter() {
        let base = Fixture.library(feeds: [], articles: [])
        let early = shard("A") { $0.setFilter("a", filter("a", "old", order: 0), hlc: Fixture.hlc(1000, node: "A")) }
        let late = shard("B") { $0.setFilter("a", filter("a", "new", order: 0), hlc: Fixture.hlc(2000, node: "B")) }

        let ab = DeviceStateDocument.materialize(base: base, shards: [early, late])
        let ba = DeviceStateDocument.materialize(base: base, shards: [late, early])
        #expect(ab.filters.map(\.pattern) == ["new"])
        #expect(ba.filters.map(\.pattern) == ["new"])
    }

    @Test("A deletion tombstone wins over a lower-HLC edit and syncs")
    func tombstoneWins() {
        let base = Fixture.library(feeds: [], articles: [])
        let added = shard("A") { $0.setFilter("a", filter("a", "x", order: 0), hlc: Fixture.hlc(1000, node: "A")) }
        let deleted = shard("B") { $0.setFilterTombstone("a", true, hlc: Fixture.hlc(2000, node: "B")) }

        let merged = DeviceStateDocument.materialize(base: base, shards: [added, deleted])
        #expect(merged.filters.isEmpty)
    }

    @Test("A once-tombstoned id stays deleted even with a newer value on that id")
    func tombstonedIdStaysDeleted() {
        // materialize drops any filter whose tombstone is true, regardless of the
        // value's clock — so a deleted filter never resurrects. This is why the
        // store gives every newly-added filter a fresh UUID rather than reusing a
        // deleted id.
        let base = Fixture.library(feeds: [], articles: [])
        let deleted = shard("A") { $0.setFilterTombstone("a", true, hlc: Fixture.hlc(1000, node: "A")) }
        let newerValue = shard("A") { $0.setFilter("a", filter("a", "y", order: 0), hlc: Fixture.hlc(2000, node: "A")) }
        let merged = DeviceStateDocument.materialize(base: base, shards: [deleted, newerValue])
        #expect(merged.filters.isEmpty)
    }

    @Test("No filters anywhere materializes to an empty list")
    func emptyByDefault() {
        let base = Fixture.library(feeds: [Fixture.feed("f1")], articles: [])
        let merged = DeviceStateDocument.materialize(base: base, shards: [shard("A") { _ in }])
        #expect(merged.filters.isEmpty)
    }
}
