import Foundation
import Testing
@testable import NookKit

/// The content baseline is grow-only on write: a stale in-memory snapshot must
/// never drop a feed/article another device added and that already reached this
/// device's on-disk file. Removal is expressed via shard tombstones, not by
/// absence from a save.
struct AdditiveSaveTests {
    @Test func keepsOnDiskFeedMissingFromTheIncomingSnapshot() {
        let onDisk = Fixture.library(
            feeds: [Fixture.feed("a"), Fixture.feed("b")],
            articles: [Fixture.article("a1", feedID: "a"), Fixture.article("b1", feedID: "b")]
        )
        // This device never saw feed "b" — a plain overwrite would erase it.
        let incoming = Fixture.library(
            feeds: [Fixture.feed("a")],
            articles: [Fixture.article("a1", feedID: "a")]
        )

        let merged = ReaderStorage.additivelyMerged(incoming: incoming, onDisk: onDisk)

        #expect(Set(merged.feeds.map(\.id)) == ["a", "b"])
        #expect(Set(merged.articles.map(\.id)) == ["a1", "b1"])
    }

    @Test func incomingWinsForSharedIdsAndAddsItsOwn() {
        let onDisk = Fixture.library(feeds: [Fixture.feed("a", category: "Old")], articles: [])
        let incoming = Fixture.library(
            feeds: [Fixture.feed("a", category: "New"), Fixture.feed("c")],
            articles: [Fixture.article("c1", feedID: "c")]
        )

        let merged = ReaderStorage.additivelyMerged(incoming: incoming, onDisk: onDisk)

        #expect(Set(merged.feeds.map(\.id)) == ["a", "c"])
        #expect(merged.feeds.first { $0.id == "a" }?.category == "New")
        #expect(merged.articles.map(\.id) == ["c1"])
    }

    @Test func noDiskFileUsesIncomingVerbatim() {
        let incoming = Fixture.library(feeds: [Fixture.feed("a")], articles: [])
        let merged = ReaderStorage.additivelyMerged(incoming: incoming, onDisk: nil)
        #expect(merged.feeds.map(\.id) == ["a"])
    }

    @Test func unionsFolders() {
        let onDisk = Fixture.library(feeds: [], articles: [], folders: ["Work"])
        let incoming = Fixture.library(feeds: [], articles: [], folders: ["Personal"])
        let merged = ReaderStorage.additivelyMerged(incoming: incoming, onDisk: onDisk)
        #expect(Set(merged.folders) == ["Work", "Personal"])
    }
}
