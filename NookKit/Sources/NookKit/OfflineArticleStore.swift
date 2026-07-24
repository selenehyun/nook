import CryptoKit
import Foundation

/// Metadata for one article saved for offline reading. The extracted HTML lives
/// in a sibling file (keyed by the article id's hash); this record is what the
/// managed list and the size/expiry logic read.
public struct OfflineArticleInfo: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var title: String
    public var url: URL
    public var feedTitle: String
    public var savedAt: Date
    public var byteCount: Int

    public init(id: String, title: String, url: URL, feedTitle: String, savedAt: Date, byteCount: Int) {
        self.id = id
        self.title = title
        self.url = url
        self.feedTitle = feedTitle
        self.savedAt = savedAt
        self.byteCount = byteCount
    }
}

/// Device-local store of articles the user saved for offline reading. Downloads
/// are inherently per-device (you keep them on the device you'll read offline),
/// so this is NOT synced — it lives in Application Support, outside the sync
/// folder, like the title-translation cache.
///
/// Layout: `Application Support/Nook/Offline/index.json` (small metadata index,
/// loaded once) plus one `<sha256(id)>.html` per saved article (read on demand,
/// so opening a saved article is a single fast file read — instant and offline).
///
/// `@MainActor` so the observable `savedIDs`/index the UI reads stay on the main
/// actor; the (larger) HTML file writes run off-main.
@MainActor
@Observable
public final class OfflineArticleStore {
    public static let shared = OfflineArticleStore()

    /// Metadata index, keyed by article id. The source of truth for what's saved.
    public private(set) var index: [Article.ID: OfflineArticleInfo] = [:]

    /// HTML held in memory only until its file write lands, so an article opened
    /// immediately after saving still serves instantly (the detached file write
    /// may not have completed yet). Dropped once the file is on disk.
    private var pendingContent: [Article.ID: String] = [:]

    private var loaded = false
    /// Hard cap so a runaway "download all" can't fill the disk. Oldest saved
    /// entries are dropped first when exceeded.
    private let maxEntries = 2000

    public init() {}

    // MARK: - Loading

    /// Loads the index once (small JSON). Cheap enough to call eagerly at launch.
    public func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let url = Self.indexURL(),
              let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode([OfflineArticleInfo].self, from: data) else { return }
        index = Dictionary(stored.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    // MARK: - Queries

    public var savedIDs: Set<Article.ID> { loadIfNeeded(); return Set(index.keys) }

    public func isSaved(_ id: Article.ID) -> Bool { loadIfNeeded(); return index[id] != nil }

    public func info(for id: Article.ID) -> OfflineArticleInfo? { loadIfNeeded(); return index[id] }

    /// Saved articles, newest first — for the managed list.
    public func infos() -> [OfflineArticleInfo] {
        loadIfNeeded()
        return index.values.sorted { $0.savedAt > $1.savedAt }
    }

    public var totalCount: Int { loadIfNeeded(); return index.count }
    public var totalBytes: Int { loadIfNeeded(); return index.values.reduce(0) { $0 + $1.byteCount } }

    /// The saved HTML for an article, read synchronously (one small file). Returns
    /// nil if not saved or the file is missing. This is the instant, network-free
    /// path that lets a saved article open offline.
    public func content(for id: Article.ID) -> String? {
        loadIfNeeded()
        guard index[id] != nil else { return nil }
        if let pending = pendingContent[id] { return pending }
        guard let url = Self.contentURL(for: id) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - Mutations

    /// Saves (or replaces) an article's offline copy. Updates the in-memory index
    /// immediately (so the icon/list react at once) and writes the HTML file and
    /// index off the main actor.
    public func save(id: Article.ID, title: String, url: URL, feedTitle: String, html: String, now: Date) {
        loadIfNeeded()
        let bytes = html.utf8.count
        index[id] = OfflineArticleInfo(id: id, title: title, url: url, feedTitle: feedTitle, savedAt: now, byteCount: bytes)
        pendingContent[id] = html
        evictIfNeeded()
        if let fileURL = Self.contentURL(for: id) {
            Task.detached(priority: .utility) { [weak self] in
                try? html.data(using: .utf8)?.write(to: fileURL, options: .atomic)
                // File is on disk now; drop the in-memory copy.
                await self?.clearPending(id)
            }
        }
        persistIndex()
    }

    private func clearPending(_ id: Article.ID) {
        pendingContent[id] = nil
    }

    public func remove(_ id: Article.ID) {
        guard index.removeValue(forKey: id) != nil else { return }
        pendingContent[id] = nil
        if let fileURL = Self.contentURL(for: id) {
            Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: fileURL) }
        }
        persistIndex()
    }

    /// Deletes every offline article (index + all HTML files).
    public func removeAll() {
        index.removeAll()
        pendingContent.removeAll()
        if let dir = Self.directoryURL() {
            Task.detached(priority: .utility) {
                let fm = FileManager.default
                if let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                    for file in files where file.pathExtension == "html" { try? fm.removeItem(at: file) }
                }
            }
        }
        persistIndex()
    }

    /// Removes entries saved longer ago than `maxAge`. Returns the purged ids.
    @discardableResult
    public func purge(olderThan maxAge: TimeInterval, now: Date) -> [Article.ID] {
        loadIfNeeded()
        let cutoff = now.addingTimeInterval(-maxAge)
        let expired = index.values.filter { $0.savedAt < cutoff }.map(\.id)
        for id in expired { remove(id) }
        return expired
    }

    private func evictIfNeeded() {
        guard index.count > maxEntries else { return }
        let overflow = index.values.sorted { $0.savedAt < $1.savedAt }.prefix(index.count - maxEntries)
        for info in overflow { remove(info.id) }
    }

    // MARK: - Persistence

    private func persistIndex() {
        let snapshot = Array(index.values)
        Task.detached(priority: .utility) {
            guard let url = Self.indexURL(), let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    private nonisolated static func directoryURL() -> URL? {
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ) else { return nil }
        let dir = base.appendingPathComponent("Nook/Offline", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private nonisolated static func indexURL() -> URL? {
        directoryURL()?.appendingPathComponent("index.json")
    }

    private nonisolated static func contentURL(for id: Article.ID) -> URL? {
        let digest = SHA256.hash(data: Data(id.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return directoryURL()?.appendingPathComponent("\(name).html")
    }
}
