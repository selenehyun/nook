import Foundation
import Observation

/// Translates HTML fragments while preserving inline markup, the native-view
/// counterpart to the web view's DOM engine. There is no live DOM here, so it
/// serializes a fragment's inline tags into `⟦n⟧…⟦/n⟧` markers (opaque/void tags
/// as `⟦=n⟧`), keeping the original tag strings — including attributes like
/// `href` — indexed. After the model translates the marked text it rebuilds the
/// fragment by mapping markers back to the original tags. Strict validation
/// guarantees a broken marker set can never produce corrupt markup: it falls
/// back to plain translated text instead.
enum InlineMarkupTranslator {
    struct Entry: Equatable {
        let raw: String   // the original opening (or void) tag, verbatim
        let name: String  // lowercased tag name, for the closing tag
        let opaque: Bool  // void/self-closing: preserved, never translated into
    }

    private static let openMarker = "\u{27E6}"   // ⟦
    private static let closeMarker = "\u{27E7}"   // ⟧
    private static let tagRegex = try! NSRegularExpression(pattern: "<[^>]+>")
    private static let markerRegex = try! NSRegularExpression(pattern: "\u{27E6}(=|/)?([0-9]+)\u{27E7}")
    private static let voidTags: Set<String> = [
        "br", "wbr", "img", "hr", "source", "col", "area", "input",
        "meta", "link", "base", "embed", "param", "track",
    ]

