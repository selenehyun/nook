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
        template.replacingOccurrences(
            of: "\u{27E6}[=/]?[0-9]+\u{27E7}", with: "", options: .regularExpression
        )
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
    }

    private func run(title: String, blocks: [HTMLContentBlock], language: String, token: Int) async {
        var context = ""

        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty,
           let result = try? await NaturalTranslator.translateBlock(trimmedTitle, into: language, context: context) {
            guard token == generation else { return }
            context = result.context
            translatedTitle = InlineMarkupTranslator.stripMarkers(result.translation)
        }

        for (index, block) in blocks.enumerated() {
            guard token == generation, !Task.isCancelled else { return }
            guard let (translated, newContext) = await translate(block, language: language, context: context, token: token) else {
                continue
            }
            guard token == generation else { return }
            context = newContext
            overrides[index] = translated
        }

        if token == generation { isTranslating = false }
    }

    /// Translates one block, returning the replacement and the updated context.
    /// Returns nil for non-translatable blocks (rendered as-is).
    private func translate(
        _ block: HTMLContentBlock, language: String, context: String, token: Int
    ) async -> (HTMLContentBlock, String)? {
        switch block {
        case .text(let html):
            guard let (fragment, newContext) = await translateFragment(html, language: language, context: context, token: token) else {
                return nil
            }
            return (.text(fragment), newContext)
        case .heading(let level, let html):
            guard let (fragment, newContext) = await translateFragment(html, language: language, context: context, token: token) else {
                return nil
            }
            return (.heading(level: level, html: fragment), newContext)
        case .blockquote(let inner):
            var context = context
            var translatedInner: [HTMLContentBlock] = []
            translatedInner.reserveCapacity(inner.count)
            for child in inner {
                if let (translatedChild, newContext) = await translate(child, language: language, context: context, token: token) {
                    context = newContext
                    translatedInner.append(translatedChild)
                } else {
                    translatedInner.append(child)
                }
            }
            return (.blockquote(translatedInner), context)
        default:
            return nil   // code, tables, media, rules: keep the original
        }
    }

    /// Translates one HTML fragment preserving inline markup, with a plain-text
    /// fallback if the model garbled the markers.
    private func translateFragment(
        _ html: String, language: String, context: String, token: Int
    ) async -> (String, String)? {
        let (template, entries) = InlineMarkupTranslator.markify(html)
        guard !InlineMarkupTranslator.stripMarkers(template).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        guard let result = try? await NaturalTranslator.translateBlock(template, into: language, context: context) else {
            return nil
        }
        guard token == generation else { return nil }
        let rebuilt = InlineMarkupTranslator.rebuild(result.translation, entries: entries)
            ?? InlineMarkupTranslator.plainFallback(result.translation)
        return (rebuilt, result.context)
    }
}
