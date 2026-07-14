import Foundation
import Testing
@testable import NookKit

/// Feed membership is CRDT state: a feed a device seeded into its shard survives
/// even when the shared baseline no longer lists it, and a re-add beats an
/// earlier delete by last-writer-wins.
struct FeedMembershipTests {
    private func seeded(_ id: String, hlc: HLC) -> DeviceStateDocument {
        var shard = DeviceStateDocument(deviceID: "A")
        shard.setFeedSeed(id, FeedSeed(from: Fixture.feed(id)), hlc: hlc)
        shard.setFeedTombstone(id, false, hlc: hlc)
        return shard
    }

    @Test func seededFeedSurvivesABaselineThatLostIt() {
        // The baseline never learned about "b" (another device's overwrite), but
        // that device's shard seeded it — so it must still materialize.
        let base = Fixture.library(feeds: [Fixture.feed("a")], articles: [])
        let shard = seeded("b", hlc: Fixture.hlc(10))

        let merged = DeviceStateDocument.materialize(base: base, shards: [shard])

        #expect(Set(merged.feeds.map(\.id)) == ["a", "b"])
    }

    @Test func deleteAfterSeedRemovesTheFeed() {
        let base = Fixture.library(feeds: [Fixture.feed("a")], articles: [])
        var shard = seeded("a", hlc: Fixture.hlc(10))
        shard.setFeedTombstone("a", true, hlc: Fixture.hlc(20)) // deleted later

        let merged = DeviceStateDocument.materialize(base: base, shards: [shard])

        #expect(merged.feeds.isEmpty)
    }

    @Test func reAddAfterDeleteWinsByNewerClock() {
        let base = Fixture.library(feeds: [], articles: [])
        var shard = DeviceStateDocument(deviceID: "A")
        shard.setFeedSeed("a", FeedSeed(from: Fixture.feed("a")), hlc: Fixture.hlc(10))
        shard.setFeedTombstone("a", true, hlc: Fixture.hlc(20))  // deleted
        shard.setFeedTombstone("a", false, hlc: Fixture.hlc(30)) // re-added later

        let merged = DeviceStateDocument.materialize(base: base, shards: [shard])

        #expect(merged.feeds.map(\.id) == ["a"])
    }

    @Test func seededFeedInheritsShardOverrides() {
        let base = Fixture.library(feeds: [], articles: [])
        var shard = seeded("a", hlc: Fixture.hlc(10))
        shard.setFeedCategory("a", "Work", hlc: Fixture.hlc(11))

        let merged = DeviceStateDocument.materialize(base: base, shards: [shard])

        #expect(merged.feeds.first?.category == "Work")
    }
}
