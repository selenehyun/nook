import CryptoKit
import Foundation
import SQLite3

public struct ReplicaSnapshot: Sendable {
    public var revision: UInt64
    public var library: ReaderLibrary
    public var bodies: [Article.ID: ArticleBody]
}

public enum ReplicaStoreError: Error { case sqlite(String) }

/// Durable local accumulator for state-based anti-entropy. The database is a
/// rebuildable cache; authoritative copies remain the per-device files in the
/// selected sync folder.
public final class ReplicaStore: @unchecked Sendable {
    private let databaseURL: URL
    private let deviceID: String
    private let lock = NSLock()

    public init(syncDirectory: URL, deviceID: String, databaseDirectory: URL? = nil) throws {
        self.deviceID = deviceID
        let root = try databaseDirectory ?? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ).appending(path: "Nook/Replicas", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let key = Self.digest(Data(syncDirectory.standardizedFileURL.path(percentEncoded: false).utf8)).prefix(20)
        databaseURL = root.appending(path: "replica-\(key).sqlite3", directoryHint: .notDirectory)
        try withDatabase { db in
            try exec(db, """
                PRAGMA journal_mode=WAL;
                PRAGMA synchronous=FULL;
                CREATE TABLE IF NOT EXISTS documents (name TEXT PRIMARY KEY, payload BLOB NOT NULL);
                CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS legacy_inputs (digest TEXT PRIMARY KEY, identity TEXT NOT NULL, ingested_at REAL NOT NULL);
                CREATE TABLE IF NOT EXISTS notification_receipts (
                    article_id TEXT PRIMARY KEY, first_seen_at REAL NOT NULL,
                    reserved_at REAL, delivered_at REAL
                );
            """)
        }
    }

    /// Merges every available v2 shard, then imports unseen legacy files as an
    /// add-only bridge. Missing/corrupt/stale files can never subtract state.
    public func reconcile(storage: ReaderStorage) throws -> ReplicaSnapshot {
        try lock.withLock {
            try withDatabase { db in
                try transaction(db) {
                    var document = try loadDocument(db) ?? storage.loadOwnContentShard(deviceID: deviceID)
                        ?? ContentShardDocument(deviceID: deviceID)
                    var changed = false
                    for peer in storage.loadContentShards() {
                        let merged = document.merged(with: peer, as: deviceID)
                        if merged.feeds != document.feeds || merged.articles != document.articles || merged.clock != document.clock {
                            document = merged
                            changed = true
                        }
                    }

                    let migrationComplete = try metadata(db, "legacy_migration_complete") == "1"
                    let candidates = storage.loadLegacyCandidates()
                    var unseen: [(ReaderStorage.LegacyCandidate, String)] = []
                    for candidate in candidates {
                        let digest = Self.digest(candidate.data)
                        if try !legacyWasIngested(db, digest) { unseen.append((candidate, digest)) }
                    }
                    if !unseen.isEmpty {
                        let winners = Self.legacyWinners(unseen.map(\.0))
                        var clock = document.clock
                        for feed in winners.feeds where document.feeds[feed.id] == nil {
                            clock = HLC.next(after: clock, node: deviceID)
                            document.feeds[feed.id] = LWWRegister(value: FeedContent(feed), hlc: clock)
                            changed = true
                        }
                        for article in winners.articles where document.articles[article.id] == nil {
                            clock = HLC.next(after: clock, node: deviceID)
                            document.articles[article.id] = LWWRegister(value: ArticleContent(article), hlc: clock)
                            if !migrationComplete {
                                try insertReceipt(db, articleID: article.id, delivered: true)
                            }
                            changed = true
                        }
                        document.clock = clock
                        for (candidate, digest) in unseen {
                            try recordLegacy(db, digest: digest, identity: candidate.identity)
                        }
                    }
                    if !migrationComplete { try setMetadata(db, "legacy_migration_complete", "1") }

                    let hadStoredDocument = try loadDocument(db) != nil
                    if changed || !hadStoredDocument {
                        document.generation &+= 1
                        try saveDocument(db, document)
                        try setMetadata(db, "outbox_dirty", "1")
                        try bumpRevision(db)
                    }
                    var bodies = Self.mergeBodies(storage.loadBodyShards())
                    if let localBodies = try loadBodyDocument(db)?.bodies {
                        bodies.merge(localBodies) { _, local in local }
                    }
                    return try snapshot(db, document: document, bodies: bodies)
                }
            }
        }
    }

