import Foundation
import NaturalLanguage
import Observation

/// Translates the titles of on-screen article-list rows into the user's language,
/// on device with Apple Intelligence, and streams each result token by token.
///
/// Behavior (all opt-in, driven by `configure`):
/// - Only rows that stay visible for `dwell` seconds are translated, so a quick
///   scroll-past never starts work.
/// - A row that scrolls off screen before it finishes is dropped from the queue
///   / cancelled, so effort follows the viewport.
/// - Titles already in the target language are left untranslated (the row shows
///   the original only).
/// - Results are cached (per target language), so re-seeing a title is instant
///   and never re-translated. Everything is on device, so there is no network
///   cost; the cache just avoids recompute.
///
/// `@MainActor` so observable state updates (streaming) and SwiftUI reads stay on
/// the main actor. A single shared instance keeps the cache across list rebuilds.
@MainActor
@Observable
public final class ListTitleTranslator {
    public static let shared = ListTitleTranslator()

    /// The visible state of a row's title translation.
    public enum TitleState: Equatable, Sendable {
        /// Streaming in — the latest cumulative snapshot.
        case translating(String)
        /// Final translated title.
        case translated(String)
    }

    /// How long a row must stay on screen before its title is translated.
    public var dwell: TimeInterval = 1.5
    /// How many titles translate at once (Apple Intelligence is serialized enough
    /// that a small cap keeps it responsive).
    private let maxConcurrent = 2

    private var enabled = false
    private var targetLanguageName = ""
    private var targetLanguageCode = ""

    /// Per-article visible translation state (absent = show the original only).
    public private(set) var states: [Article.ID: TitleState] = [:]

    // In-memory, device-local caches (never synced). Keyed by target language so a
    // language switch re-translates rather than showing a stale language.
    private var cache: [String: String] = [:]
    private var sameLanguage: Set<String> = []

    private var dwellTasks: [Article.ID: Task<Void, Never>] = [:]
    private var activeTasks: [Article.ID: Task<Void, Never>] = [:]
    private var pending: [(id: Article.ID, title: String)] = []

    public init() {}

    /// Sets the feature on/off and the target language. Turning it off (or the
    /// app being unavailable) cancels everything in flight and clears live state,
    /// but keeps the caches.
    public func configure(enabled: Bool, targetLanguageName: String, targetLanguageCode: String) {
        let languageChanged = targetLanguageCode != self.targetLanguageCode
        self.enabled = enabled && NaturalTranslator.isAvailable
        self.targetLanguageName = targetLanguageName
        self.targetLanguageCode = targetLanguageCode
        if !self.enabled || languageChanged {
            cancelAll()
        }
    }

    public func state(for id: Article.ID) -> TitleState? { states[id] }

    /// A row scrolled into view. After the dwell (if still requested), translate
    /// its title — unless it's already cached, already the target language, or in
    /// progress.
    public func rowAppeared(id: Article.ID, title: String) {
        guard enabled, !title.isEmpty else { return }
        let key = cacheKey(for: title)
        if sameLanguage.contains(key) { return }
        if let cached = cache[key] {
            states[id] = .translated(cached)
            return
        }
        if states[id] != nil || dwellTasks[id] != nil || activeTasks[id] != nil { return }
        dwellTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(self?.dwell ?? 1.5))
            guard !Task.isCancelled, let self else { return }
            self.dwellTasks[id] = nil
            self.enqueue(id: id, title: title)
        }
    }

    /// A row scrolled off screen: drop it from the dwell/translate queue. A
    /// finished (cached) translation is kept; an in-flight one is cancelled and
    /// its partial discarded, so it re-tries cleanly if seen again.
    public func rowDisappeared(id: Article.ID) {
        dwellTasks[id]?.cancel()
        dwellTasks[id] = nil
        pending.removeAll { $0.id == id }
        if let task = activeTasks[id] {
            task.cancel()
            activeTasks[id] = nil
            if case .translating = states[id] { states[id] = nil }
            fillSlots()
        }
    }

    private func enqueue(id: Article.ID, title: String) {
        let key = cacheKey(for: title)
        if let cached = cache[key] { states[id] = .translated(cached); return }
        if sameLanguage.contains(key) { return }
        guard activeTasks[id] == nil, !pending.contains(where: { $0.id == id }) else { return }
        pending.append((id, title))
        fillSlots()
    }

    private func fillSlots() {
        while activeTasks.count < maxConcurrent, !pending.isEmpty {
            let next = pending.removeFirst()
            startTranslate(id: next.id, title: next.title)
        }
    }

    private func startTranslate(id: Article.ID, title: String) {
        let key = cacheKey(for: title)
        let name = targetLanguageName
        let code = targetLanguageCode
        activeTasks[id] = Task { [weak self] in
            defer { self?.finish(id: id) }
            let detected = await Task.detached { ListTitleTranslator.detectLanguage(title) }.value
            if Task.isCancelled { return }
            guard let self else { return }
            // Already in the target language → leave the original untouched.
            if let detected, Self.baseCode(detected) == code {
                self.sameLanguage.insert(key)
                self.states[id] = nil
                return
            }
            do {
                let result = try await NaturalTranslator.streamTranslateBlock(title, into: name) { [weak self] partial in
                    guard let self, !Task.isCancelled else { return }
                    let trimmed = partial.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { self.states[id] = .translating(trimmed) }
                }
                if Task.isCancelled { return }
                let final = result.translation.trimmingCharacters(in: .whitespacesAndNewlines)
                // Guard against a degenerate result (empty, or an echo of the
                // source): show the original rather than a bad translation.
                if final.isEmpty || final == title {
                    self.states[id] = nil
                } else {
                    self.cache[key] = final
                    self.states[id] = .translated(final)
                }
            } catch {
                self.states[id] = nil
            }
        }
    }

    private func finish(id: Article.ID) {
        activeTasks[id] = nil
        fillSlots()
    }

    private func cancelAll() {
        for task in dwellTasks.values { task.cancel() }
        for task in activeTasks.values { task.cancel() }
        dwellTasks.removeAll()
        activeTasks.removeAll()
        pending.removeAll()
        states.removeAll()
    }

    private func cacheKey(for title: String) -> String { "\(targetLanguageCode)|\(title)" }

    private static func baseCode(_ code: String) -> String {
        Locale.Language(identifier: code).languageCode?.identifier ?? code
    }

    nonisolated private static func detectLanguage(_ title: String) -> String? {
        let sample = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sample.isEmpty else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        return recognizer.dominantLanguage?.rawValue
    }
}
