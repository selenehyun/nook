import Foundation
import Markdown

/// A translation-specific Markdown document. The model sees the whole article,
/// but every top-level block is fenced with a stable identifier so streaming
/// output can be validated and projected onto the original native block tree.
struct MarkdownTranslationTemplate: Sendable {
    static let maxBatchCharacters = 48_000
    static let formatVersion = 1

    struct Unit: Sendable, Equatable {
        let id: String
        let blockIndex: Int?
        let source: String
    }

    struct Batch: Sendable {
        let units: [Unit]
        let prompt: String
    }

    let title: String
    let baseURL: URL?
    let originalBlocks: [HTMLContentBlock]
    let units: [Unit]
    let protectedBlocks: [Int: HTMLContentBlock]
    let sourceMarkdown: String

    init(title: String, blocks: [HTMLContentBlock], baseURL: URL?) {
        self.title = title
        self.baseURL = baseURL
        self.originalBlocks = blocks

        var units: [Unit] = [
            Unit(id: "title", blockIndex: nil, source: Self.escapePlain(title)),
        ]
        var protected: [Int: HTMLContentBlock] = [:]
        var sourceParts: [String] = []

        for (index, block) in blocks.enumerated() {
            if Self.isProtected(block) {
                protected[index] = block
                sourceParts.append(Self.protectedMarker(index))
                continue
            }
            let markdown = ArticleMarkdown.render([block], baseURL: baseURL)
            guard !markdown.isEmpty else {
                protected[index] = block
                sourceParts.append(Self.protectedMarker(index))
                continue
            }
            units.append(Unit(id: "block-\(index)", blockIndex: index, source: markdown))
            sourceParts.append(markdown)
        }

        self.units = units
        self.protectedBlocks = protected
        self.sourceMarkdown = sourceParts.joined(separator: "\n\n")
    }

    var sourceIdentity: String {
        "\(Self.formatVersion)\n\(baseURL?.absoluteString ?? "")\n\(title)\n\(sourceMarkdown)"
    }

    func batches(maxCharacters: Int = maxBatchCharacters) -> [Batch] {
        var batches: [[Unit]] = []
        var current: [Unit] = []
        var currentCount = 0

        for unit in units {
            let wrapped = Self.wrapped(unit)
            if !current.isEmpty, currentCount + wrapped.count > maxCharacters {
                batches.append(current)
                current = []
                currentCount = 0
            }
            current.append(unit)
            currentCount += wrapped.count
        }
        if !current.isEmpty { batches.append(current) }

        return batches.map { units in
            Batch(units: units, prompt: units.map(Self.wrapped).joined(separator: "\n\n"))
        }
    }

    func assembledMarkdown(translations: [String: String]) -> String {
        originalBlocks.indices.map { index in
            if protectedBlocks[index] != nil { return Self.protectedMarker(index) }
            return translations["block-\(index)"]
                ?? units.first(where: { $0.blockIndex == index })?.source
                ?? ""
        }
        .filter { !$0.isEmpty }
        .joined(separator: "\n\n")
    }

    func parsedBlocks(markdown: String) -> [HTMLContentBlock]? {
        MarkdownNativeParser.blocks(
            from: markdown,
            baseURL: baseURL,
            protectedBlocks: protectedBlocks
        )
    }

    static func beginMarker(_ id: String) -> String { "<!--NOOK:BEGIN:\(id)-->" }
    static func endMarker(_ id: String) -> String { "<!--NOOK:END:\(id)-->" }
    static func protectedMarker(_ index: Int) -> String { "<!--NOOK:PROTECTED:\(index)-->" }

    private static func wrapped(_ unit: Unit) -> String {
        "\(beginMarker(unit.id))\n\(unit.source)\n\(endMarker(unit.id))"
    }

    private static func isProtected(_ block: HTMLContentBlock) -> Bool {
        switch block {
        case .codeBlock, .thematicBreak, .image, .video, .audio, .embed:
            true
        default:
            false
        }
    }

    private static func escapePlain(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "*", with: "\\*")
            .replacingOccurrences(of: "_", with: "\\_")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
            .replacingOccurrences(of: "`", with: "\\`")
    }
}

/// Extracts complete and active units from Gemini's cumulative stream snapshots.
/// Parsing is deliberately delimiter-based: an incomplete Markdown AST is never
/// trusted or rendered as formatted content.
enum MarkdownTranslationStream {
    struct Snapshot: Equatable {
        var completed: [String: String]
        var activeID: String?
        var activeText: String
        var order: [String]
        var hasDuplicate = false
    }

