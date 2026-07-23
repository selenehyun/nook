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
/// The coordinator is deliberately NOT `@Observable`: a single observable state
/// dictionary made every row re-render (and re-measure) on any one title's update,
/// stuttering the list during scroll. Instead, per-article state lives in a small
/// observable `StateBox`, so only the one row translating re-renders.
@MainActor
public final class ListTitleTranslator {
    public static let shared = ListTitleTranslator()

    /// The visible state of a row's title translation.
    public enum TitleState: Equatable, Sendable {
        /// Streaming in — the latest cumulative snapshot.
        case translating(String)
        /// Final translated title.
        case translated(String)
    }

    /// Per-article observable state. A row observes only its own box, so a
    /// translation update re-renders that one row rather than the whole list.
    @MainActor
    @Observable
    public final class StateBox {
        public fileprivate(set) var state: TitleState?
        fileprivate init(state: TitleState? = nil) { self.state = state }
    }

    /// How long a row must stay on screen before its title is translated.
    public var dwell: TimeInterval = 1.5
    /// How many titles translate at once, drained FIFO from `pending`. Gemini is a
    /// network backend, so it's processed strictly one-at-a-time (a serial queue)
    /// to avoid a burst of requests when a screen of titles becomes eligible;
    /// on-device Apple Intelligence keeps a small parallel cap.
    private var maxConcurrent: Int { provider == .gemini ? 1 : 2 }

    private var enabled = false
    private var targetLanguageName = ""
    private var targetLanguageCode = ""
    /// Translation backend for list titles, from the title provider setting.
    private var provider: TranslationProvider = .appleIntelligence

    /// Per-article state boxes (stable references, interned by id). Not observed
    /// at the dictionary level — only each box's `state` is.
    private var boxes: [Article.ID: StateBox] = [:]

    /// The stable observable box for a row. Rows read this once and observe only
    /// its `state`. Interning a new box mutates a non-observed dictionary, so it's
    /// safe to call from a view body (no "publishing during view update").
    public func box(for id: Article.ID) -> StateBox {
        if let existing = boxes[id] { return existing }
        let created = StateBox()
        boxes[id] = created
        return created
    }

    private func liveState(for id: Article.ID) -> TitleState? { boxes[id]?.state }

