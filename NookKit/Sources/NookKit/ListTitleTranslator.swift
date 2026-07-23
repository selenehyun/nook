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
    /// Extra attempts after the first when a translation errors or comes back
    /// degenerate, before giving up and showing the original.
    private let maxRetries = 2

    private var enabled = false
    private var targetLanguageName = ""
    private var targetLanguageCode = ""

    /// Per-article visible translation state (absent = show the original only).
    public private(set) var states: [Article.ID: TitleState] = [:]

    // Device-local caches (never synced), persisted to Application Support so a
    // relaunch shows previously translated titles instantly and never re-requests.
    // Keyed by target language so a language switch re-translates rather than
    // showing a stale language. Insertion order is tracked for LRU-style pruning.
    private var cache: [String: String] = [:]
    private var cacheOrder: [String] = []
    private var sameLanguage: Set<String> = []
    private var sameLanguageOrder: [String] = []
    /// Titles whose translation exhausted `maxRetries` this launch. Kept in memory
    /// only (not persisted): a relaunch gives them a fresh chance, since failures
    /// are usually transient (model warming up, momentary unavailability).
    private var abandoned: Set<String> = []
    /// Soft cap per map. Titles are tiny, so this stays well under ~1 MB on disk
    /// while covering a very large backlog of read history.
    private let maxCacheEntries = 5000

    private var dwellTasks: [Article.ID: Task<Void, Never>] = [:]
    /// In-flight translations, each tagged with a generation token so a late
    /// `finish` from a cancelled task can't clobber a newer task for the same row.
    private var activeTasks: [Article.ID: (token: Int, task: Task<Void, Never>)] = [:]
    private var taskGeneration = 0
    private var pending: [(id: Article.ID, title: String)] = []
    /// Rows currently on screen, with their latest title. Lets `finish` reschedule
    /// a row that disappeared and reappeared while its cancelled task wound down.
    private var visibleTitles: [Article.ID: String] = [:]

    private var loadedFromDisk = false
    private var saveTask: Task<Void, Never>?

    public init() {}

    /// Sets the feature on/off and the target language. Turning it off (or the
    /// app being unavailable) cancels everything in flight and clears live state,
    /// but keeps the caches.
    public func configure(enabled: Bool, targetLanguageName: String, targetLanguageCode: String) {
        let languageChanged = targetLanguageCode != self.targetLanguageCode
        self.enabled = enabled && NaturalTranslator.isAvailable
        self.targetLanguageName = targetLanguageName
        self.targetLanguageCode = targetLanguageCode
        if self.enabled { loadCacheIfNeeded() }
        if !self.enabled || languageChanged {
            cancelAll()
        }
    }

    public func state(for id: Article.ID) -> TitleState? { states[id] }

    /// Like `state(for:)` but also resolves a translation that's only in the
    /// (already-loaded) cache synchronously, so a row whose translation was cached
    /// on a previous launch is full-height on its very first layout — before its
    /// `onAppear` writes it into `states`. Without this, such a row lays out short
    /// then grows a pass later, which makes the macOS List judder on scroll-up.
    public func state(for id: Article.ID, title: String) -> TitleState? {
        if let live = states[id] { return live }
        guard enabled, !title.isEmpty else { return nil }
        if let cached = cache[cacheKey(for: title)] { return .translated(cached) }
        return nil
    }

    /// A row scrolled into view. After the dwell (if still requested), translate
    /// its title — unless it's already cached, already the target language, or in
    /// progress.
    public func rowAppeared(id: Article.ID, title: String) {
        guard enabled, !title.isEmpty else { return }
        visibleTitles[id] = title
        // If this row already has a state, don't touch `states` — re-assigning the
        // same value would invalidate every row observing the dict and churn layout
        // on an ordinary scroll-in.
        if states[id] != nil { return }
        let key = cacheKey(for: title)
        if sameLanguage.contains(key) || abandoned.contains(key) { return }
        if let cached = cache[key] {
            states[id] = .translated(cached)
            return
        }
        if dwellTasks[id] != nil || activeTasks[id] != nil { return }
        dwellTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(self?.dwell ?? 1.5))
            guard !Task.isCancelled, let self else { return }
            self.dwellTasks[id] = nil
            self.enqueue(id: id, title: title)
        }
    }

    /// A row scrolled off screen: drop it from the dwell/translate queue. A
    /// finished (cached) translation is kept; an in-flight one is cancelled and
    /// its partial discarded. The slot is freed by the task's own `finish` (not
    /// here), so the concurrency count stays correct even as it winds down.
    public func rowDisappeared(id: Article.ID) {
        visibleTitles[id] = nil
        dwellTasks[id]?.cancel()
        dwellTasks[id] = nil
        pending.removeAll { $0.id == id }
        if let entry = activeTasks[id] {
            entry.task.cancel()
            if case .translating = states[id] { states[id] = nil }
        }
    }

    private func enqueue(id: Article.ID, title: String) {
        let key = cacheKey(for: title)
        if let cached = cache[key] { states[id] = .translated(cached); return }
        if sameLanguage.contains(key) || abandoned.contains(key) { return }
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
        taskGeneration += 1
        let token = taskGeneration
        let task = Task { [weak self] in
            defer { self?.finish(id: id, token: token, wasCancelled: Task.isCancelled) }
            let alreadyTarget = await Task.detached {
                ListTitleTranslator.isAlreadyInTargetLanguage(title, targetCode: code)
            }.value
            if Task.isCancelled { return }
            guard let self else { return }
            // Already readable in the user's language (dominant, or visibly mixed
            // in) → leave the original untouched, no block.
            if alreadyTarget {
                self.rememberSameLanguage(key)
                self.states[id] = nil
                return
            }

            // Show the block once, up front, as a "translating" placeholder so the
            // row reveals a single time; tokens then fill it in (the block fits its
            // content, growing at most from one line to two while it streams).
            self.states[id] = .translating("")

            for attempt in 0...self.maxRetries {
                if Task.isCancelled { return }
                do {
                    let result = try await NaturalTranslator.streamTranslateBlock(title, into: name) { [weak self] partial in
                        guard let self, !Task.isCancelled else { return }
                        let trimmed = partial.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty { self.states[id] = .translating(trimmed) }
                    }
                    if Task.isCancelled { return }
                    let final = result.translation.trimmingCharacters(in: .whitespacesAndNewlines)
                    // A degenerate result (empty, or an echo of the source) counts
                    // as a failed attempt so a retry can produce a real one.
                    if !final.isEmpty, !Self.isEcho(final, of: title) {
                        self.rememberTranslation(key, final)
                        self.states[id] = .translated(final)
                        return
                    }
                } catch is CancellationError {
                    return
                } catch {
                    if Task.isCancelled { return }
                    // A real translation error: fall through to retry / give up.
                }

                if attempt < self.maxRetries {
                    // Reset the partial (so a shorter retry can't look like it's
                    // rewinding) but keep the block up; back off before retrying.
                    self.states[id] = .translating("")
                    do { try await Task.sleep(for: .seconds(0.6 * Double(attempt + 1))) }
                    catch { return } // cancelled during backoff — not a failure
                }
            }

            // Exhausted every attempt: collapse the block, show the original, and
            // don't retry this title again until relaunch.
            if Task.isCancelled { return }
            self.abandoned.insert(key)
            self.states[id] = nil
        }
        activeTasks[id] = (token, task)
    }

    private func finish(id: Article.ID, token: Int, wasCancelled: Bool) {
        // Ignore a late finish from a task that was already superseded for this row
        // (disappear → reappear started a newer one): it must not free the slot or
        // erase the newer task.
        guard activeTasks[id]?.token == token else { return }
        activeTasks[id] = nil
        // A finished task must never leave the row stuck mid-stream.
        if case .translating = states[id] { states[id] = nil }
        fillSlots()
        // Reschedule ONLY when this task was genuinely cancelled (a transient
        // disappear) yet the row is on screen again — i.e. a real reappear gap.
        // Gating on `wasCancelled` avoids an infinite dwell→start→finish loop if the
        // translation API were to keep throwing without the task being cancelled.
        if wasCancelled, let title = visibleTitles[id] {
            rowAppeared(id: id, title: title)
        }
    }

    private func cancelAll() {
        for task in dwellTasks.values { task.cancel() }
        // Cancel but DON'T drop the active entries here: a cancelled task may not
        // have stopped yet, and clearing the slot early would let a re-enable start
        // extra tasks past `maxConcurrent`. Each task's token-guarded `finish` frees
        // its own slot when it actually ends.
        for entry in activeTasks.values { entry.task.cancel() }
        dwellTasks.removeAll()
        pending.removeAll()
        states.removeAll()
    }

    private func cacheKey(for title: String) -> String { "\(targetLanguageCode)|\(title)" }

    private nonisolated static func baseCode(_ code: String) -> String {
        Locale.Language(identifier: code).languageCode?.identifier ?? code
    }

    /// Whether `output` is really just the source echoed back untranslated,
    /// comparing after trimming, Unicode canonicalization, and case folding so a
    /// cosmetic difference doesn't hide an untranslated result.
    private nonisolated static func isEcho(_ output: String, of source: String) -> Bool {
        func normalize(_ text: String) -> String {
            text.trimmingCharacters(in: .whitespacesAndNewlines)
                .precomposedStringWithCanonicalMapping
                .lowercased()
        }
        return normalize(output) == normalize(source)
    }

    /// Whether `title` already reads as the user's language, so translating it
    /// would be noise. True when it's dominantly that language, OR it visibly
    /// contains that language's script (mixed titles like Korean + English) — the
    /// dominant-only check wrongly flagged such titles as foreign because a few
    /// English tokens can out-vote the Korean ones on a short string.
    nonisolated private static func isAlreadyInTargetLanguage(_ title: String, targetCode: String) -> Bool {
        let sample = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sample.isEmpty else { return true }

        // Script heuristic (reliable for non-Latin targets): if the user's writing
        // system already makes up a meaningful share of the letters, they can read
        // it — so a mixed-language title should not be translated.
        if let ratio = targetScriptRatio(sample, targetCode: targetCode), ratio >= 0.15 {
            return true
        }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        if let dominant = recognizer.dominantLanguage?.rawValue, baseCode(dominant) == targetCode {
            return true
        }
        // Secondary signal for Latin-script targets (where the script heuristic
        // can't discriminate): a meaningful probability mass on the target.
        let hypotheses = recognizer.languageHypotheses(withMaximum: 5)
        let targetProbability = hypotheses
            .filter { baseCode($0.key.rawValue) == targetCode }
            .reduce(0.0) { $0 + $1.value }
        return targetProbability >= 0.20
    }

    /// The fraction of letters in `text` that belong to the target language's
    /// characteristic (non-Latin) script, or nil when the target uses the Latin
    /// script (where this heuristic can't discriminate).
    nonisolated private static func targetScriptRatio(_ text: String, targetCode: String) -> Double? {
        guard let inTargetScript = scriptMembership(for: targetCode) else { return nil }
        var total = 0
        var matching = 0
        for scalar in text.unicodeScalars where scalar.properties.isAlphabetic {
            total += 1
            if inTargetScript(scalar) { matching += 1 }
        }
        guard total > 0 else { return nil }
        return Double(matching) / Double(total)
    }

    /// A membership test for the target language's characteristic script, or nil
    /// for Latin-script languages. Japanese keys on kana (kanji alone is ambiguous
    /// with Chinese); Chinese on Han; Korean on Hangul.
    nonisolated private static func scriptMembership(for targetCode: String) -> ((Unicode.Scalar) -> Bool)? {
        switch targetCode {
        case "ko":
            return { s in
                (0xAC00...0xD7A3).contains(s.value)      // Hangul syllables
                    || (0x1100...0x11FF).contains(s.value) // Hangul Jamo
                    || (0x3130...0x318F).contains(s.value) // compatibility Jamo
            }
        case "ja":
            return { s in
                (0x3040...0x309F).contains(s.value)        // Hiragana
                    || (0x30A0...0x30FF).contains(s.value) // Katakana
            }
        case "zh":
            return { s in
                (0x4E00...0x9FFF).contains(s.value)        // CJK Unified Ideographs
                    || (0x3400...0x4DBF).contains(s.value) // Extension A
            }
        case "ru", "uk", "bg", "sr", "be", "mk":
            return { s in (0x0400...0x04FF).contains(s.value) } // Cyrillic
        case "ar", "fa", "ur":
            return { s in (0x0600...0x06FF).contains(s.value) } // Arabic
        case "hi", "mr", "ne":
            return { s in (0x0900...0x097F).contains(s.value) } // Devanagari
        case "th":
            return { s in (0x0E00...0x0E7F).contains(s.value) } // Thai
        case "he", "yi":
            return { s in (0x0590...0x05FF).contains(s.value) } // Hebrew
        case "el":
            return { s in (0x0370...0x03FF).contains(s.value) } // Greek
        default:
            return nil // Latin-script languages: rely on the recognizer instead.
        }
    }

    // MARK: - Persistence

    /// A finished translation: cache it (LRU-capped) and schedule a save so it
    /// survives relaunch and never re-translates.
    private func rememberTranslation(_ key: String, _ value: String) {
        if cache[key] == nil { cacheOrder.append(key) }
        cache[key] = value
        while cacheOrder.count > maxCacheEntries {
            let oldest = cacheOrder.removeFirst()
            cache[oldest] = nil
        }
        scheduleSave()
    }

    /// A title found to already be in the target language: remember it (LRU-capped)
    /// so it's never re-detected, and schedule a save.
    private func rememberSameLanguage(_ key: String) {
        guard sameLanguage.insert(key).inserted else { return }
        sameLanguageOrder.append(key)
        while sameLanguageOrder.count > maxCacheEntries {
            let oldest = sameLanguageOrder.removeFirst()
            sameLanguage.remove(oldest)
        }
        scheduleSave()
    }

    /// On-disk shape of the cache. Order arrays preserve LRU across launches.
    private struct Persisted: Codable {
        var cache: [String: String]
        var cacheOrder: [String]
        var sameLanguage: [String]
    }

    /// Application Support/Nook/ListTitleTranslations.json — device-local, outside
    /// the sync folder, so it is never shared between devices.
    private nonisolated static func cacheURL() -> URL? {
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ) else { return nil }
        let dir = base.appendingPathComponent("Nook", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("ListTitleTranslations.json")
    }

    /// Loads the persisted caches once, merging under any entries already learned
    /// this session (which are newer). Cheap: a small JSON read at first enable.
    private func loadCacheIfNeeded() {
        guard !loadedFromDisk else { return }
        loadedFromDisk = true
        guard let url = Self.cacheURL(),
              let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode(Persisted.self, from: data) else { return }
        for key in stored.cacheOrder where cache[key] == nil {
            if let value = stored.cache[key] {
                cache[key] = value
                cacheOrder.append(key)
            }
        }
        for key in stored.sameLanguage where sameLanguage.insert(key).inserted {
            sameLanguageOrder.append(key)
        }
    }

    /// Debounced, off-main write. Coalesces the bursts of completions that happen
    /// while scrolling into a single disk write ~1s later.
    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = Persisted(cache: cache, cacheOrder: cacheOrder, sameLanguage: sameLanguageOrder)
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await Self.write(snapshot)
            _ = self
        }
    }

    private nonisolated static func write(_ snapshot: Persisted) async {
        await Task.detached(priority: .utility) {
            guard let url = cacheURL(), let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }.value
    }
}