    static func parse(_ raw: String, expectedIDs: Set<String>) -> Snapshot {
        let text = stripOuterFence(raw)
        let beginPattern = #"<!--\s*NOOK:BEGIN:([a-zA-Z0-9-]+)\s*-->"#
        guard let regex = try? NSRegularExpression(pattern: beginPattern) else {
            return Snapshot(completed: [:], activeID: nil, activeText: "", order: [])
        }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var result = Snapshot(completed: [:], activeID: nil, activeText: "", order: [])
        var seen = Set<String>()

        for match in matches {
            guard let idRange = Range(match.range(at: 1), in: text) else { continue }
            let id = String(text[idRange])
            guard expectedIDs.contains(id) else { continue }
            if !seen.insert(id).inserted { result.hasDuplicate = true }
            result.order.append(id)

            let contentStart = match.range.location + match.range.length
            let end = MarkdownTranslationTemplate.endMarker(id)
            let searchRange = NSRange(location: contentStart, length: ns.length - contentStart)
            let endRange = ns.range(of: end, options: [], range: searchRange)
            let value: String
            if endRange.location == NSNotFound {
                value = ns.substring(from: contentStart)
                result.activeID = id
                result.activeText = cleaned(value)
            } else {
                value = ns.substring(with: NSRange(
                    location: contentStart,
                    length: endRange.location - contentStart
                ))
                result.completed[id] = cleaned(value)
            }
        }
        return result
    }