    private func setState(_ newState: TitleState?, for id: Article.ID) {
        let box = box(for: id)
        if box.state != newState { box.state = newState }
    }

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
        let newProvider = TranslationSettings.titleProvider()
        let providerChanged = newProvider != self.provider
        let wasEnabled = self.enabled
        self.provider = newProvider
        self.enabled = enabled && NaturalTranslator.isAvailable(for: newProvider)
        self.targetLanguageName = targetLanguageName
        self.targetLanguageCode = targetLanguageCode
        if self.enabled { loadCacheIfNeeded() }
        if !self.enabled || languageChanged || providerChanged {
            cancelAll()
        }
        // Just turned on, or switched language/provider while on: translate the
        // rows already on screen now — without waiting for a dwell — so the list
        // the user is looking at updates immediately instead of only after scroll.
        if self.enabled, !wasEnabled || languageChanged || providerChanged {
            for (id, title) in visibleTitles {
                scheduleTranslation(id: id, title: title, afterDwell: false)
            }
        }
    }

    /// The row's visible state. Reads the box's live state (observed), falling back
    /// to an already-loaded cache hit synchronously — so a row whose translation
    /// was cached on a previous launch is full-height on its very first layout,
    /// before `onAppear` writes it into the box (this keeps the macOS List from
    /// juddering on scroll-up). Reading the cache here does NOT create an
    /// observation dependency, because the coordinator isn't `@Observable`.
    public func state(for box: StateBox, title: String) -> TitleState? {
        if let live = box.state { return live }
        guard enabled, !title.isEmpty else { return nil }
        if let cached = cache[cacheKey(for: title)] { return .translated(cached) }
        return nil
    }

    /// A row scrolled into view. After the dwell (if still requested), translate
    /// its title — unless it's already cached, already the target language, or in
    /// progress.
    public func rowAppeared(id: Article.ID, title: String) {
        guard !title.isEmpty else { return }
        // Track visibility even while disabled, so enabling the feature can find
        // the rows already on screen and translate them at once.
        visibleTitles[id] = title
        guard enabled else { return }
        scheduleTranslation(id: id, title: title, afterDwell: true)
    }

    /// Starts translating a visible row's title, unless it's already cached, the
    /// target language, abandoned, or in progress. `afterDwell` gates on the
    /// visible dwell (normal scroll-in); pass false to begin immediately (the row
    /// is already being looked at, e.g. the feature was just turned on).
    private func scheduleTranslation(id: Article.ID, title: String, afterDwell: Bool) {
        // If this row already has a state, don't re-set it (a no-op set is skipped
        // by setState anyway, but this also avoids the cache work).
        if liveState(for: id) != nil { return }
        let key = cacheKey(for: title)
        if sameLanguage.contains(key) || abandoned.contains(key) { return }
        if let cached = cache[key] {
            setState(.translated(cached), for: id)
            return
        }
        if dwellTasks[id] != nil || activeTasks[id] != nil { return }
        guard afterDwell else {
            enqueue(id: id, title: title)
            return
        }
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
            if case .translating = liveState(for: id) { setState(nil, for: id) }
        }
    }

    private func enqueue(id: Article.ID, title: String) {
        let key = cacheKey(for: title)
        if let cached = cache[key] { setState(.translated(cached), for: id); return }
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
        // Capture the provider for this task so a mid-flight provider switch can't
        // mix backends within one translation.
        let provider = self.provider
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
                self.setState(nil, for: id)
                return
            }

            // A list title is NOT revealed mid-flight: we deliberately skip the
            // intermediate `.translating` states and reveal only the final result,
            // in one step. Streaming a title into a `List` row changed the row's
            // height on every token, and each height change re-lays-out the whole
            // visible list (NSTableView re-anchors all rows), which is what
            // stuttered scrolling. Revealing once means a single layout pass, and
            // it lands after the dwell + inference (usually once scrolling settled).
            // The reader keeps its token-by-token streaming; only list titles pop
            // in whole, matching how a cache hit already appears.

            // Proper nouns / brands / acronyms (LG, SIMD, OpenAI, GPT-4, …) to keep
            // verbatim rather than translate or transliterate, in both passes.
            let keepTerms = NaturalTranslator.heuristicKeepTokens(title)

            // 1) Guided translation (retries once internally). We still use the
            //    streaming API for its guardrails/quality but discard partials so
            //    the row never re-lays-out per token.
            do {
                let result = try await NaturalTranslator.streamTranslateBlock(title, into: name, keepTerms: keepTerms, provider: provider) { _ in }
                if Task.isCancelled { return }
                let final = result.translation.trimmingCharacters(in: .whitespacesAndNewlines)
                if !final.isEmpty, !Self.isEcho(final, of: title) {
                    self.rememberTranslation(key, final)
                    self.setState(.translated(final), for: id)
                    return
                }
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled { return }
                // Guided decoding failed — commonly an echo of a short or
                // proper-noun-heavy title. Fall through to the plain fallback.
            }

            // 2) Escalate to a fresh, non-guided session. Small on-device models
            //    echo short / proper-noun-heavy titles verbatim under guided
            //    (structured) decoding, so the guardrails reject them and the title
            //    would otherwise never translate (e.g. "Everyone Should Know SIMD",
            //    "LG to Ban Residential Proxies from Smart TV Apps"). A plain prompt
            //    that keeps the proper nouns verbatim recovers a real translation —
            //    the same recovery the reader uses.
            if Task.isCancelled { return }
            if let plain = await NaturalTranslator.translatePlainFallback(title, into: name, keepTerms: keepTerms, provider: provider) {
                if Task.isCancelled { return }
                let final = plain.trimmingCharacters(in: .whitespacesAndNewlines)
                if !final.isEmpty, !Self.isEcho(final, of: title) {
                    self.rememberTranslation(key, final)
                    self.setState(.translated(final), for: id)
                    return
                }
            }

            // 3) Give up: collapse the block, show the original, and don't retry
            //    this title again until relaunch.
            if Task.isCancelled { return }
            self.abandoned.insert(key)
            self.setState(nil, for: id)
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
        if case .translating = liveState(for: id) { setState(nil, for: id) }
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
        // Reset each box's state in place (keep the map) so rows holding a box
        // reference update immediately and a re-enable reuses the same box.
        for box in boxes.values where box.state != nil { box.state = nil }
    }

    /// Deletes every saved title translation — the in-memory caches, the
    /// "same language" / "gave up" sets, and the on-disk file — and stops and
    /// clears anything in flight or on screen. Titles re-translate from scratch
    /// the next time their rows are viewed. Device-local; affects only this app.
    public func clearCache() {
        cancelAll()
        // Also forget which rows are on screen, so cancelled tasks don't reschedule
        // and immediately rebuild the cache we just cleared.
        visibleTitles.removeAll()
        cache.removeAll()
        cacheOrder.removeAll()
        sameLanguage.removeAll()
        sameLanguageOrder.removeAll()
        abandoned.removeAll()
        // Drop any pending save, then delete the persisted file.
        saveTask?.cancel()
        saveTask = nil
        if let url = Self.cacheURL() {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func cacheKey(for title: String) -> String { "\(provider.rawValue)|\(targetLanguageCode)|\(title)" }

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
