import Foundation

enum ReaderStorageError: LocalizedError {
    case noDirectorySelected
    case staleBookmark

    var errorDescription: String? {
        switch self {
        case .noDirectorySelected:
            String(localized: "Choose an iCloud Drive folder before adding feeds.")
        case .staleBookmark:
            String(localized: "The saved sync folder permission expired. Choose the folder again.")
        }
    }
}

struct ReaderStorage {
    static let bookmarkDefaultsKey = "syncFolderBookmark"
    static let displayPathDefaultsKey = "syncFolderDisplayPath"

    private static let libraryFileName = "NookLibrary.json"
    private static let iconsDirectoryName = "Icons"
    private static let faviconTTL: TimeInterval = 24 * 60 * 60

    var directoryURL: URL

    var libraryURL: URL {
        directoryURL.appending(path: Self.libraryFileName, directoryHint: .notDirectory)
    }

    private var iconsDirectoryURL: URL {
        directoryURL.appending(path: Self.iconsDirectoryName, directoryHint: .isDirectory)
    }

    private func faviconURL(forKey key: String) -> URL {
        iconsDirectoryURL.appending(path: "\(key).png", directoryHint: .notDirectory)
    }

    func cachedFaviconData(forKey key: String) -> Data? {
        try? Data(contentsOf: faviconURL(forKey: key))
    }

    /// True when there is no cached favicon or the cached one is older than the
    /// 1-day TTL and should be re-fetched.
    func faviconNeedsRefresh(forKey key: String) -> Bool {
        let path = faviconURL(forKey: key).path(percentEncoded: false)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let modified = attributes[.modificationDate] as? Date else {
            return true
        }
        return Date.now.timeIntervalSince(modified) >= Self.faviconTTL
    }

    func writeFaviconData(_ data: Data, forKey key: String) throws {
        try FileManager.default.createDirectory(at: iconsDirectoryURL, withIntermediateDirectories: true)
        try data.write(to: faviconURL(forKey: key), options: [.atomic])
    }

    func load() throws -> ReaderLibrary? {
        guard FileManager.default.fileExists(atPath: libraryURL.path(percentEncoded: false)) else {
            return nil
        }

        let data = try Data(contentsOf: libraryURL)
        return try JSONDecoder.nook.decode(ReaderLibrary.self, from: data)
    }

    func save(_ library: ReaderLibrary) throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let data = try JSONEncoder.nook.encode(library)
        try data.write(to: libraryURL, options: [.atomic])
    }

    static func saveBookmark(for directoryURL: URL) throws {
        let bookmarkData = try directoryURL.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        UserDefaults.standard.set(bookmarkData, forKey: bookmarkDefaultsKey)
        UserDefaults.standard.set(directoryURL.path(percentEncoded: false), forKey: displayPathDefaultsKey)
    }

    static func resolveBookmarkedDirectory() throws -> URL? {
        guard let bookmarkData = UserDefaults.standard.data(forKey: bookmarkDefaultsKey) else {
            return nil
        }

        var isStale = false
        let directoryURL = try URL(
            resolvingBookmarkData: bookmarkData,
            options: [.withSecurityScope],
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
