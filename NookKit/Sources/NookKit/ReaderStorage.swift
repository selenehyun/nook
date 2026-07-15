import Foundation

public enum ReaderStorageError: LocalizedError {
    case noDirectorySelected
    case staleBookmark

    public var errorDescription: String? {
        switch self {
        case .noDirectorySelected:
            String(localized: "Choose an iCloud Drive folder before adding feeds.", bundle: Bundle.module)
        case .staleBookmark:
            String(localized: "The saved sync folder permission expired. Choose the folder again.", bundle: Bundle.module)
        }
    }
}

public struct ReaderStorage: Sendable {
    public static let bookmarkDefaultsKey = "syncFolderBookmark"
    public static let displayPathDefaultsKey = "syncFolderDisplayPath"

    private static let libraryFileName = "NookLibrary.json"
    // Article bodies (contentHTML / paragraphs) live apart from the list-light
    // baseline so launch only decodes the small file; this holds the bodies,
    // loaded lazily and capped to the most recent articles.
    private static let contentFileName = "NookContent.json"
    private static let iconsDirectoryName = "Icons"
    // Per-device user-state shards live in a hidden folder so they don't clutter
    // the user's vault, next to the `NookLibrary.json` content baseline.
    private static let stateDirectoryName = ".nook/state"
    private static let contentDirectoryName = ".nook/content"
    private static let bodiesDirectoryName = ".nook/bodies"
    private static let shardFileExtension = "json"
    private static let faviconTTL: TimeInterval = 24 * 60 * 60

    public var directoryURL: URL

    public init(directoryURL: URL) {
        self.directoryURL = directoryURL
    }

    public var libraryURL: URL {
        directoryURL.appending(path: Self.libraryFileName, directoryHint: .notDirectory)
    }

    /// The content sidecar holding article bodies keyed by article id.
    public var contentURL: URL {
        directoryURL.appending(path: Self.contentFileName, directoryHint: .notDirectory)
    }

    /// Folder holding every device's state shard (`<deviceID>.json`).
    public var stateDirectoryURL: URL {
        directoryURL.appending(path: Self.stateDirectoryName, directoryHint: .isDirectory)
    }

    public var contentDirectoryURL: URL {
        directoryURL.appending(path: Self.contentDirectoryName, directoryHint: .isDirectory)
    }

    public var bodiesDirectoryURL: URL {
        directoryURL.appending(path: Self.bodiesDirectoryName, directoryHint: .isDirectory)
    }

    private func shardURL(deviceID: String) -> URL {
        stateDirectoryURL.appending(path: "\(deviceID).\(Self.shardFileExtension)", directoryHint: .notDirectory)
    }

    private func contentShardURL(deviceID: String) -> URL {
        contentDirectoryURL.appending(path: "\(deviceID).\(Self.shardFileExtension)", directoryHint: .notDirectory)
    }

    private func bodyShardURL(deviceID: String) -> URL {
        bodiesDirectoryURL.appending(path: "\(deviceID).\(Self.shardFileExtension)", directoryHint: .notDirectory)
    }

    private var iconsDirectoryURL: URL {
        directoryURL.appending(path: Self.iconsDirectoryName, directoryHint: .isDirectory)
    }

    private func faviconURL(forKey key: String) -> URL {
        iconsDirectoryURL.appending(path: "\(key).png", directoryHint: .notDirectory)
    }

    /// Marker file recording that a favicon fetch failed, so we don't retry a
    /// dead/slow host on every launch.
    private func faviconMissURL(forKey key: String) -> URL {
        iconsDirectoryURL.appending(path: "\(key).miss", directoryHint: .notDirectory)
    }

    public func cachedFaviconData(forKey key: String) -> Data? {
        try? Data(contentsOf: faviconURL(forKey: key))
    }

    private func modificationDate(of url: URL) -> Date? {
        let path = url.path(percentEncoded: false)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else {
            return nil
        }
        return attributes[.modificationDate] as? Date
    }

    /// True only when neither a cached favicon nor a recent failure marker
    /// exists within the 1-day TTL. A recorded miss suppresses retries so an
    /// unreachable host isn't hammered on every launch.
    public func faviconNeedsRefresh(forKey key: String) -> Bool {
        let newest = [faviconURL(forKey: key), faviconMissURL(forKey: key)]
            .compactMap(modificationDate(of:))
            .max()
        guard let newest else { return true }
        return Date.now.timeIntervalSince(newest) >= Self.faviconTTL
    }

    public func writeFaviconData(_ data: Data, forKey key: String) throws {
        try FileManager.default.createDirectory(at: iconsDirectoryURL, withIntermediateDirectories: true)
        try data.write(to: faviconURL(forKey: key), options: [.atomic])
        // A fresh success clears any stale failure marker.
        try? FileManager.default.removeItem(at: faviconMissURL(forKey: key))
    }

