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

public struct ReaderStorage {
    public static let bookmarkDefaultsKey = "syncFolderBookmark"
    public static let displayPathDefaultsKey = "syncFolderDisplayPath"

    private static let libraryFileName = "NookLibrary.json"
    private static let iconsDirectoryName = "Icons"
    private static let faviconTTL: TimeInterval = 24 * 60 * 60

    public var directoryURL: URL

    public init(directoryURL: URL) {
        self.directoryURL = directoryURL
    }

    public var libraryURL: URL {
        directoryURL.appending(path: Self.libraryFileName, directoryHint: .notDirectory)
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
        let data = try JSONEncoder.nook.encode(library)

        // Coordinate the write so iCloud picks it up promptly and two devices
        // writing don't produce conflict copies.
        var writeError: Error?
        var coordinatorError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: libraryURL, options: [.forReplacing], error: &coordinatorError) { url in
            do { try data.write(to: url, options: [.atomic]) } catch { writeError = error }
        }
        if let coordinatorError { throw coordinatorError }
        if let writeError { throw writeError }
    }

    /// Asks iCloud to download the latest library file if it isn't already
    /// local, so a freshly-launched or foregrounded app pulls another device's
    /// changes instead of waiting for iCloud to push them opportunistically.
    public func startDownloadingLibraryIfNeeded() {
        try? FileManager.default.startDownloadingUbiquitousItem(at: libraryURL)
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
}

private extension JSONDecoder {
    static var nook: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
