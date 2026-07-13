import Foundation
import Testing
@testable import NookKit

@Suite("DeviceStateDocument.materialize")
struct MaterializeTests {
    private func shard(_ deviceID: String, _ build: (inout DeviceStateDocument) -> Void) -> DeviceStateDocument {
        var doc = DeviceStateDocument(deviceID: deviceID)
        build(&doc)
        return doc
    }

    /// The exact bug this whole redesign fixes: two devices each read a
    /// different article offline. After merge, BOTH reads must survive.
    @Test("Concurrent reads on different articles both survive")
    func concurrentReadsBothSurvive() {
        let base = Fixture.library(
            feeds: [Fixture.feed("f1")],
            articles: [
                Fixture.article("a1", feedID: "f1"),
                Fixture.article("a2", feedID: "f1"),
            ]
        )
        let deviceA = shard("A") { $0.setArticleRead("a1", true, hlc: Fixture.hlc(1000, node: "A")) }
        let deviceB = shard("B") { $0.setArticleRead("a2", true, hlc: Fixture.hlc(1000, node: "B")) }

        let merged = DeviceStateDocument.materialize(base: base, shards: [deviceA, deviceB])
        let byID = Dictionary(uniqueKeysWithValues: merged.articles.map { ($0.id, $0) })
        #expect(byID["a1"]?.isRead == true)
        #expect(byID["a2"]?.isRead == true)
    }

    @Test("The higher-HLC write wins on the same field")
    func higherClockWins() {
        let base = Fixture.library(feeds: [Fixture.feed("f1")], articles: [Fixture.article("a1", feedID: "f1")])
        let readEarly = shard("A") { $0.setArticleRead("a1", true, hlc: Fixture.hlc(1000, node: "A")) }
        let unreadLate = shard("B") { $0.setArticleRead("a1", false, hlc: Fixture.hlc(2000, node: "B")) }

        let merged = DeviceStateDocument.materialize(base: base, shards: [readEarly, unreadLate])
        #expect(merged.articles.first?.isRead == false)
    }

    @Test("Baseline read/starred survive when no shard touched the field")
    func baselineFallback() {
        let base = Fixture.library(
            feeds: [Fixture.feed("f1")],
            articles: [Fixture.article("a1", feedID: "f1", isRead: true, isStarred: true)]
        )
        let merged = DeviceStateDocument.materialize(base: base, shards: [])
        #expect(merged.articles.first?.isRead == true)
        #expect(merged.articles.first?.isStarred == true)
    }

    @Test("A feed tombstone drops the feed and its articles")
    func tombstoneDropsFeedAndArticles() {
        let base = Fixture.library(
            feeds: [Fixture.feed("f1"), Fixture.feed("f2")],
            articles: [
                Fixture.article("a1", feedID: "f1"),
                Fixture.article("a2", feedID: "f2"),
            ]
        )
        // A deletes f1; B (unaware) re-categorises f1. Tombstone must still win.
        let deleter = shard("A") { $0.setFeedTombstone("f1", true, hlc: Fixture.hlc(2000, node: "A")) }
        let editor = shard("B") { $0.setFeedCategory("f1", "News", hlc: Fixture.hlc(1000, node: "B")) }

        let merged = DeviceStateDocument.materialize(base: base, shards: [deleter, editor])
        #expect(merged.feeds.map(\.id) == ["f2"])
        #expect(merged.articles.map(\.id) == ["a2"])
    }

    @Test("Feed category and view-mode overrides apply")
    func feedOverridesApply() {
        let base = Fixture.library(feeds: [Fixture.feed("f1", category: "Feeds")], articles: [])
        let editor = shard("A") {
            $0.setFeedCategory("f1", "Tech", hlc: Fixture.hlc(1000, node: "A"))
            $0.setFeedViewMode("f1", .original, hlc: Fixture.hlc(1001, node: "A"))
        }
        let merged = DeviceStateDocument.materialize(base: base, shards: [editor])
        #expect(merged.feeds.first?.category == "Tech")
        #expect(merged.feeds.first?.preferredViewMode == .original)
    }

    @Test("Folder add/remove registers adjust the folder set")
    func folderAddRemove() {
        let base = Fixture.library(feeds: [], articles: [], folders: ["Kept"])
        let device = shard("A") {
            $0.setFolderPresent("Added", true, hlc: Fixture.hlc(1000, node: "A"))
            $0.setFolderPresent("Kept", false, hlc: Fixture.hlc(1001, node: "A"))
        }
        let merged = DeviceStateDocument.materialize(base: base, shards: [device])
        #expect(Set(merged.folders) == ["Added"])
    }

    /// Merge must not depend on the order shards are loaded from disk.
    @Test("Materialize is order-independent")
    func orderIndependent() {
        let base = Fixture.library(
            feeds: [Fixture.feed("f1"), Fixture.feed("f2")],
            articles: [
                Fixture.article("a1", feedID: "f1"),
                Fixture.article("a2", feedID: "f1"),
                Fixture.article("a3", feedID: "f2"),
            ]
        )
        let shards = [
            shard("A") {
                $0.setArticleRead("a1", true, hlc: Fixture.hlc(1000, node: "A"))
                $0.setArticleStarred("a3", true, hlc: Fixture.hlc(1500, node: "A"))
            },
            shard("B") {
                $0.setArticleRead("a1", false, hlc: Fixture.hlc(2000, node: "B"))
                $0.setArticleRead("a2", true, hlc: Fixture.hlc(1200, node: "B"))
            },
            shard("C") {
                $0.setFeedTombstone("f2", true, hlc: Fixture.hlc(3000, node: "C"))
            },
        ]

        func fingerprint(_ library: ReaderLibrary) -> [String] {
            library.articles
                .sorted { $0.id < $1.id }
                .map { "\($0.id):\($0.isRead ? "r" : "u"):\($0.isStarred ? "s" : "-")" }
                + ["feeds=" + library.feeds.map(\.id).sorted().joined(separator: ",")]
        }

        let reference = fingerprint(DeviceStateDocument.materialize(base: base, shards: shards))
        for permutation in permutations(shards) {
            #expect(fingerprint(DeviceStateDocument.materialize(base: base, shards: permutation)) == reference)
        }
        // a1 unread (B's 2000 beats A's 1000); a2 read; a3 gone with tombstoned f2.
        #expect(reference.contains("a1:u:-"))
        #expect(reference.contains("a2:r:-"))
        #expect(reference.contains("feeds=f1"))
    }

    private func permutations<T>(_ items: [T]) -> [[T]] {
        guard items.count > 1 else { return [items] }
        var result: [[T]] = []
        for (index, item) in items.enumerated() {
            var rest = items
            rest.remove(at: index)
            for tail in permutations(rest) {
                result.append([item] + tail)
            }
        }
        return result
    }
}
