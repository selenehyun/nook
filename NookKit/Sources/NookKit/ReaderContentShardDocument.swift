import Foundation

/// One article's reader-mode extraction result, synced across devices.
/// Regenerable content, so a `.failed` marker is kept too — it stops every
/// device from re-fetching a page that has no extractable article.
public struct ReaderContentValue: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable {
        case success
        case failed
    }

    public var status: Status
    /// The extracted reader HTML for `.success`; `nil` for `.failed`.
    public var html: String?

    public init(status: Status, html: String?) {
        self.status = status
        self.html = html
    }

    enum CodingKeys: String, CodingKey {
        case status = "s"
        case html = "h"
    }
}

/// A state-based CRDT shard for reader-mode-extracted content, mirroring
/// `ContentShardDocument`/`BodyShardDocument`: each device writes only its own
/// `.nook/reader/<deviceID>.json`, and loads merge every shard with last-writer-
/// wins per article (by `HLC`). This keeps macOS and iOS conflict-free — the two
/// devices never write the same file, and concurrent extractions of the same
/// article converge deterministically (their content is equivalent anyway).
///
/// Deliberately separate from the library/state/body sync: it is additive and
/// never modifies the existing shards.
public struct ReaderContentShardDocument: Codable, Sendable, Equatable {
    public static let currentSchema = 1

    public var schema: Int
    public var deviceID: String
    public var clock: HLC
    public var entries: [Article.ID: LWWRegister<ReaderContentValue>]

    public init(
        deviceID: String,
        clock: HLC = .zero,
        entries: [Article.ID: LWWRegister<ReaderContentValue>] = [:]
    ) {
        schema = Self.currentSchema
        self.deviceID = deviceID
        self.clock = clock
        self.entries = entries
    }

    enum CodingKeys: String, CodingKey { case schema, deviceID, clock, entries }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decodeIfPresent(Int.self, forKey: .schema) ?? Self.currentSchema
        deviceID = try c.decode(String.self, forKey: .deviceID)
        clock = try c.decodeIfPresent(HLC.self, forKey: .clock) ?? .zero
        entries = try c.decodeIfPresent([Article.ID: LWWRegister<ReaderContentValue>].self, forKey: .entries) ?? [:]
    }
}
