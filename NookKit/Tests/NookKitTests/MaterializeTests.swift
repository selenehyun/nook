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

    @Test("Seen state merges across devices by HLC")
    func seenMergesAcrossDevices() {
        // Device A saw a1 in its list; B never did. The merged state must report
        // a1 seen and a2 not, so a background refresh on either device skips
        // notifying about a1 but can still notify about a2.
        let deviceA = shard("A") { $0.setArticleSeen("a1", true, hlc: Fixture.hlc(1000, node: "A")) }
        let deviceB = shard("B") { $0.setArticleRead("a2", false, hlc: Fixture.hlc(1000, node: "B")) }

        let merged = DeviceStateDocument.mergedState(from: [deviceA, deviceB])
        #expect(merged.articles["a1"]?.seen?.value == true)
        #expect(merged.articles["a2"]?.seen?.value == nil)

        // A later "unseen" (higher HLC) wins, so seen is a normal LWW register.
        let unsee = shard("B") { $0.setArticleSeen("a1", false, hlc: Fixture.hlc(2000, node: "B")) }
        let after = DeviceStateDocument.mergedState(from: [deviceA, unsee])
        #expect(after.articles["a1"]?.seen?.value == false)
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

    @Test("A feed rename (custom title) merges by HLC and applies")
    func feedRenameApplies() {
        let base = Fixture.library(feeds: [Fixture.feed("f1")], articles: [])
        // f1's fixture title is "f1". Two devices rename it; higher HLC wins.
        let deviceA = shard("A") { $0.setFeedTitle("f1", "Old Name", hlc: Fixture.hlc(1000, node: "A")) }
        let deviceB = shard("B") { $0.setFeedTitle("f1", "New Name", hlc: Fixture.hlc(2000, node: "B")) }

        let merged = DeviceStateDocument.materialize(base: base, shards: [deviceA, deviceB])
        #expect(merged.feeds.first?.customTitle == "New Name")
        #expect(merged.feeds.first?.displayTitle == "New Name")

        // Clearing the override (nil) reverts to the feed-provided title.
        let clear = shard("A") { $0.setFeedTitle("f1", nil, hlc: Fixture.hlc(3000, node: "A")) }
        let reverted = DeviceStateDocument.materialize(base: base, shards: [deviceB, clear])
        #expect(reverted.feeds.first?.customTitle == nil)
        #expect(reverted.feeds.first?.displayTitle == "f1")
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

    // MARK: Canonical dedup (fixes cross-device "Unknown Feed" + duplicates)

    @Test("Trailing-slash feed aliases collapse; split copies merge by seed; a matching orphan is absorbed; a unique orphan is kept")
    func canonicalFeedAndArticleDedup() {
        func feed(_ url: String) -> Feed {
            Feed(id: url, title: url, siteDescription: "", category: "Feeds",
                 systemImage: "dot", feedURL: URL(string: url)!, siteURL: URL(string: url)!, healthScore: 1)
        }
        // Article ids follow the real "\(feedID)#\(seed)" convention.
        func art(feedID: String, seed: String, url: String, isRead: Bool = false) -> Article {
            Article(id: "\(feedID)#\(seed)", feedID: feedID, title: seed, summary: "", bodyParagraphs: [],
                    publishedAt: Date(timeIntervalSince1970: 1_700_000_000), url: URL(string: url)!,
                    estimatedReadMinutes: 1, isRead: isRead, isStarred: false)
        }
        let base = Fixture.library(
            feeds: [feed("https://x.com/feed"), feed("https://x.com/feed/")],   // same subscription, two urls
            articles: [
                art(feedID: "https://x.com/feed", seed: "p1", url: "https://x.com/p1", isRead: true),
                art(feedID: "https://x.com/feed/", seed: "p1", url: "https://x.com/p1"),        // same item under the alias
                art(feedID: "https://x.com/feed", seed: "p2", url: "https://x.com/p2"),
                art(feedID: "https://x.com/feed/feed", seed: "p2", url: "https://x.com/p2"),    // orphan, url-dup of p2
                art(feedID: "https://x.com/ghost", seed: "p3", url: "https://x.com/p3"),        // orphan, unique -> kept
            ]
        )
        let merged = DeviceStateDocument.materialize(base: base, shards: [])

        let canonicalID = "https://x.com/feed"
        let urls = Set(merged.articles.map { $0.url.absoluteString })
        let p1Read = merged.articles.first { $0.url.absoluteString == "https://x.com/p1" }?.isRead
        let p2FeedID = merged.articles.first { $0.url.absoluteString == "https://x.com/p2" }?.feedID

        #expect(merged.feeds.count == 1)                              // trailing-slash aliases collapse
        #expect(merged.feeds.first?.id == canonicalID)               // deterministic canonical (min id)
        #expect(urls == ["https://x.com/p1", "https://x.com/p2", "https://x.com/p3"])
        #expect(p1Read == true)                                      // read carried on the merged item
        #expect(p2FeedID == canonicalID)                             // orphan absorbed under the canonical feed
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
