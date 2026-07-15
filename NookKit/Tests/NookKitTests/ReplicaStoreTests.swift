import Foundation
import Testing
@testable import NookKit

@Suite("Content replica v2")
struct ReplicaStoreTests {
    private func fixture() throws -> (ReaderStorage, ReplicaStore, URL, URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "nook-replica-\(UUID())", directoryHint: .isDirectory)
        let sync = root.appending(path: "sync", directoryHint: .isDirectory)
        let db = root.appending(path: "db", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sync, withIntermediateDirectories: true)
        let storage = ReaderStorage(directoryURL: sync)
        return (storage, try ReplicaStore(syncDirectory: sync, deviceID: "v2", databaseDirectory: db), root, sync)
    }

    private func writeLegacy(_ library: ReaderLibrary, to storage: ReaderStorage) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(library).write(to: storage.libraryURL, options: .atomic)
    }

    @Test("A shrinking v1 baseline never removes observed v2 content")
    func legacyShrinkIsAddOnly() throws {
        let (storage, replica, root, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = Fixture.article("a", feedID: "f")
        try writeLegacy(Fixture.library(feeds: [Fixture.feed("f")], articles: [a]), to: storage)
        #expect(try replica.reconcile(storage: storage).library.articles.map(\.id).contains("a"))

        try writeLegacy(Fixture.library(feeds: [], articles: []), to: storage)
        #expect(try replica.reconcile(storage: storage).library.articles.map(\.id).contains("a"))
    }

    @Test("Legacy adds missing IDs but cannot overwrite a v2 payload")
    func legacyCannotOverwriteV2() throws {
        let (storage, replica, root, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var modern = Fixture.article("a", feedID: "f")
        modern.title = "v2"
        _ = try replica.recordLocal(Fixture.library(feeds: [Fixture.feed("f")], articles: [modern]), retainBodies: [])

        var stale = modern
        stale.title = "v1 stale"
        let b = Fixture.article("b", feedID: "f")
        try writeLegacy(Fixture.library(feeds: [Fixture.feed("f")], articles: [stale, b]), to: storage)
        let snapshot = try replica.reconcile(storage: storage)
        let byID = Dictionary(uniqueKeysWithValues: snapshot.library.articles.map { ($0.id, $0) })
        #expect(byID["a"]?.title == "v2")
        #expect(byID["b"] != nil)
    }

    @Test("Publishing v2 never changes NookLibrary.json")
    func publishDoesNotWriteLegacy() throws {
        let (storage, replica, root, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeLegacy(Fixture.library(feeds: [Fixture.feed("f")], articles: []), to: storage)
        let before = try Data(contentsOf: storage.libraryURL)
        _ = try replica.reconcile(storage: storage)
        try replica.publishIfNeeded(to: storage)
        #expect(try Data(contentsOf: storage.libraryURL) == before)
        #expect(storage.loadOwnContentShard(deviceID: "v2") != nil)
    }

    @Test("Older and duplicate peer snapshots cannot regress registers")
    func stalePeerCannotRegress() throws {
        let (storage, replica, root, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let newer = ArticleContent(Fixture.article("a", feedID: "f"))
        var olderValue = newer
        olderValue.title = "old"
        var newDoc = ContentShardDocument(deviceID: "peer", generation: 2)
        newDoc.articles["a"] = LWWRegister(value: newer, hlc: Fixture.hlc(2, node: "peer"))
        try storage.saveContentShard(newDoc)
        #expect(try replica.reconcile(storage: storage).library.articles.first?.title == "a")

        var oldDoc = ContentShardDocument(deviceID: "peer", generation: 1)
        oldDoc.articles["a"] = LWWRegister(value: olderValue, hlc: Fixture.hlc(1, node: "peer"))
        try storage.saveContentShard(oldDoc)
        #expect(try replica.reconcile(storage: storage).library.articles.first?.title == "a")
    }

    @Test("Legacy migration is silent and a new local article reserves once")
    func notificationReceiptsAreDeviceLocalAndAtMostOnce() throws {
        let (storage, replica, root, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = Fixture.article("old", feedID: "f")
        try writeLegacy(Fixture.library(feeds: [Fixture.feed("f")], articles: [old]), to: storage)
        _ = try replica.reconcile(storage: storage)
        #expect(try replica.reserveNotifications(for: [old]).isEmpty)

        let fresh = Fixture.article("fresh", feedID: "f")
        _ = try replica.recordLocal(Fixture.library(feeds: [Fixture.feed("f")], articles: [old, fresh]), retainBodies: [])
        #expect(try replica.reserveNotifications(for: [old, fresh]).map(\.id) == ["fresh"])
        #expect(try replica.reserveNotifications(for: [fresh]).isEmpty)
    }

    @Test("Legacy folders and read state are seeded without replacing newer registers")
    func legacyUserStateSeedPreservesLibraryShape() {
        var feed = Fixture.feed("f", category: "Design")
        feed.customTitle = "My Feed"
        let read = Fixture.article("read", feedID: "f", isRead: true, isStarred: true)
        let unread = Fixture.article("unread", feedID: "f")
        let legacy = Fixture.library(feeds: [feed], articles: [read, unread], folders: ["Empty Folder"])

        var shard = DeviceStateDocument(deviceID: "v2")
        var peer = DeviceStateDocument(deviceID: "peer")
        peer.setArticleRead("read", false, hlc: Fixture.hlc(10, node: "peer"))
        _ = shard.seedLegacyUserState(
            from: legacy, whereMissingFrom: [peer],
            after: Fixture.hlc(10, node: "v2"), node: "v2"
        )

        let contentOnly = ReaderLibrary(
            feeds: [FeedContent(feed).makeFeed()],
            articles: [ArticleContent(read).makeArticle(), ArticleContent(unread).makeArticle()],
            lastRefreshedAt: nil,
            folders: []
        )
        let materialized = DeviceStateDocument.materialize(base: contentOnly, shards: [shard, peer])
        #expect(materialized.feeds.first?.category == "Design")
        #expect(materialized.feeds.first?.customTitle == "My Feed")
        #expect(Set(materialized.folders) == ["Design", "Empty Folder"])
        #expect(materialized.articles.first(where: { $0.id == "read" })?.isRead == false)
        #expect(materialized.articles.first(where: { $0.id == "read" })?.isStarred == true)
        #expect(materialized.articles.first(where: { $0.id == "unread" })?.isRead == false)
    }
}