    /// Records that a favicon fetch failed so it is not retried until the TTL
    /// elapses.
    public func recordFaviconMiss(forKey key: String) {
        try? FileManager.default.createDirectory(at: iconsDirectoryURL, withIntermediateDirectories: true)
        try? Data().write(to: faviconMissURL(forKey: key), options: [.atomic])
    }

    /// The library file's last-modified date, or nil if it doesn't exist. Used
    /// to detect when another device (via iCloud) has written a newer version.
    public var libraryModificationDate: Date? {
        modificationDate(of: libraryURL)
    }

    /// The state directory's last-modified date, which bumps whenever a shard
    /// file is added or replaced (including a peer's shard arriving via iCloud).
    /// Used to cheaply suppress reacting to this device's own shard writes.
    public var stateDirectoryModificationDate: Date? {
        modificationDate(of: stateDirectoryURL)
    }

    public var contentDirectoryModificationDate: Date? { modificationDate(of: contentDirectoryURL) }
    public var bodiesDirectoryModificationDate: Date? { modificationDate(of: bodiesDirectoryURL) }

    public struct LegacyCandidate: Sendable {
        public var identity: String
        public var modificationDate: Date
        public var data: Data
        public var library: ReaderLibrary
    }

    /// Reads the current v1 baseline and every unresolved conflict version. v2
    /// treats these as add-only input and never resolves, removes, or rewrites
    /// them because an older Nook may still be using the files.
    public func loadLegacyCandidates() -> [LegacyCandidate] {
        var urls: [(String, URL, Date)] = []
        if FileManager.default.fileExists(atPath: libraryURL.path(percentEncoded: false)) {
            urls.append(("current", libraryURL, modificationDate(of: libraryURL) ?? .distantPast))
        }
        for version in NSFileVersion.unresolvedConflictVersionsOfItem(at: libraryURL) ?? [] {
            urls.append((String(describing: version.persistentIdentifier), version.url, version.modificationDate ?? .distantPast))
        }
        return urls.compactMap { identity, url, date in
            guard let data = try? coordinatedRead(url),
                  let library = try? JSONDecoder.nook.decode(ReaderLibrary.self, from: data) else { return nil }
            return LegacyCandidate(identity: identity, modificationDate: date, data: data, library: library)
        }
    }