    /// Records local RSS/editor content before it is exposed to asynchronous
    /// publishing. Registers only advance when the actual payload changed.
    public func recordLocal(_ library: ReaderLibrary, retainBodies: Set<Article.ID>) throws -> ReplicaSnapshot {
        try lock.withLock {
            try withDatabase { db in
                try transaction(db) {
                    var document = try loadDocument(db) ?? ContentShardDocument(deviceID: deviceID)
                    var bodyDocument = try loadBodyDocument(db) ?? BodyShardDocument(deviceID: deviceID)
                    var clock = document.clock
                    var changed = false
                    for feed in library.feeds {
                        let content = FeedContent(feed)
                        guard document.feeds[feed.id]?.value != content else { continue }
                        clock = HLC.next(after: clock, node: deviceID)
                        document.feeds[feed.id] = LWWRegister(value: content, hlc: clock)
                        changed = true
                    }
                    for article in library.articles {
                        let content = ArticleContent(article)
                        if document.articles[article.id]?.value != content {
                            clock = HLC.next(after: clock, node: deviceID)
                            document.articles[article.id] = LWWRegister(value: content, hlc: clock)
                            changed = true
                        }
                        if article.hasBody, retainBodies.contains(article.id) { bodyDocument.bodies[article.id] = article.body }
                    }
                    bodyDocument.bodies = bodyDocument.bodies.filter { retainBodies.contains($0.key) }
                    document.clock = clock
                    if changed {
                        document.generation &+= 1
                        try saveDocument(db, document)
                        try setMetadata(db, "outbox_dirty", "1")
                        try bumpRevision(db)
                    }
                    bodyDocument.generation &+= 1
                    try saveBodyDocument(db, bodyDocument)
                    try setMetadata(db, "body_outbox_dirty", "1")
                    return try snapshot(db, document: document, bodies: bodyDocument.bodies)
                }
            }
        }
    }

    /// Publishes only this device's files. A failed write leaves the outbox bit
    /// set, so the next launch/refresh retries it.
    public func publishIfNeeded(to storage: ReaderStorage) throws {
        try lock.withLock {
            try withDatabase { db in
                if try metadata(db, "outbox_dirty") == "1", let document = try loadDocument(db) {
                    try storage.saveContentShard(document)
                    try setMetadata(db, "outbox_dirty", "0")
                }
                if try metadata(db, "body_outbox_dirty") == "1", let body = try loadBodyDocument(db) {
                    try storage.saveBodyShard(body)
                    try setMetadata(db, "body_outbox_dirty", "0")
                }
            }
        }
    }

    /// Returns the deterministic legacy union until ReaderStore durably seeds
    /// its user-state shard. Kept separate from content migration so a failed
    /// shard write cannot falsely mark folders/read/starred state as migrated.
    public func pendingLegacyStateSeed(from storage: ReaderStorage) throws -> ReaderLibrary? {
        try lock.withLock {
            try withDatabase { db in
                guard try metadata(db, "legacy_state_seed_complete") != "1" else { return nil }
                let candidates = storage.loadLegacyCandidates()
                guard !candidates.isEmpty else { return nil }
                return Self.legacyWinners(candidates)
            }
        }
    }

    public func markLegacyStateSeedComplete() throws {
        try lock.withLock {
            try withDatabase { db in try setMetadata(db, "legacy_state_seed_complete", "1") }
        }
    }

    /// Atomically reserves every article that has never been considered for a
    /// notification on this device. Reservation, not successful presentation,
    /// is the at-most-once boundary.
    public func reserveNotifications(for articles: [Article]) throws -> [Article] {
        try lock.withLock {
            try withDatabase { db in
                try transaction(db) {
                    var reserved: [Article] = []
                    for article in articles {
                        guard try !receiptExists(db, article.id) else { continue }
                        try insertReceipt(db, articleID: article.id, delivered: false, reserve: true)
                        reserved.append(article)
                    }
                    return reserved
                }
            }
        }
    }

    public func markNotificationsDelivered(_ articleIDs: [Article.ID]) throws {
        try lock.withLock {
            try withDatabase { db in
                for id in articleIDs {
                    try run(db, "UPDATE notification_receipts SET delivered_at=? WHERE article_id=?", [.double(Date().timeIntervalSince1970), .text(id)])
                }
            }
        }
    }

    private static func legacyWinners(_ candidates: [ReaderStorage.LegacyCandidate]) -> ReaderLibrary {
        let ordered = candidates.sorted {
            if $0.modificationDate != $1.modificationDate { return $0.modificationDate < $1.modificationDate }
            return digest($0.data) < digest($1.data)
        }
        var feeds: [Feed.ID: Feed] = [:]
        var articles: [Article.ID: Article] = [:]
        for candidate in ordered {
            for feed in candidate.library.feeds { feeds[feed.id] = feed }
            for article in candidate.library.articles { articles[article.id] = article }
        }
        return ReaderLibrary(feeds: Array(feeds.values), articles: Array(articles.values), lastRefreshedAt: nil, folders: [])
    }

    private static func mergeBodies(_ shards: [BodyShardDocument]) -> [Article.ID: ArticleBody] {
        var result: [Article.ID: ArticleBody] = [:]
        for shard in shards.sorted(by: { ($0.generation, $0.deviceID) < ($1.generation, $1.deviceID) }) {
            result.merge(shard.bodies) { _, new in new }
        }
        return result
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func snapshot(_ db: OpaquePointer, document: ContentShardDocument, bodies: [Article.ID: ArticleBody]) throws -> ReplicaSnapshot {
        let revision = UInt64(try metadata(db, "revision") ?? "0") ?? 0
        return ReplicaSnapshot(revision: revision, library: document.materialize(bodies: bodies), bodies: bodies)
    }

    private func withDatabase<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        var db: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path(percentEncoded: false), &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let db else { throw ReplicaStoreError.sqlite("Unable to open replica database") }
        defer { sqlite3_close(db) }
        return try body(db)
    }

