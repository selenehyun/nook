import Foundation
import Testing
@testable import NookKit

@Suite("ReaderStorage shard round-trip")
struct ShardStorageTests {
    private func makeTempStorage() throws -> (ReaderStorage, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "NookKitTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (ReaderStorage(directoryURL: dir), dir)
    }

    private func shard(_ deviceID: String, read articleID: String) -> DeviceStateDocument {
        var doc = DeviceStateDocument(deviceID: deviceID, updatedAt: Date(timeIntervalSince1970: 1000))
        doc.setArticleRead(articleID, true, hlc: Fixture.hlc(1000, node: deviceID))
        return doc
    }

    @Test("saveShard then loadShards returns every device's shard")
    func saveAndLoadAll() throws {
        let (storage, dir) = try makeTempStorage()
        defer { try? FileManager.default.removeItem(at: dir) }

        let a = shard("device-A", read: "a1")
        let b = shard("device-B", read: "a2")
        try storage.saveShard(a)
        try storage.saveShard(b)

        let loaded = try storage.loadShards().sorted { $0.deviceID < $1.deviceID }
        #expect(loaded == [a, b])
    }

    @Test("loadOwnShard returns only this device's shard")
    func loadOwn() throws {
        let (storage, dir) = try makeTempStorage()
        defer { try? FileManager.default.removeItem(at: dir) }

        let a = shard("device-A", read: "a1")
        try storage.saveShard(a)
        try storage.saveShard(shard("device-B", read: "a2"))

        #expect(storage.loadOwnShard(deviceID: "device-A") == a)
        #expect(storage.loadOwnShard(deviceID: "missing") == nil)
    }

    @Test("Re-saving a device's shard overwrites in place (no conflict siblings)")
    func resaveOverwrites() throws {
        let (storage, dir) = try makeTempStorage()
        defer { try? FileManager.default.removeItem(at: dir) }

        try storage.saveShard(shard("device-A", read: "a1"))
        var updated = shard("device-A", read: "a1")
        updated.setArticleStarred("a1", true, hlc: Fixture.hlc(2000, node: "device-A"))
        try storage.saveShard(updated)

        let loaded = try storage.loadShards()
        #expect(loaded.count == 1)
        #expect(loaded.first?.articleState["a1"]?.isStarred?.value == true)
    }

    @Test("loadShards on a folder with no state directory is empty, not an error")
    func emptyWhenNoStateDir() throws {
        let (storage, dir) = try makeTempStorage()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try storage.loadShards().isEmpty)
    }
}
