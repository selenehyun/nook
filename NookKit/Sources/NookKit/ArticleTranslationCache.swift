import CryptoKit
import Foundation

/// Device-local cache for fully validated article translations. It deliberately
/// lives in Application Support, never in Nook's sync folder.
actor ArticleTranslationCache {
    static let shared = ArticleTranslationCache()
    static let routerVersion = 1

    struct Value: Codable, Sendable {
        let sourceHash: String
        let language: String
        let translatedTitle: String
        let markdown: String
        let models: [GeminiTranslator.Model]
        let createdAt: Date
        var lastAccessedAt: Date
    }

    private let maximumEntries = 200
    private let maximumBytes: Int64 = 50 * 1_024 * 1_024
    private var memory: [String: Value] = [:]

    func value(for template: MarkdownTranslationTemplate, language: String) -> Value? {
        let key = cacheKey(template: template, language: language)
        if var value = memory[key], value.sourceHash == sourceHash(template.sourceIdentity) {
            value.lastAccessedAt = .now
            memory[key] = value
            return value
        }
        guard let url = fileURL(for: key),
              let data = try? Data(contentsOf: url),
              var value = try? JSONDecoder().decode(Value.self, from: data),
              value.sourceHash == sourceHash(template.sourceIdentity),
              value.language == language
        else { return nil }
        value.lastAccessedAt = .now
        memory[key] = value
        try? FileManager.default.setAttributes(
            [.modificationDate: Date.now],
            ofItemAtPath: url.path
        )
        return value
    }

    func store(
        title: String,
        markdown: String,
        models: [GeminiTranslator.Model],
        template: MarkdownTranslationTemplate,
        language: String
    ) {
        let key = cacheKey(template: template, language: language)
        let value = Value(
            sourceHash: sourceHash(template.sourceIdentity),
            language: language,
            translatedTitle: title,
            markdown: markdown,
            models: Array(Set(models.map(\.rawValue))).compactMap(GeminiTranslator.Model.init(rawValue:)),
            createdAt: .now,
            lastAccessedAt: .now
        )
        memory[key] = value
        guard let url = fileURL(for: key, createDirectory: true),
              let data = try? JSONEncoder().encode(value)
        else { return }
        do {
            try data.write(to: url, options: .atomic)
            prune()
        } catch {
            // Cache failure must never affect the visible translation.
        }
    }

    func clear() {
        memory.removeAll()
        guard let directory = Self.directoryURL() else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    private func cacheKey(template: MarkdownTranslationTemplate, language: String) -> String {
        sourceHash(
            "\(Self.routerVersion)|\(MarkdownTranslationTemplate.formatVersion)|gemini|\(language)|\(template.sourceIdentity)"
        )
    }

    private func sourceHash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func fileURL(for key: String, createDirectory: Bool = false) -> URL? {
        guard let directory = Self.directoryURL() else { return nil }
        if createDirectory {
            try? FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        return directory.appendingPathComponent(key).appendingPathExtension("json")
    }

    private static func directoryURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Nook", isDirectory: true)
            .appendingPathComponent("ArticleTranslations", isDirectory: true)
    }

    private func prune() {
        guard let directory = Self.directoryURL(),
              let urls = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
              )
        else { return }

        let entries = urls.compactMap { url -> (URL, Date, Int64)? in
            guard let values = try? url.resourceValues(
                forKeys: [.contentModificationDateKey, .fileSizeKey]
            ) else { return nil }
            return (url, values.contentModificationDate ?? .distantPast, Int64(values.fileSize ?? 0))
        }
        .sorted { $0.1 > $1.1 }

        var bytes: Int64 = 0
        for (index, entry) in entries.enumerated() {
            bytes += entry.2
            if index >= maximumEntries || bytes > maximumBytes {
                try? FileManager.default.removeItem(at: entry.0)
            }
        }
    }
}