    private func transaction<T>(_ db: OpaquePointer, _ body: () throws -> T) throws -> T {
        try exec(db, "BEGIN IMMEDIATE")
        do { let value = try body(); try exec(db, "COMMIT"); return value }
        catch { try? exec(db, "ROLLBACK"); throw error }
    }

    private func exec(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw sqliteError(db) }
    }

    private enum SQLValue { case text(String), blob(Data), double(Double) }
    private func run(_ db: OpaquePointer, _ sql: String, _ values: [SQLValue] = []) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw sqliteError(db) }
        defer { sqlite3_finalize(statement) }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .text(let string): sqlite3_bind_text(statement, index, string, -1, SQLITE_TRANSIENT)
            case .blob(let data): _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(data.count), SQLITE_TRANSIENT) }
            case .double(let value): sqlite3_bind_double(statement, index, value)
            }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw sqliteError(db) }
    }

    private func scalar(_ db: OpaquePointer, _ sql: String, _ value: String? = nil) throws -> Data? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw sqliteError(db) }
        defer { sqlite3_finalize(statement) }
        if let value { sqlite3_bind_text(statement, 1, value, -1, SQLITE_TRANSIENT) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        let count = Int(sqlite3_column_bytes(statement, 0))
        guard let bytes = sqlite3_column_blob(statement, 0) else { return Data() }
        return Data(bytes: bytes, count: count)
    }

    private func loadDocument(_ db: OpaquePointer) throws -> ContentShardDocument? {
        guard let data = try scalar(db, "SELECT payload FROM documents WHERE name='content'") else { return nil }
        return try decoder.decode(ContentShardDocument.self, from: data)
    }
    private func saveDocument(_ db: OpaquePointer, _ document: ContentShardDocument) throws {
        try run(db, "INSERT OR REPLACE INTO documents(name,payload) VALUES('content',?)", [.blob(try encoder.encode(document))])
    }
    private func loadBodyDocument(_ db: OpaquePointer) throws -> BodyShardDocument? {
        guard let data = try scalar(db, "SELECT payload FROM documents WHERE name='body'") else { return nil }
        return try decoder.decode(BodyShardDocument.self, from: data)
    }
    private func saveBodyDocument(_ db: OpaquePointer, _ document: BodyShardDocument) throws {
        try run(db, "INSERT OR REPLACE INTO documents(name,payload) VALUES('body',?)", [.blob(try encoder.encode(document))])
    }
    private func metadata(_ db: OpaquePointer, _ key: String) throws -> String? {
        guard let data = try scalar(db, "SELECT value FROM metadata WHERE key=?", key) else { return nil }
        return String(data: data, encoding: .utf8)
    }
    private func setMetadata(_ db: OpaquePointer, _ key: String, _ value: String) throws {
        try run(db, "INSERT OR REPLACE INTO metadata(key,value) VALUES(?,?)", [.text(key), .text(value)])
    }
    private func bumpRevision(_ db: OpaquePointer) throws {
        let revision = (UInt64(try metadata(db, "revision") ?? "0") ?? 0) &+ 1
        try setMetadata(db, "revision", String(revision))
    }
    private func legacyWasIngested(_ db: OpaquePointer, _ digest: String) throws -> Bool {
        try scalar(db, "SELECT 1 FROM legacy_inputs WHERE digest=?", digest) != nil
    }
    private func recordLegacy(_ db: OpaquePointer, digest: String, identity: String) throws {
        try run(db, "INSERT OR IGNORE INTO legacy_inputs(digest,identity,ingested_at) VALUES(?,?,?)", [.text(digest), .text(identity), .double(Date().timeIntervalSince1970)])
    }
    private func receiptExists(_ db: OpaquePointer, _ id: String) throws -> Bool {
        try scalar(db, "SELECT 1 FROM notification_receipts WHERE article_id=?", id) != nil
    }
    private func insertReceipt(_ db: OpaquePointer, articleID: String, delivered: Bool, reserve: Bool = false) throws {
        let now = Date().timeIntervalSince1970
        try run(db, "INSERT OR IGNORE INTO notification_receipts(article_id,first_seen_at,reserved_at,delivered_at) VALUES(?,?,?,?)", [
            .text(articleID), .double(now), .double(reserve ? now : 0), .double(delivered ? now : 0)
        ])
    }
    private func sqliteError(_ db: OpaquePointer) -> ReplicaStoreError {
        ReplicaStoreError.sqlite(String(cString: sqlite3_errmsg(db)))
    }
    private var encoder: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }
    private var decoder: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