    /// Turns an HTML fragment into a translatable template (decoded text plus
    /// inline markers) and the ordered table of original tags to restore.
    static func markify(_ html: String) -> (template: String, entries: [Entry]) {
        let ns = html as NSString
        var template = ""
        var entries: [Entry] = []
        var stack: [(index: Int, name: String)] = []
        var cursor = 0
        for match in tagRegex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let range = match.range
            if range.location > cursor {
                template += HTMLContentParser.decodeEntities(
                    ns.substring(with: NSRange(location: cursor, length: range.location - cursor))
                )
            }
            cursor = range.location + range.length
            let tag = ns.substring(with: range)
            let name = tagName(tag)
            guard !name.isEmpty else { continue }
            if tag.hasPrefix("</") {
                // Only honor a close that matches the current open; drop strays.
                if let top = stack.last, top.name == name {
                    stack.removeLast()
                    template += "\(openMarker)/\(top.index)\(closeMarker)"
                }
            } else if tag.hasSuffix("/>") || voidTags.contains(name) {
                let index = entries.count
                entries.append(Entry(raw: tag, name: name, opaque: true))
                template += "\(openMarker)=\(index)\(closeMarker)"
            } else {
                let index = entries.count
                entries.append(Entry(raw: tag, name: name, opaque: false))
                stack.append((index, name))
                template += "\(openMarker)\(index)\(closeMarker)"
            }
        }
        if cursor < ns.length {
            template += HTMLContentParser.decodeEntities(ns.substring(from: cursor))
        }
        // Auto-close any unclosed opens so the template stays balanced.
        while let top = stack.popLast() {
            template += "\(openMarker)/\(top.index)\(closeMarker)"
        }
        return (template, entries)
    }

    /// Rebuilds an HTML fragment from a translated template, restoring the
    /// original tags by index. Returns `nil` if the markers are inconsistent
    /// (dropped, duplicated, mis-nested, or out of range) so the caller can fall
    /// back to plain text rather than emit broken markup.
    static func rebuild(_ template: String, entries: [Entry]) -> String? {
        let ns = template as NSString
        let matches = markerRegex.matches(in: template, range: NSRange(location: 0, length: ns.length))

        // Validate first.
        var stack: [Int] = []
        var seen = Set<Int>()
        for match in matches {
            let kind = match.range(at: 1).location == NSNotFound ? "" : ns.substring(with: match.range(at: 1))
            guard let index = Int(ns.substring(with: match.range(at: 2))), index >= 0, index < entries.count else {
                return nil
            }
            switch kind {
            case "=":
                if seen.contains(index) || !entries[index].opaque { return nil }
                seen.insert(index)
            case "/":
                if stack.popLast() != index { return nil }
            default:
                if seen.contains(index) || entries[index].opaque { return nil }
                seen.insert(index)
                stack.append(index)
            }
        }
        guard stack.isEmpty, seen.count == entries.count else { return nil }

        // Emit. Validation guarantees balanced/nested markers, so a linear pass
        // reproduces the correct structure.
        var out = ""
        var cursor = 0
        for match in matches {
            let range = match.range
            if range.location > cursor {
                out += escape(ns.substring(with: NSRange(location: cursor, length: range.location - cursor)))
            }
            cursor = range.location + range.length
            let kind = match.range(at: 1).location == NSNotFound ? "" : ns.substring(with: match.range(at: 1))
            let index = Int(ns.substring(with: match.range(at: 2)))!
            switch kind {
            case "/": out += "</\(entries[index].name)>"
            default: out += entries[index].raw   // open or opaque: original tag verbatim
            }
        }
        if cursor < ns.length { out += escape(ns.substring(from: cursor)) }
        return out
    }

    /// Plain translated text (markers stripped, HTML-escaped) for the fallback
    /// path — safe to render, just without inline styling.
    static func plainFallback(_ template: String) -> String {
        escape(stripMarkers(template))
    }

    static func stripMarkers(_ template: String) -> String {
        // Well-formed markers first, then any corrupted leftovers: the model can
        // mangle a marker (e.g. ⟦=5⟧ → "⟦5⟦3"), and since ⟦/⟧ never occur in real
        // text, remove any opener with its index digits even when the closer is
        // missing/misplaced, plus any stray delimiter — so nothing leaks into the
        // displayed text or the plain fallback.
        return template
            .replacingOccurrences(of: "\u{27E6}[=/]?[0-9]+\u{27E7}", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\u{27E6}[=/]?[0-9]*\u{27E7}?", with: "", options: .regularExpression)
            .replacingOccurrences(of: "[\u{27E6}\u{27E7}]", with: "", options: .regularExpression)
    }

    /// Approximate upper bound on the characters of a marked template sent to the
    /// on-device model in one call. A longer fragment silently fails to translate
    /// (the model's context is bounded), leaving the original text in place, so
    /// long fragments are split into chunks near this size — see `chunk`.
    static let maxChunkChars = 600

    /// Splits a marked template into sequential chunks no larger than ~`maxChars`,
    /// cutting only at sentence boundaries where the inline-marker depth is 0 — so
    /// every chunk carries balanced markers and the concatenated translations
    /// still rebuild. Falls back to depth-0 word breaks for a single over-long
    /// sentence, and to the whole remainder when there is no boundary at all.
    static func chunk(_ template: String, maxChars: Int = maxChunkChars) -> [String] {
        let ns = template as NSString
        guard ns.length > maxChars else { return [template] }

        var markerByStart: [Int: NSTextCheckingResult] = [:]
        for m in markerRegex.matches(in: template, range: NSRange(location: 0, length: ns.length)) {
            markerByStart[m.range.location] = m
        }

        // Single scan tracking marker depth: record cut points (right after a
        // boundary) only at depth 0. `hard` follows sentence enders; `soft`
        // follows any whitespace, used only when no sentence boundary fits.
        let enders: Set<Unicode.Scalar> = Set(".!?。！？…".unicodeScalars)
        var hardCuts: [Int] = []
        var softCuts: [Int] = []
        var depth = 0
        var i = 0
        while i < ns.length {
            if let m = markerByStart[i] {
                let kind = m.range(at: 1).location == NSNotFound ? "" : ns.substring(with: m.range(at: 1))
                switch kind {
                case "/": depth = max(0, depth - 1)
                case "=": break
                default: depth += 1
                }
                i = m.range.location + m.range.length
                continue
            }
            if depth == 0, let scalar = Unicode.Scalar(ns.character(at: i)) {
                if CharacterSet.whitespacesAndNewlines.contains(scalar), i > 0 {
                    softCuts.append(i + 1)
                    if let prev = Unicode.Scalar(ns.character(at: i - 1)), enders.contains(prev) {
                        hardCuts.append(i + 1)
                    }
                } else if enders.contains(scalar) {
                    // CJK enders often have no trailing space.
                    hardCuts.append(i + 1)
                }
            }
            i += 1
        }

        // Greedily pack: from each start, prefer the furthest hard cut within
        // budget, then the furthest soft cut, then the nearest cut beyond budget.
        var chunks: [String] = []
        var start = 0
        while start < ns.length {
            if ns.length - start <= maxChars {
                chunks.append(ns.substring(from: start))
                break
            }
            let limit = start + maxChars
            let cut = hardCuts.last(where: { $0 > start && $0 <= limit })
                ?? softCuts.last(where: { $0 > start && $0 <= limit })
                ?? hardCuts.first(where: { $0 > start })
                ?? softCuts.first(where: { $0 > start })
                ?? ns.length
            chunks.append(ns.substring(with: NSRange(location: start, length: cut - start)))
            start = cut
        }
        return chunks
    }

    /// Re-expresses a marker-balanced chunk of a template as a self-contained
    /// template with its own 0-based marker indices, paired with the matching
    /// subset of `entries`. This lets each chunk be rebuilt independently, so one
    /// chunk mangling its markers degrades only that chunk to plain text instead
    /// of stripping styles (links, emphasis, strikethrough) from the whole
    /// paragraph. Chunks from `chunk` are always depth-0 balanced, so every
    /// close's open — and thus its local index — is present in the same chunk.
    static func localize(_ chunk: String, entries: [Entry]) -> (template: String, entries: [Entry]) {
        let ns = chunk as NSString
        let matches = markerRegex.matches(in: chunk, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return (chunk, []) }

        var globalToLocal: [Int: Int] = [:]
        var localEntries: [Entry] = []
        for m in matches {
            guard let g = Int(ns.substring(with: m.range(at: 2))), g >= 0, g < entries.count else { continue }
            if globalToLocal[g] == nil {
                globalToLocal[g] = localEntries.count
                localEntries.append(entries[g])
            }
        }
        var out = ""
        var cursor = 0
        for m in matches {
            let range = m.range
            if range.location > cursor {
                out += ns.substring(with: NSRange(location: cursor, length: range.location - cursor))
            }
            cursor = range.location + range.length
            let kind = m.range(at: 1).location == NSNotFound ? "" : ns.substring(with: m.range(at: 1))
            if let g = Int(ns.substring(with: m.range(at: 2))), let l = globalToLocal[g] {
                out += "\u{27E6}\(kind)\(l)\u{27E7}"
            } else {
                out += ns.substring(with: range)
            }
        }
        if cursor < ns.length { out += ns.substring(from: cursor) }
        return (out, localEntries)
    }

    /// One translatable unit of a `.text` block. Paragraph-level so a long body
    /// (which the parser keeps as one `.text` block) is translated and streamed
    /// paragraph by paragraph instead of in a single oversized model call.
    struct Segment: Equatable {
        let raw: String        // the original slice, shown until translated
        let translatable: Bool // false for tag-only/whitespace gaps (e.g. <ul>)
        let open: String       // wrapping open tag (e.g. "<p>"), "" for loose text
        let inner: String      // content to translate
        let close: String      // wrapping close tag (e.g. "</p>"), "" for loose text
    }

    private static let paragraphRegex = try! NSRegularExpression(
        pattern: "<(p|li|h[1-6]|figcaption|dt|dd|caption)\\b[^>]*>(.*?)</\\1\\s*>",
        options: [.caseInsensitive, .dotMatchesLineSeparators]
    )

    /// Splits a `.text` fragment into paragraph-level segments in document order.
    static func segments(_ html: String) -> [Segment] {
        let ns = html as NSString
        let matches = paragraphRegex.matches(in: html, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else {
            // No paragraph structure: translate the whole fragment as one unit.
            return [Segment(raw: html, translatable: true, open: "", inner: html, close: "")]
        }
        var segments: [Segment] = []
        var cursor = 0
        for match in matches {
            let full = match.range
            if full.location > cursor {
                appendGap(ns.substring(with: NSRange(location: cursor, length: full.location - cursor)), to: &segments)
            }
            cursor = full.location + full.length
            let innerRange = match.range(at: 2)
            let open = ns.substring(with: NSRange(location: full.location, length: innerRange.location - full.location))
            let inner = ns.substring(with: innerRange)
            let closeStart = innerRange.location + innerRange.length
            let close = ns.substring(with: NSRange(location: closeStart, length: (full.location + full.length) - closeStart))
            segments.append(Segment(raw: ns.substring(with: full), translatable: true, open: open, inner: inner, close: close))
        }
        if cursor < ns.length {
            appendGap(ns.substring(from: cursor), to: &segments)
        }
        return segments
    }

    private static func appendGap(_ gap: String, to segments: inout [Segment]) {
        guard !gap.isEmpty else { return }
        let text = HTMLContentParser.decodeEntities(
            gap.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            segments.append(Segment(raw: gap, translatable: false, open: "", inner: "", close: ""))
        } else {
            segments.append(Segment(raw: gap, translatable: true, open: "", inner: gap, close: ""))
        }
    }

    private static func tagName(_ tag: String) -> String {
        var scalarsView = Substring(tag.dropFirst())   // drop '<'
        if scalarsView.hasPrefix("/") { scalarsView = scalarsView.dropFirst() }
        var name = ""
        for ch in scalarsView {
            if ch == " " || ch == ">" || ch == "/" || ch == "\t" || ch == "\n" { break }
            name.append(ch)
        }
        return name.lowercased()
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

/// Drives streaming, in-place translation of the native reader's content: it
/// parses the article into the same blocks `HTMLContentView` renders, then
/// translates the translatable ones (title first) in document order, threading a
/// running context summary through each so the on-device model stays consistent.
/// Non-text blocks (code, images, video, rules) are left untouched. Views read
/// `translatedBlock(at:)` and re-render as each result streams in.
@MainActor
@Observable
public final class NativeArticleTranslator {
    public private(set) var isActive = false
    public private(set) var isTranslating = false
    public private(set) var translatedTitle: String?

    private var overrides: [Int: HTMLContentBlock] = [:]
    private var task: Task<Void, Never>?
    private var generation = 0
    /// The article's detected subject/field, passed to block translation so it
    /// reads with field-appropriate terminology. Empty until detected.
    private var conceptDomain = ""

    public init() {}

    /// The translated replacement for the top-level block at `index`, or nil to
    /// render the original (not yet translated, or not translatable). Internal:
    /// only the block list (same module) consults it.
    func translatedBlock(at index: Int) -> HTMLContentBlock? {
        isActive ? overrides[index] : nil
    }

    /// Begins (or restarts) translation of `html` into `languageName`. `title`
    /// is translated first to seed context and exposed via `translatedTitle`.
    public func start(html: String, baseURL: URL?, title: String, into languageName: String) {
        stop()
        isActive = true
        isTranslating = true
        generation += 1
        let token = generation
        let blocks = HTMLContentParser.parse(html, baseURL: baseURL)
        task = Task { [weak self] in
            await self?.run(title: title, blocks: blocks, language: languageName, token: token)
        }
    }

    /// Turns translation off and reverts to the original content.
    public func stop() {
        task?.cancel()
        task = nil
        isActive = false
        isTranslating = false
        overrides = [:]
        translatedTitle = nil
        conceptDomain = ""
    }

    private func run(title: String, blocks: [HTMLContentBlock], language: String, token: Int) async {
        var context = ""

        // Detect the article's subject up front so each block is translated with
        // field-appropriate terminology (best-effort; empty if unavailable).
        conceptDomain = await NaturalTranslator.detectConcept(from: conceptSample(title: title, blocks: blocks)) ?? ""
        guard token == generation else { return }

        // Title: a plain, bounded translation. Using the simple translator (not
        // the block/marker one) keeps a short title from ever ballooning into a
        // paragraph, and a length guard drops any runaway result.
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty, let translated = try? await NaturalTranslator.translate(trimmedTitle, into: language) {
            guard token == generation else { return }
            let cleaned = translated.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty, cleaned.count <= max(120, trimmedTitle.count * 4) {
                translatedTitle = cleaned
            }
        }

        for (index, block) in blocks.enumerated() {
            guard token == generation, !Task.isCancelled else { return }
            context = await translate(block, at: index, language: language, context: context, token: token)
        }

        if token == generation { isTranslating = false }
    }

    /// A short plain-text sample (title + leading prose) used to detect the
    /// article's subject/field. Bounded so concept detection stays cheap.
    private func conceptSample(title: String, blocks: [HTMLContentBlock]) -> String {
        var parts = [title.trimmingCharacters(in: .whitespacesAndNewlines)]
        for block in blocks {
            let plain: String
            switch block {
            case .text(let html):
                plain = InlineMarkupTranslator.stripMarkers(html)
                    .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            case .heading(_, let html):
                plain = InlineMarkupTranslator.stripMarkers(html)
                    .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            default:
                continue
            }
            let trimmed = plain.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { parts.append(trimmed) }
            if parts.reduce(0, { $0 + $1.count }) > 1200 { break }
        }
        return parts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Translates one top-level block, updating its override as results stream in
    /// and returning the advanced context. Non-translatable blocks are left as-is.
    private func translate(
        _ block: HTMLContentBlock, at index: Int, language: String, context: String, token: Int
    ) async -> String {
        switch block {
        case .text(let html):
            return await translateTextBlock(html, at: index, wrap: { .text($0) }, language: language, context: context, token: token)
        case .heading(let level, let html):
            return await translateTextBlock(html, at: index, wrap: { .heading(level: level, html: $0) }, language: language, context: context, token: token)
        case .blockquote(let inner):
            var context = context
            var translatedInner = inner
            for (childIndex, child) in inner.enumerated() {
                guard token == generation else { return context }
                let (replacement, newContext) = await translateNested(child, language: language, context: context, token: token)
                context = newContext
                if let replacement {
                    translatedInner[childIndex] = replacement
                    guard token == generation else { return context }
                    overrides[index] = .blockquote(translatedInner)
                }
            }
            return context
        case .list(let ordered, let items):
            var context = context
            var translatedItems = items
            for (itemIndex, itemBlocks) in items.enumerated() {
                var translatedBlocks = itemBlocks
                for (childIndex, child) in itemBlocks.enumerated() {
                    guard token == generation else { return context }
                    let (replacement, newContext) = await translateNested(child, language: language, context: context, token: token)
                    context = newContext
                    if let replacement {
                        translatedBlocks[childIndex] = replacement
                        translatedItems[itemIndex] = translatedBlocks
                        guard token == generation else { return context }
                        overrides[index] = .list(ordered: ordered, items: translatedItems)
                    }
                }
            }
            return context
        case .table(let table):
            var context = context
            var rows = table.rows
            for (rowIndex, row) in table.rows.enumerated() {
                var cells = row.cells
                for (cellIndex, cell) in row.cells.enumerated() {
                    guard token == generation else { return context }
                    guard let (translatedCell, newContext) = await translateFragment(cell, language: language, context: context, token: token) else { continue }
                    context = newContext
                    cells[cellIndex] = translatedCell
                    rows[rowIndex] = HTMLTable.Row(cells: cells, isHeader: row.isHeader)
                    guard token == generation else { return context }
                    overrides[index] = .table(HTMLTable(rows: rows))
                }
            }
            return context
        default:
            return context   // code, media, rules: keep the original
        }
    }

    /// Translates a `.text`/`.heading` fragment paragraph by paragraph, updating
    /// the override after each so the block fills in top-to-bottom.
    private func translateTextBlock(
        _ html: String,
        at index: Int,
        wrap: (String) -> HTMLContentBlock,
        language: String,
        context: String,
        token: Int
    ) async -> String {
        var context = context
        let segments = InlineMarkupTranslator.segments(html)
        var output = segments.map(\.raw)
        for (segmentIndex, segment) in segments.enumerated() where segment.translatable {
            guard token == generation else { return context }
            let active = segmentIndex
            // Show the caret at the start of this segment the moment translation
            // begins — before the first token arrives — so it's clear which block
            // is being translated during the model's initial latency.
            overrides[index] = .mixedText(mixedParts(output: output, activeIndex: active, activePartial: ""))
            // Stream this segment token-by-token: show the growing plain text for
            // the active segment while the others stay rendered as HTML.
            let result = await translateFragmentStreaming(
                segment.inner, language: language, context: context, token: token
            ) { partial in
                guard token == self.generation else { return }
                self.overrides[index] = .mixedText(self.mixedParts(output: output, activeIndex: active, activePartial: partial))
            }
            guard let (translatedInner, newContext) = result else { continue }
            context = newContext
            output[segmentIndex] = segment.open + translatedInner + segment.close
            guard token == generation else { return context }
            // Settle the finished segment; the next one re-emits (or the loop ends
            // and the block collapses to a single importer-rendered block below).
            overrides[index] = .mixedText(mixedParts(output: output, activeIndex: -1, activePartial: ""))
        }
        guard token == generation else { return context }
        // Collapse to the final single block so the settled layout/import path is
        // identical to a non-streamed translation.
        overrides[index] = wrap(output.joined())
        return context
    }

    /// Builds the streaming block's parts: the active segment shows its dimmed
    /// original (`.pending`) until the first token arrives, then streams as plain
    /// text (`.plain`) — so the block never blanks and crossfades in place — while
    /// every other non-empty segment renders as its HTML.
    private func mixedParts(output: [String], activeIndex: Int, activePartial: String) -> [HTMLContentBlock.TextPart] {
        var parts: [HTMLContentBlock.TextPart] = []
        for (i, segment) in output.enumerated() {
            if i == activeIndex {
                parts.append(activePartial.isEmpty ? .pending(segment) : .plain(activePartial))
            } else if !segment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                parts.append(.html(segment))
            }
        }
        return parts
    }

    /// Streaming counterpart to `translateFragment`: forwards each marker-stripped
    /// partial to `onPartial` for live rendering, then returns the final rebuilt
    /// fragment. Returns nil when there's nothing translatable or it failed.
    private func translateFragmentStreaming(
        _ html: String, language: String, context: String, token: Int,
        onPartial: @escaping (String) -> Void
    ) async -> (String, String)? {
        let (template, entries) = InlineMarkupTranslator.markify(html)
        guard !InlineMarkupTranslator.stripMarkers(template).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        // Split long fragments so no single model call exceeds the on-device
        // context (which would silently fail and leave the text untranslated).
        // Chunks translate in order; the live text shows finished chunks plus the
        // one currently streaming.
        let chunks = InlineMarkupTranslator.chunk(template)
        var htmlParts: [String] = []
        var finishedStripped = ""
        for chunk in chunks {
            guard token == generation else { return nil }
            let prefix = finishedStripped   // immutable snapshot for the closure
            let (chunkHTML, stripped) = await translateChunk(
                chunk, entries: entries, language: language, token: token,
                onPartial: { live in
                    guard token == self.generation else { return }
                    onPartial(prefix + live)
                }
            )
            htmlParts.append(chunkHTML)
            finishedStripped += stripped
            if !finishedStripped.hasSuffix(" ") { finishedStripped += " " }
        }
        guard token == generation else { return nil }
        // Each chunk is already rebuilt HTML; just join them.
        return (htmlParts.joined(), "")
    }

    /// Translates one chunk and rebuilds it **independently**: the chunk is
    /// re-numbered to self-contained local markers, translated, then rebuilt on
    /// its own. So a chunk that mangles its markers degrades only itself to plain
    /// text, while sibling chunks keep their links/emphasis/strikethrough — rather
    /// than one bad chunk stripping styles from the whole paragraph. Returns the
    /// rebuilt HTML piece to concatenate and its marker-stripped text for the live
    /// display.
    private func translateChunk(
        _ chunk: String, entries: [InlineMarkupTranslator.Entry], language: String, token: Int,
        onPartial: @escaping (String) -> Void
    ) async -> (html: String, stripped: String) {
        let (local, localEntries) = InlineMarkupTranslator.localize(chunk, entries: entries)
        let translated = await escalateTranslate(local, language: language, token: token, onPartial: onPartial)
        // Rebuild this chunk alone; on marker failure fall back to plain text for
        // just this chunk. When we gave up (translated == local, the untranslated
        // original), rebuild restores the original tags around the original text —
        // so a failed chunk still shows its source styling rather than raw markers.
        let html = InlineMarkupTranslator.rebuild(translated, entries: localEntries)
            ?? InlineMarkupTranslator.plainFallback(translated)
        return (html, InlineMarkupTranslator.stripMarkers(translated))
    }

    /// The escalation ladder for one localized chunk, returning a marker-bearing
    /// translation (or plain text, or the original) so the caller can rebuild it:
    /// guided streaming → a fresh guided attempt (both preserve inline markers) →
    /// a plain, non-guided translation (markers dropped; the chunk rebuilds to
    /// plain text) → the original chunk as a last resort (styles preserved, text
    /// untranslated).
    private func escalateTranslate(
        _ template: String, language: String, token: Int,
        onPartial: @escaping (String) -> Void
    ) async -> String {
        // 1) Guided streaming — markers preserved, streams token by token.
        if let result = try? await NaturalTranslator.streamTranslateBlock(
            template, into: language, domain: conceptDomain,
            onPartial: { partial in onPartial(InlineMarkupTranslator.stripMarkers(partial)) }
        ) {
            return result.translation
        }
        guard token == generation else { return template }
        // 2) Fresh guided session — still preserves markers.
        if let result = try? await NaturalTranslator.translateBlock(template, into: language, context: "", domain: conceptDomain) {
            onPartial(InlineMarkupTranslator.stripMarkers(result.translation))
            return result.translation
        }
        guard token == generation else { return template }
        // 3) Plain, non-guided translation — recovers from the echo failure mode
        // guided decoding falls into, at the cost of this chunk's inline markup.
        if let plain = await NaturalTranslator.translatePlainFallback(
            InlineMarkupTranslator.stripMarkers(template), into: language, domain: conceptDomain
        ) {
            onPartial(plain)
            return plain
        }
        // 4) Give up on this chunk; keep the original so the rest still translates.
        return template
    }

    /// Translates a nested block (inside a blockquote) without its own override.
    private func translateNested(
        _ block: HTMLContentBlock, language: String, context: String, token: Int
    ) async -> (HTMLContentBlock?, String) {
        switch block {
        case .text(let html):
            let segments = InlineMarkupTranslator.segments(html)
            var context = context
            var output = segments.map(\.raw)
            for (segmentIndex, segment) in segments.enumerated() where segment.translatable {
                guard token == generation else { return (nil, context) }
                guard let (translatedInner, newContext) = await translateFragment(segment.inner, language: language, context: context, token: token) else {
                    continue
                }
                context = newContext
                output[segmentIndex] = segment.open + translatedInner + segment.close
            }
            return (.text(output.joined()), context)
        case .heading(let level, let html):
            guard let (fragment, newContext) = await translateFragment(html, language: language, context: context, token: token) else {
                return (nil, context)
            }
            return (.heading(level: level, html: fragment), newContext)
        case .list(let ordered, let items):
            var context = context
            var translatedItems = items
            for (itemIndex, itemBlocks) in items.enumerated() {
                var translatedBlocks = itemBlocks
                for (childIndex, child) in itemBlocks.enumerated() {
                    guard token == generation else { return (nil, context) }
                    let (replacement, newContext) = await translateNested(child, language: language, context: context, token: token)
                    context = newContext
                    if let replacement {
                        translatedBlocks[childIndex] = replacement
                        translatedItems[itemIndex] = translatedBlocks
                    }
                }
            }
            return (.list(ordered: ordered, items: translatedItems), context)
        case .table(let table):
            var context = context
            var rows = table.rows
            for (rowIndex, row) in table.rows.enumerated() {
                var cells = row.cells
                for (cellIndex, cell) in row.cells.enumerated() {
                    guard token == generation else { return (nil, context) }
                    guard let (translatedCell, newContext) = await translateFragment(cell, language: language, context: context, token: token) else { continue }
                    context = newContext
                    cells[cellIndex] = translatedCell
                    rows[rowIndex] = HTMLTable.Row(cells: cells, isHeader: row.isHeader)
                }
            }
            return (.table(HTMLTable(rows: rows)), context)
        default:
            return (nil, context)
        }
    }

    /// Translates one inline fragment, preserving markup, with a plain-text
    /// fallback if the model garbled the markers. Returns nil when there's
    /// nothing translatable.
    private func translateFragment(
        _ html: String, language: String, context: String, token: Int
    ) async -> (String, String)? {
        let (template, entries) = InlineMarkupTranslator.markify(html)
        guard !InlineMarkupTranslator.stripMarkers(template).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        // Same chunking + per-chunk rebuild as the streaming path (no live
        // callback) so long cells/quotes don't overflow or echo, and one bad chunk
        // doesn't strip styles from the whole cell/quote.
        let chunks = InlineMarkupTranslator.chunk(template)
        var htmlParts: [String] = []
        for chunk in chunks {
            guard token == generation else { return nil }
            let (chunkHTML, _) = await translateChunk(chunk, entries: entries, language: language, token: token, onPartial: { _ in })
            htmlParts.append(chunkHTML)
        }
        guard token == generation else { return nil }
        return (htmlParts.joined(), "")
    }
}