    public func load() throws -> ReaderLibrary? {
        guard FileManager.default.fileExists(atPath: libraryURL.path(percentEncoded: false)) else {
            return nil
        }

        // Coordinate the read so it waits for any in-flight iCloud write and
        // sees a consistent file rather than a half-written one.
        var readData: Data?
        var readError: Error?
        var coordinatorError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: libraryURL, options: [.withoutChanges], error: &coordinatorError) { url in
            do { readData = try Data(contentsOf: url) } catch { readError = error }
        }
        if let coordinatorError { throw coordinatorError }
        if let readError { throw readError }
        guard let data = readData else { return nil }
        return try JSONDecoder.nook.decode(ReaderLibrary.self, from: data)
    }

    public func save(_ library: ReaderLibrary) throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        // Coordinate the write so iCloud picks it up promptly and two devices
        // writing don't produce conflict copies. The write is a read-modify-write
        // *union*: within the same coordination we fold this device's snapshot
        // over whatever is currently on disk, so a feed/article another device
        // added — already downloaded here but not yet merged into memory — is
        // never dropped by a plain overwrite. The baseline is content-only and
        // grow-only; removals are expressed as per-device tombstones (in the
        // shards) and applied at materialize, never by absence from a save.
        var writeError: Error?
        var coordinatorError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: libraryURL, options: [.forReplacing], error: &coordinatorError) { url in
            do {
                let existing = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder.nook.decode(ReaderLibrary.self, from: $0) }
                let merged = Self.additivelyMerged(incoming: library, onDisk: existing)
                let data = try JSONEncoder.nookStrippingContent.encode(merged)
                try data.write(to: url, options: [.atomic])
            } catch { writeError = error }
        }
        if let coordinatorError { throw coordinatorError }
        if let writeError { throw writeError }
    }

    /// Folds `incoming` (this device's in-memory snapshot) over the current
    /// on-disk baseline, keeping every feed/article that exists on disk but not
    /// in the snapshot. Duplicate ids resolve to the incoming (fresher) copy.
    static func additivelyMerged(incoming: ReaderLibrary, onDisk: ReaderLibrary?) -> ReaderLibrary {
        guard let onDisk else { return incoming }
        var feedsByID = Dictionary(onDisk.feeds.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for feed in incoming.feeds { feedsByID[feed.id] = feed }
        var articlesByID = Dictionary(onDisk.articles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for article in incoming.articles { articlesByID[article.id] = article }
        var folders = Set(onDisk.folders)
        folders.formUnion(incoming.folders)
        let latestRefresh = [onDisk.lastRefreshedAt, incoming.lastRefreshedAt].compactMap { $0 }.max()
        return ReaderLibrary(
            feeds: Array(feedsByID.values),
            articles: Array(articlesByID.values),
            lastRefreshedAt: latestRefresh,
            folders: Array(folders)
        )
    }

    /// Asks iCloud to download the latest library file if it isn't already
    /// local, so a freshly-launched or foregrounded app pulls another device's
    /// changes instead of waiting for iCloud to push them opportunistically.
    public func startDownloadingLibraryIfNeeded() {
        try? FileManager.default.startDownloadingUbiquitousItem(at: libraryURL)
        try? FileManager.default.startDownloadingUbiquitousItem(at: contentURL)
    }

    // MARK: - Content sidecar (article bodies)

    /// Loads the article-body sidecar (id → body), or an empty map when absent.
    /// Kept off the launch-critical path: the list renders from the light
    /// baseline, and bodies hydrate in from here afterward.
    public func loadContent() -> [Article.ID: ArticleBody] {
        guard FileManager.default.fileExists(atPath: contentURL.path(percentEncoded: false)),
              let data = try? coordinatedRead(contentURL),
              let bodies = try? JSONDecoder.nook.decode([Article.ID: ArticleBody].self, from: data) else {
            return [:]
        }
        return bodies
    }

    /// Writes the content sidecar as a coordinated read-modify-write union (so a
    /// peer's freshly-added body is never dropped), then caps it to `retain` —
    /// the ids worth keeping bodies for (the most recent articles). Bodies are
    /// regenerable, so dropping an old one just means a refetch when reopened.
    public func saveContent(_ bodies: [Article.ID: ArticleBody], retain: Set<Article.ID>) throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        var writeError: Error?
        var coordinatorError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: contentURL, options: [.forReplacing], error: &coordinatorError) { url in
            do {
                var merged = (try? Data(contentsOf: url))
                    .flatMap { try? JSONDecoder.nook.decode([Article.ID: ArticleBody].self, from: $0) } ?? [:]
                merged.merge(bodies) { _, new in new }
                merged = merged.filter { retain.contains($0.key) }
                let data = try JSONEncoder.nook.encode(merged)
                try data.write(to: url, options: [.atomic])
            } catch { writeError = error }
        }
        if let coordinatorError { throw coordinatorError }
        if let writeError { throw writeError }
    }

    // MARK: - Per-device state shards

    /// Reads a single file with the same read coordination as `load()` so it
    /// waits for any in-flight iCloud write and sees a consistent file.
    private func coordinatedRead(_ url: URL) throws -> Data? {
        var readData: Data?
        var readError: Error?
        var coordinatorError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [.withoutChanges], error: &coordinatorError) { url in
            do { readData = try Data(contentsOf: url) } catch { readError = error }
        }
        if let coordinatorError { throw coordinatorError }
        if let readError { throw readError }
        return readData
    }

    /// Loads every device's state shard from `.nook/state`. A shard that is
    /// missing, still downloading, or unreadable is skipped rather than failing
    /// the whole load — merge is resilient to a temporarily absent peer.
    public func loadShards() throws -> [DeviceStateDocument] {
        let stateDir = stateDirectoryURL
        guard FileManager.default.fileExists(atPath: stateDir.path(percentEncoded: false)) else {
            return []
        }
        let entries = try FileManager.default.contentsOfDirectory(
            at: stateDir,
            includingPropertiesForKeys: nil
        )
        var shards: [DeviceStateDocument] = []
        for url in entries where url.pathExtension == Self.shardFileExtension {
            guard let data = try? coordinatedRead(url),
                  let shard = try? JSONDecoder.nook.decode(DeviceStateDocument.self, from: data) else {
                continue
            }
            shards.append(shard)
        }
        return shards
    }

    /// Loads only this device's shard, for restoring its clock and registers on
    /// launch without decoding every peer.
    public func loadOwnShard(deviceID: String) -> DeviceStateDocument? {
        let url = shardURL(deviceID: deviceID)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)),
              let data = try? coordinatedRead(url) else {
            return nil
        }
        return try? JSONDecoder.nook.decode(DeviceStateDocument.self, from: data)
    }

    /// Writes this device's shard. Each device only ever writes its own file, so
    /// two devices can never write the same file — the write-conflict class that
    /// caused lost updates simply cannot occur here.
    public func saveShard(_ shard: DeviceStateDocument) throws {
        try FileManager.default.createDirectory(at: stateDirectoryURL, withIntermediateDirectories: true)
        let data = try JSONEncoder.nook.encode(shard)
        let url = shardURL(deviceID: shard.deviceID)

        var writeError: Error?
        var coordinatorError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: [.forReplacing], error: &coordinatorError) { url in
            do { try data.write(to: url, options: [.atomic]) } catch { writeError = error }
        }
        if let coordinatorError { throw coordinatorError }
        if let writeError { throw writeError }
    }

    public func loadContentShards() -> [ContentShardDocument] {
        loadDocuments(in: contentDirectoryURL, as: ContentShardDocument.self)
    }

    public func loadOwnContentShard(deviceID: String) -> ContentShardDocument? {
        loadDocument(at: contentShardURL(deviceID: deviceID), as: ContentShardDocument.self)
    }

    public func saveContentShard(_ shard: ContentShardDocument) throws {
        try saveDocument(shard, at: contentShardURL(deviceID: shard.deviceID), directory: contentDirectoryURL)
    }

    public func loadBodyShards() -> [BodyShardDocument] {
        loadDocuments(in: bodiesDirectoryURL, as: BodyShardDocument.self)
    }

    public func saveBodyShard(_ shard: BodyShardDocument) throws {
        try saveDocument(shard, at: bodyShardURL(deviceID: shard.deviceID), directory: bodiesDirectoryURL)
    }

    private func loadDocuments<T: Decodable>(in directory: URL, as type: T.Type) -> [T] {
        guard let entries = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        return entries.compactMap { url in
            guard url.pathExtension == Self.shardFileExtension else { return nil }
            return loadDocument(at: url, as: type)
        }
    }

    private func loadDocument<T: Decodable>(at url: URL, as type: T.Type) -> T? {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)),
              let data = try? coordinatedRead(url) else { return nil }
        return try? JSONDecoder.nook.decode(type, from: data)
    }

    private func saveDocument<T: Encodable>(_ document: T, at url: URL, directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder.nook.encode(document)
        var writeError: Error?
        var coordinatorError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: [.forReplacing], error: &coordinatorError) { url in
            do { try data.write(to: url, options: [.atomic]) } catch { writeError = error }
        }
        if let coordinatorError { throw coordinatorError }
        if let writeError { throw writeError }
    }

    /// Asks iCloud to download every peer's shard so a freshly launched or
    /// foregrounded app merges the latest state instead of waiting for a push.
    public func startDownloadingStateIfNeeded() {
        let stateDir = stateDirectoryURL
        try? FileManager.default.startDownloadingUbiquitousItem(at: stateDir)
        guard let entries = try? FileManager.default.contentsOfDirectory(at: stateDir, includingPropertiesForKeys: nil) else {
            return
        }
        for url in entries {
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        }
        startDownloadingDocuments(in: contentDirectoryURL)
        startDownloadingDocuments(in: bodiesDirectoryURL)
    }

    private func startDownloadingDocuments(in directory: URL) {
        try? FileManager.default.startDownloadingUbiquitousItem(at: directory)
        guard let entries = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for url in entries { try? FileManager.default.startDownloadingUbiquitousItem(at: url) }
    }

    // Security-scoped bookmarks: macOS requires the `.withSecurityScope`
    // option; on iOS that option doesn't exist (document-picker URLs are
    // already security-scoped), so the bookmark is created/resolved plain.
    #if os(macOS)
    private static let bookmarkCreationOptions: URL.BookmarkCreationOptions = [.withSecurityScope]
    private static let bookmarkResolutionOptions: URL.BookmarkResolutionOptions = [.withSecurityScope]
    #else
    private static let bookmarkCreationOptions: URL.BookmarkCreationOptions = []
    private static let bookmarkResolutionOptions: URL.BookmarkResolutionOptions = []
    #endif

    public static func saveBookmark(for directoryURL: URL) throws {
        let bookmarkData = try directoryURL.bookmarkData(
            options: bookmarkCreationOptions,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        UserDefaults.standard.set(bookmarkData, forKey: bookmarkDefaultsKey)
        UserDefaults.standard.set(directoryURL.path(percentEncoded: false), forKey: displayPathDefaultsKey)
    }

    public static func resolveBookmarkedDirectory() throws -> URL? {
        guard let bookmarkData = UserDefaults.standard.data(forKey: bookmarkDefaultsKey) else {
            return nil
        }

        var isStale = false
        let directoryURL = try URL(
            resolvingBookmarkData: bookmarkData,
            options: bookmarkResolutionOptions,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )

        if isStale {
            throw ReaderStorageError.staleBookmark
        }

        return directoryURL
    }
}

private extension JSONEncoder {
    static var nook: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    /// The baseline encoder, with `Article` bodies stripped so `NookLibrary.json`
    /// stays list-light (bodies persist in the content sidecar instead).
    static var nookStrippingContent: JSONEncoder {
        let encoder = nook
        encoder.userInfo[.stripArticleContent] = true
        return encoder
    }
}

private extension JSONDecoder {
    static var nook: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
