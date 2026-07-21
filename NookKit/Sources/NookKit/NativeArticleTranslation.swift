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
    // The small model sometimes rewrites the ⟦…⟧ delimiters into braces or CJK
    // brackets (e.g. "{1}", "{=0}", "【/2】"). Recover those to the canonical form
    // before rebuilding/stripping so a mangled marker restores (or is removed)
    // instead of leaking into the text.
    // Braces, CJK brackets, and the not-sign the model substitutes for ⟦/⟧ —
    // not "[1]", which is a legitimate citation.
    private static let mangledMarkerRegex = try! NSRegularExpression(
        pattern: "[{【〔\u{00AC}]\\s*(=|/)?\\s*([0-9]+)\\s*[}】〕\u{00AC}]"
    )
    // Any residual marker-delimiter character that never belongs in translated
    // prose, left over after a marker was mangled beyond recovery.
    private static let strayMarkerChars = "[\u{27E6}\u{27E7}\u{00AC}]"

    /// Canonicalizes marker delimiters the model may have altered back to ⟦…⟧.
    static func normalizeMarkers(_ s: String) -> String {
        let ns = s as NSString
        return mangledMarkerRegex.stringByReplacingMatches(
            in: s, range: NSRange(location: 0, length: ns.length), withTemplate: "\u{27E6}$1$2\u{27E7}"
        )
    }

    /// Final safety net: removes any leftover marker-delimiter characters (⟦ ⟧ ¬)
    /// that survived rebuild — so a marker the model mangled beyond recovery never
    /// shows in the reader.
    static func sanitizeResidualMarkers(_ s: String) -> String {
        s.replacingOccurrences(of: strayMarkerChars, with: "", options: .regularExpression)
    }
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
        // Recover any marker delimiters the model rewrote (e.g. "{1}" → "⟦1⟧") so
        // a lightly-mangled result still rebuilds instead of leaking braces.
        let template = normalizeMarkers(template)
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
        return normalizeMarkers(template)
            .replacingOccurrences(of: "\u{27E6}[=/]?[0-9]+\u{27E7}", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\u{27E6}[=/]?[0-9]*\u{27E7}?", with: "", options: .regularExpression)
            .replacingOccurrences(of: strayMarkerChars, with: "", options: .regularExpression)
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
    /// Article-wide glossary of names/terms to keep verbatim (proper nouns, brands,
    /// technical terms), grown block-by-block as translation proceeds so every
    /// block is translated against every term seen so far.
    private var keepTerms: [String] = []
    /// Lowercased keys of `keepTerms` for O(1) de-duplication across blocks.
    private var keepTermsSeen: Set<String> = []

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
        keepTerms = []
        keepTermsSeen = []
    }

    private func run(title: String, blocks: [HTMLContentBlock], language: String, token: Int) async {
        var context = ""

        // Detect the article's subject up front so each block is translated with
        // field-appropriate terminology (best-effort; empty if unavailable).
        conceptDomain = await NaturalTranslator.detectConcept(from: conceptSample(title: title, blocks: blocks, limit: 1200)) ?? ""
        guard token == generation else { return }

        // Seed the keep-verbatim glossary from the title; it then grows per block
        // below, before each block is translated.
        mergeKeepTerms(await NaturalTranslator.detectKeepTerms(from: title))
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
            // Extract this block's keep-verbatim terms and add them to the glossary
            // BEFORE translating it, so the block (and every later one) is
            // translated against the full accumulated glossary.
            await accumulateKeepTerms(from: block, token: token)
            guard token == generation, !Task.isCancelled else { return }
            context = await translate(block, at: index, language: language, context: context, token: token)
        }

        if token == generation { isTranslating = false }
    }

    /// Extracts the keep-verbatim terms from one block's source text and folds them
    /// into the running glossary before that block is translated.
    private func accumulateKeepTerms(from block: HTMLContentBlock, token: Int) async {
        let text = blockPlainText(block).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let terms = await NaturalTranslator.detectKeepTerms(from: text)
        guard token == generation else { return }
        mergeKeepTerms(terms)
    }

    /// De-duplicates (case-insensitively) new terms into the ordered glossary,
    /// capped so the instruction stays bounded.
    private func mergeKeepTerms(_ new: [String]) {
        for term in new {
            let key = term.lowercased()
            guard !keepTermsSeen.contains(key) else { continue }
            keepTermsSeen.insert(key)
            keepTerms.append(term)
        }
        if keepTerms.count > 120 { keepTerms = Array(keepTerms.prefix(120)) }
    }

    /// Plain, tag-stripped text of a block including its nested content, for
    /// term extraction.
    private func blockPlainText(_ block: HTMLContentBlock) -> String {
        switch block {
        case .text(let html):
            return plainText(html)
        case .heading(_, let html):
            return plainText(html)
        case .blockquote(let inner):
            return inner.map(blockPlainText).joined(separator: " ")
        case .list(_, let items):
            return items.flatMap { $0 }.map(blockPlainText).joined(separator: " ")
        case .table(let table):
            return table.rows.flatMap(\.cells).map(plainText).joined(separator: " ")
        default:
            return ""
        }
    }

    /// A short plain-text sample (title + leading prose) used to detect the
    /// article's subject/field. Bounded so concept detection stays cheap.
    private func conceptSample(title: String, blocks: [HTMLContentBlock], limit: Int) -> String {
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
            if parts.reduce(0, { $0 + $1.count }) > limit { break }
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
            return await translateTextBlock(html, at: index, headingLevel: nil, language: language, context: context, token: token)
        case .heading(let level, let html):
            return await translateTextBlock(html, at: index, headingLevel: level, language: language, context: context, token: token)
        case .blockquote(let inner):
            var context = context
            var translatedInner = inner
            for (childIndex, child) in inner.enumerated() {
                guard token == generation else { return context }
                let (replacement, newContext) = await translateNested(
                    child, language: language, context: context, token: token,
                    onPartial: { [self] childBlock in
                        guard token == generation else { return }
                        var live = translatedInner
                        live[childIndex] = childBlock
                        overrides[index] = .blockquote(live)
                    }
                )
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
                    let (replacement, newContext) = await translateNested(
                        child, language: language, context: context, token: token,
                        onPartial: { [self] childBlock in
                            guard token == generation else { return }
                            var liveBlocks = translatedBlocks
                            liveBlocks[childIndex] = childBlock
                            var liveItems = translatedItems
                            liveItems[itemIndex] = liveBlocks
                            overrides[index] = .list(ordered: ordered, items: liveItems)
                        }
                    )
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

    /// Translates a top-level `.text`/`.heading` block, streaming into its own
    /// override so it fills in top-to-bottom, then settling to the final block.
    private func translateTextBlock(
        _ html: String,
        at index: Int,
        headingLevel: Int?,
        language: String,
        context: String,
        token: Int
    ) async -> String {
        let (settled, newContext) = await streamTextBlock(
            html, headingLevel: headingLevel, language: language, context: context, token: token,
            emit: { [self] partial in overrides[index] = partial }
        )
        guard token == generation else { return newContext }
        // Collapse to the final single block so the settled layout/import path is
        // identical to a non-streamed translation.
        overrides[index] = settled
        return newContext
    }

    /// Streams a `.text`/`.heading` fragment segment-by-segment, emitting each
    /// intermediate `.mixedText` via `emit` — so a top-level block (writing its own
    /// override) and a nested one inside a quote/list (rebuilding its parent) get
    /// the identical typing/caret/overlay effect — and returns the settled block.
    /// `headingLevel` (non-nil for a heading) is carried on the streamed
    /// `.mixedText` so it renders at the heading's size/weight while typing, not as
    /// body text.
    private func streamTextBlock(
        _ html: String,
        headingLevel: Int?,
        language: String,
        context: String,
        token: Int,
        emit: @escaping (HTMLContentBlock) -> Void
    ) async -> (HTMLContentBlock, String) {
        var context = context
        let segments = InlineMarkupTranslator.segments(html)
        var output = segments.map(\.raw)
        func settledBlock() -> HTMLContentBlock {
            let joined = output.joined()
            return headingLevel.map { .heading(level: $0, html: joined) } ?? .text(joined)
        }
        func mixed(activeIndex: Int, activePartial: String) -> HTMLContentBlock {
            .mixedText(parts: mixedParts(output: output, activeIndex: activeIndex, activePartial: activePartial), headingLevel: headingLevel)
        }
        for (segmentIndex, segment) in segments.enumerated() where segment.translatable {
            guard token == generation else { return (settledBlock(), context) }
            let active = segmentIndex
            // Caret at the segment start the moment translation begins — before the
            // first token — so it's clear which block is being translated.
            emit(mixed(activeIndex: active, activePartial: ""))
            // Stream this segment token-by-token: the active segment overlays and
            // erases its dimmed original while the others stay rendered as HTML.
            let result = await translateFragmentStreaming(
                segment.inner, language: language, context: context, token: token
            ) { partial in
                guard token == self.generation else { return }
                emit(mixed(activeIndex: active, activePartial: partial))
            }
            guard let (translatedInner, newContext) = result else { continue }
            context = newContext
            output[segmentIndex] = segment.open + translatedInner + segment.close
            guard token == generation else { return (settledBlock(), context) }
            // Settle the finished segment; the next one re-emits.
            emit(mixed(activeIndex: -1, activePartial: ""))
        }
        return (settledBlock(), context)
    }

    /// Builds the streaming block's parts: the active segment lays its dimmed
    /// original text under the streaming translation (`.streaming`), which types on
    /// top and erases the original as it grows — so the block never blanks and the
    /// translation overlays it in place — while every other non-empty segment
    /// renders as its HTML.
    private func mixedParts(output: [String], activeIndex: Int, activePartial: String) -> [HTMLContentBlock.TextPart] {
        var parts: [HTMLContentBlock.TextPart] = []
        for (i, segment) in output.enumerated() {
            if i == activeIndex {
                parts.append(.streaming(original: plainText(segment), text: activePartial))
            } else if !segment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                parts.append(.html(segment))
            }
        }
        return parts
    }

    /// Plain, tag-stripped text of an original HTML segment, for the dimmed
    /// underlay behind the streaming translation.
    private func plainText(_ html: String) -> String {
        HTMLContentParser.decodeEntities(
            html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        )
        .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
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
        // A valid rebuild leaves no markers, but a stray delimiter the model
        // emitted as text (e.g. a lone "¬") can still slip through — clean it.
        let html = InlineMarkupTranslator.sanitizeResidualMarkers(
            InlineMarkupTranslator.rebuild(translated, entries: localEntries)
                ?? InlineMarkupTranslator.plainFallback(translated)
        )
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
            template, into: language, domain: conceptDomain, keepTerms: keepTerms,
            onPartial: { partial in onPartial(InlineMarkupTranslator.stripMarkers(partial)) }
        ) {
            return result.translation
        }
        guard token == generation else { return template }
        // 2) Fresh guided streaming — a new session usually escapes a repetition
        // loop or echo the first attempt hit, and streams so it types in and can
        // be aborted early if it too runs away.
        if let result = try? await NaturalTranslator.streamTranslateBlock(
            template, into: language, domain: conceptDomain, keepTerms: keepTerms,
            onPartial: { partial in onPartial(InlineMarkupTranslator.stripMarkers(partial)) }
        ) {
            return result.translation
        }
        guard token == generation else { return template }
        // 3) Plain, non-guided translation — recovers from the echo failure mode
        // guided decoding falls into, at the cost of this chunk's inline markup.
        if let plain = await NaturalTranslator.translatePlainFallback(
            InlineMarkupTranslator.stripMarkers(template), into: language, domain: conceptDomain, keepTerms: keepTerms
        ) {
            await paceEmit(plain, onPartial: onPartial, token: token)
            return plain
        }
        // 4) Give up on this chunk; keep the original so the rest still translates.
        return template
    }

    /// Emits `text` as growing prefixes over time so a bulk (non-streamed)
    /// translation types in visibly instead of appearing all at once. Runs before
    /// the caller returns, so the block doesn't settle until it has played — the
    /// fix for a later block suddenly swapping whole when it escalates off the
    /// token-streaming path. Clears within ~1.2s but never slower than ~70 chars/s.
    private func paceEmit(_ text: String, onPartial: @escaping (String) -> Void, token: Int) async {
        let chars = Array(text)
        guard !chars.isEmpty else { return }
        var shown = 0
        while shown < chars.count {
            guard token == generation else { return }
            let backlog = chars.count - shown
            let charsPerSecond = max(70.0, Double(backlog) / 1.2)
            let step = max(1, Int((charsPerSecond * 0.016).rounded()))
            shown = min(chars.count, shown + step)
            onPartial(String(chars[0..<shown]))
            try? await Task.sleep(nanoseconds: 16_000_000)
            if Task.isCancelled { return }
        }
    }

    /// Translates a nested block (inside a quote/list). `onPartial` receives the
    /// child's intermediate states so the parent can rebuild its override live,
    /// giving nested text the same streaming/caret/overlay effect as a top-level
    /// block instead of popping in all at once.
    private func translateNested(
        _ block: HTMLContentBlock, language: String, context: String, token: Int,
        onPartial: @escaping (HTMLContentBlock) -> Void
    ) async -> (HTMLContentBlock?, String) {
        switch block {
        case .text(let html):
            let (settled, newContext) = await streamTextBlock(
                html, headingLevel: nil, language: language, context: context, token: token, emit: onPartial
            )
            return (settled, newContext)
        case .heading(let level, let html):
            let (settled, newContext) = await streamTextBlock(
                html, headingLevel: level, language: language, context: context, token: token, emit: onPartial
            )
            return (settled, newContext)
        case .list(let ordered, let items):
            var context = context
            var translatedItems = items
            for (itemIndex, itemBlocks) in items.enumerated() {
                var translatedBlocks = itemBlocks
                for (childIndex, child) in itemBlocks.enumerated() {
                    guard token == generation else { return (nil, context) }
                    let (replacement, newContext) = await translateNested(
                        child, language: language, context: context, token: token,
                        onPartial: { childBlock in
                            var liveBlocks = translatedBlocks
                            liveBlocks[childIndex] = childBlock
                            var liveItems = translatedItems
                            liveItems[itemIndex] = liveBlocks
                            onPartial(.list(ordered: ordered, items: liveItems))
                        }
                    )
                    context = newContext
                    if let replacement {
                        translatedBlocks[childIndex] = replacement
                        translatedItems[itemIndex] = translatedBlocks
                        onPartial(.list(ordered: ordered, items: translatedItems))
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
                    onPartial(.table(HTMLTable(rows: rows)))
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
