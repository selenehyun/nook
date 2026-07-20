import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Builds the body text for a "new articles" notification.
///
/// - A single new article shows just its title (no "N new articles" line — the
///   count is redundant with the badge and reads oddly next to the title).
/// - Several new articles are condensed by Apple Intelligence's on-device model
///   into one short, headline-style digest of the distinct topics — never a
///   conversational sentence. When Apple Intelligence is unavailable (or slow),
///   it falls back to a short plain list of titles.
public enum NewArticleSummarizer {
    /// Whether Apple Intelligence can produce a digest right now.
    public static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26, macOS 26, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
    }

    /// The notification body for `count` new articles whose (possibly sampled)
    /// titles are `titles`. Always returns something printable; never throws.
    public static func notificationBody(titles: [String], count: Int) async -> String {
        let titles = titles.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        // One article: just its title. No count, no digest.
        if count <= 1 {
            return titles.first ?? fallbackList(titles, count: count)
        }

        // Several: try an on-device digest, but never let it hang the background
        // refresh — fall back to a short title list on timeout or error.
        if titles.count >= 2, isAvailable {
            if let digest = await withTimeout(seconds: 8, operation: { await llmDigest(titles) }),
               !digest.isEmpty {
                return digest
            }
        }
        return fallbackList(titles, count: count)
    }

    /// A short plain-text fallback: the first few titles, one per line.
    private static func fallbackList(_ titles: [String], count: Int) -> String {
        guard !titles.isEmpty else { return "" }
        return titles.prefix(3).joined(separator: "\n")
    }

    // MARK: - Apple Intelligence

    #if canImport(FoundationModels)
    @available(iOS 26, macOS 26, *)
    @Generable
    fileprivate struct HeadlineDigest {
        @Guide(description: "A single short line naming only the distinct topics from the headlines, separated by ' · ' (space, middle dot, space). NOT full sentences. No verbs of reporting (no 'announces', 'reports', 'launches', '발표', '공개', '전했다'). No first or second person, no greeting, no explanation, no quotation marks, no label, no preamble, no trailing period. Written in the same language as the majority of the headlines. At most 12 words; merge near-duplicate topics.")
        var digest: String
    }
    #endif

    /// Runs the on-device model to condense the titles. Returns nil on any error.
    private static func llmDigest(_ titles: [String]) async -> String? {
        #if canImport(FoundationModels)
        guard #available(iOS 26, macOS 26, *) else { return nil }
        let instructions = """
        You condense a list of news article headlines into ONE short line for a \
        phone notification. Output only that line — the distinct key topics, \
        separated by " · ".

        Hard rules:
        - Never write full sentences. Never use reporting verbs (announces, \
        reports, launches, unveils, says, 발표, 공개, 전했다, 밝혔다). List topics as \
        noun phrases, not clauses.
        - No conversational or explanatory tone. No first or second person, no \
        greeting, no closing. This is not a message to the reader.
        - No preamble, labels, quotation marks, or trailing punctuation.
        - Keep proper nouns. Merge near-duplicate headlines into one topic.
        - Write in the same language as the majority of the headlines.
        - At most 12 words total. Prefer fewer.
        """
        let bulleted = titles.prefix(12).map { "- \($0)" }.joined(separator: "\n")
        let prompt = """
        Headlines:
        \(bulleted)

        Condensed digest (topics only, separated by " · "):
        """
        do {
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(to: prompt, generating: HeadlineDigest.self)
            return response.content.digest.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }

    /// Races `operation` against a timeout so a slow model call can't blow the
    /// background refresh budget. Returns nil if the timeout wins.
    private static func withTimeout<T: Sendable>(
        seconds: Double,
        operation: @escaping @Sendable () async -> T?
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