    static func plainProjection(_ markdown: String) -> String {
        markdown
            .replacingOccurrences(of: #"<!--.*?-->"#, with: "", options: [.regularExpression])
            .replacingOccurrences(of: #"!\[([^\]]*)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"(?m)^\s{0,3}(#{1,6}|>|[-+*]|\d+\.)\s+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[*_~`]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func cleaned(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripOuterFence(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```markdown") || trimmed.hasPrefix("```md") else { return value }
        guard let firstNewline = trimmed.firstIndex(of: "\n") else { return value }
        var body = String(trimmed[trimmed.index(after: firstNewline)...])
        if body.hasSuffix("```") { body.removeLast(3) }
        return body
    }
}

/// Strict validation for one translated Markdown unit.
enum MarkdownTranslationValidator {
    static func accepts(source: String, output: String, language: String) -> Bool {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !NaturalTranslator.isUntranslated(source: source, output: trimmed, languageName: language),
              !NaturalTranslator.looksRunaway(trimmed)
        else { return false }

        let sourceDocument = Document(parsing: source)
        let outputDocument = Document(parsing: trimmed)
        var sourceSignature = SignatureCollector()
        var outputSignature = SignatureCollector()
        sourceSignature.visit(sourceDocument)
        outputSignature.visit(outputDocument)

        guard sourceSignature.structure == outputSignature.structure,
              sourceSignature.links == outputSignature.links,
              sourceSignature.images == outputSignature.images,
              sourceSignature.inlineCode == outputSignature.inlineCode,
              sourceSignature.codeBlocks == outputSignature.codeBlocks,
              sourceSignature.htmlSkeleton == outputSignature.htmlSkeleton
        else { return false }

        return MarkdownNativeParser.blocks(from: trimmed, baseURL: nil, protectedBlocks: [:]) != nil
    }

    private struct SignatureCollector: MarkupWalker {
        var structure: [String] = []
        var links: [String] = []
        var images: [String] = []
        var inlineCode: [String] = []
        var codeBlocks: [String] = []
        var htmlSkeleton: [String] = []

        mutating func visitHeading(_ heading: Heading) {
            structure.append("h\(heading.level)")
            descendInto(heading)
        }

        mutating func visitBlockQuote(_ blockQuote: BlockQuote) {
            structure.append("quote")
            descendInto(blockQuote)
        }

        mutating func visitOrderedList(_ orderedList: OrderedList) {
            structure.append("ol:\(Array(orderedList.listItems).count)")
            descendInto(orderedList)
        }

        mutating func visitUnorderedList(_ unorderedList: UnorderedList) {
            structure.append("ul:\(Array(unorderedList.listItems).count)")
            descendInto(unorderedList)
        }

        mutating func visitTable(_ table: Table) {
            structure.append("table:\(table.head.childCount):\(Array(table.body.rows).count)")
            descendInto(table)
        }

        mutating func visitLink(_ link: Link) {
            links.append(link.destination ?? "")
            descendInto(link)
        }

        mutating func visitImage(_ image: Image) {
            images.append(image.source ?? "")
            descendInto(image)
        }

        mutating func visitInlineCode(_ inlineCode: InlineCode) {
            self.inlineCode.append(inlineCode.code)
        }

        mutating func visitCodeBlock(_ codeBlock: CodeBlock) {
            codeBlocks.append("\(codeBlock.language ?? "")\n\(codeBlock.code)")
        }

        mutating func visitHTMLBlock(_ html: HTMLBlock) {
            htmlSkeleton.append(Self.tags(in: html.rawHTML))
        }

        mutating func visitInlineHTML(_ inlineHTML: InlineHTML) {
            htmlSkeleton.append(Self.tags(in: inlineHTML.rawHTML))
        }

        private static func tags(in html: String) -> String {
            guard let regex = try? NSRegularExpression(pattern: #"</?[a-zA-Z][^>]*>"#) else {
                return ""
            }
            let ns = html as NSString
            return regex.matches(in: html, range: NSRange(location: 0, length: ns.length))
                .map { ns.substring(with: $0.range).lowercased() }
                .joined()
        }
    }
}

/// Parses CommonMark/GFM directly into Nook's native reader block model.
/// Inline Markdown is converted only to the safe HTML subset already consumed by
/// the native attributed-string renderer; block structure never goes through HTML.
enum MarkdownNativeParser {
    static func blocks(
        from markdown: String,
        baseURL: URL?,
        protectedBlocks: [Int: HTMLContentBlock]
    ) -> [HTMLContentBlock]? {
        let document = Document(parsing: markdown)
        var output: [HTMLContentBlock] = []
        for child in document.children {
            guard let converted = block(child, baseURL: baseURL, protectedBlocks: protectedBlocks) else {
                continue
            }
            append(converted, to: &output)
        }
        return output.isEmpty && !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil
            : output
    }

    private static func append(_ block: HTMLContentBlock, to output: inout [HTMLContentBlock]) {
        if case .text(let html) = block, case .text(let previous)? = output.last {
            output[output.count - 1] = .text(previous + html)
        } else {
            output.append(block)
        }
    }

    private static func block(
        _ markup: Markup,
        baseURL: URL?,
        protectedBlocks: [Int: HTMLContentBlock]
    ) -> HTMLContentBlock? {
        switch markup {
        case let paragraph as Paragraph:
            let children = Array(paragraph.children)
            if children.count == 1, let image = children[0] as? Image,
               let media = media(image, baseURL: baseURL) {
                return .image(media)
            }
            let html = inlineHTML(children, baseURL: baseURL)
            return html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil
                : .text("<p>\(html)</p>")

        case let heading as Heading:
            return .heading(
                level: heading.level,
                html: inlineHTML(Array(heading.children), baseURL: baseURL)
            )

        case let quote as BlockQuote:
            let inner = Array(quote.children).compactMap {
                block($0, baseURL: baseURL, protectedBlocks: protectedBlocks)
            }
            return inner.isEmpty ? nil : .blockquote(inner)

        case let list as OrderedList:
            return listBlock(
                ordered: true,
                items: Array(list.listItems),
                baseURL: baseURL,
                protectedBlocks: protectedBlocks
            )

        case let list as UnorderedList:
            return listBlock(
                ordered: false,
                items: Array(list.listItems),
                baseURL: baseURL,
                protectedBlocks: protectedBlocks
            )

        case let code as CodeBlock:
            return .codeBlock(code: code.code, language: code.language)

        case is ThematicBreak:
            return .thematicBreak

        case let table as Table:
            return .table(tableBlock(table, baseURL: baseURL))

        case let html as HTMLBlock:
            let raw = html.rawHTML.trimmingCharacters(in: .whitespacesAndNewlines)
            if raw.hasPrefix("<!--NOOK:BEGIN:") || raw.hasPrefix("<!--NOOK:END:") {
                return nil
            }
            if let index = protectedIndex(raw), let protected = protectedBlocks[index] {
                return protected
            }
            let lower = raw.lowercased()
            guard !lower.contains("<script"), !lower.contains("<style"), !lower.contains("<iframe") else {
                return nil
            }
            let parsed = HTMLContentParser.parse(raw, baseURL: baseURL)
            return parsed.count == 1 ? parsed[0] : nil

        default:
            return nil
        }
    }

    private static func listBlock(
        ordered: Bool,
        items: [ListItem],
        baseURL: URL?,
        protectedBlocks: [Int: HTMLContentBlock]
    ) -> HTMLContentBlock? {
        let converted = items.map { item in
            var blocks: [HTMLContentBlock] = []
            for child in item.children {
                if let block = block(child, baseURL: baseURL, protectedBlocks: protectedBlocks) {
                    append(block, to: &blocks)
                }
            }
            if let checkbox = item.checkbox {
                let marker = checkbox == .checked ? "☑︎ " : "☐ "
                if case .text(let html)? = blocks.first {
                    blocks[0] = .text("<p>\(marker)\(html.replacingOccurrences(of: "<p>", with: "", options: .anchored))")
                }
            }
            return blocks
        }
        return converted.isEmpty ? nil : .list(ordered: ordered, items: converted)
    }

    private static func tableBlock(_ table: Table, baseURL: URL?) -> HTMLTable {
        var rows: [HTMLTable.Row] = []
        let headerCells = table.head.children.compactMap { $0 as? Table.Cell }.map {
            HTMLTable.Cell(
                html: inlineHTML(Array($0.children), baseURL: baseURL),
                isHeader: true,
                colSpan: Int($0.colspan),
                rowSpan: Int($0.rowspan)
            )
        }
        if !headerCells.isEmpty { rows.append(HTMLTable.Row(cells: headerCells)) }
        for row in table.body.rows {
            let cells = row.children.compactMap { $0 as? Table.Cell }.map {
                HTMLTable.Cell(
                    html: inlineHTML(Array($0.children), baseURL: baseURL),
                    isHeader: false,
                    colSpan: Int($0.colspan),
                    rowSpan: Int($0.rowspan)
                )
            }
            rows.append(HTMLTable.Row(cells: cells))
        }
        return HTMLTable(rows: rows)
    }

    private static func inlineHTML(_ nodes: [Markup], baseURL: URL?) -> String {
        nodes.map { node in
            switch node {
            case let text as Markdown.Text:
                return escapeHTML(text.string)
            case is SoftBreak:
                return " "
            case is LineBreak:
                return "<br>"
            case let strong as Strong:
                return "<strong>\(inlineHTML(Array(strong.children), baseURL: baseURL))</strong>"
            case let emphasis as Emphasis:
                return "<em>\(inlineHTML(Array(emphasis.children), baseURL: baseURL))</em>"
            case let strike as Strikethrough:
                return "<del>\(inlineHTML(Array(strike.children), baseURL: baseURL))</del>"
            case let code as InlineCode:
                return "<code>\(escapeHTML(code.code))</code>"
            case let link as Link:
                let content = inlineHTML(Array(link.children), baseURL: baseURL)
                guard let destination = resolvedURL(link.destination, baseURL: baseURL, image: false) else {
                    return content
                }
                return #"<a href="\#(escapeAttribute(destination.absoluteString))">\#(content)</a>"#
            case let image as Image:
                guard let media = media(image, baseURL: baseURL) else { return "" }
                return #"<img src="\#(escapeAttribute(media.url.absoluteString))" alt="\#(escapeAttribute(media.title ?? "Image"))">"#
            case let html as InlineHTML:
                return safeInlineHTML(html.rawHTML)
            default:
                return inlineHTML(Array(node.children), baseURL: baseURL)
            }
        }.joined()
    }

    private static func media(_ image: Image, baseURL: URL?) -> HTMLMedia? {
        guard let url = resolvedURL(image.source, baseURL: baseURL, image: true) else { return nil }
        let alt = plainText(Array(image.children)).trimmingCharacters(in: .whitespacesAndNewlines)
        return HTMLMedia(
            url: url,
            title: alt.isEmpty ? image.title : alt,
            caption: nil,
            posterURL: nil,
            aspectRatio: nil
        )
    }

    private static func plainText(_ nodes: [Markup]) -> String {
        nodes.map { node in
            switch node {
            case let text as Markdown.Text: text.string
            case let code as InlineCode: code.code
            case is SoftBreak, is LineBreak: " "
            default: plainText(Array(node.children))
            }
        }.joined()
    }

    private static func resolvedURL(_ raw: String?, baseURL: URL?, image: Bool) -> URL? {
        guard let raw,
              let url = URL(string: raw, relativeTo: baseURL)?.absoluteURL,
              let scheme = url.scheme?.lowercased()
        else { return nil }
        let allowed = image ? ["http", "https"] : ["http", "https", "mailto"]
        return allowed.contains(scheme) ? url : nil
    }

    private static func protectedIndex(_ raw: String) -> Int? {
        let pattern = #"^<!--NOOK:PROTECTED:([0-9]+)-->$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: raw,
                range: NSRange(raw.startIndex..<raw.endIndex, in: raw)
              ),
              let range = Range(match.range(at: 1), in: raw)
        else { return nil }
        return Int(raw[range])
    }

    private static func safeInlineHTML(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = #"^</?(u|mark|sub|sup|kbd)>$"#
        guard trimmed.range(of: allowed, options: [.regularExpression, .caseInsensitive]) != nil else {
            return escapeHTML(raw)
        }
        return trimmed
    }

    private static func escapeHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func escapeAttribute(_ value: String) -> String {
        escapeHTML(value)
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
