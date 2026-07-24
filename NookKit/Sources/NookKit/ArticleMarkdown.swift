import Foundation
import SwiftUI
import UniformTypeIdentifiers

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

public extension UTType {
    /// Markdown is not exposed as a built-in `UTType` on every supported SDK.
    static var nookMarkdown: UTType {
        UTType(importedAs: "net.daringfireball.markdown", conformingTo: .plainText)
    }
}

/// Converts the native reader's parsed block model into portable Markdown.
/// Using the same parser as `HTMLContentView` keeps copying/exporting aligned
/// with what the reader can actually display.
public enum ArticleMarkdown {
    public static func convert(html: String, baseURL: URL? = nil) -> String {
        let blocks: [HTMLContentBlock]
        if let cached = HTMLBlockCache.shared.blocks(html: html, baseURL: baseURL) {
            blocks = cached
        } else {
            blocks = HTMLContentParser.parse(html, baseURL: baseURL)
            HTMLBlockCache.shared.store(blocks, html: html, baseURL: baseURL)
        }
        return render(blocks, baseURL: baseURL)
    }

    public static func convert(paragraphs: [String]) -> String {
        paragraphs
            .map { escapePlainText($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func render(_ blocks: [HTMLContentBlock], baseURL: URL?) -> String {
        blocks
            .compactMap { block($0, baseURL: baseURL) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func block(_ block: HTMLContentBlock, baseURL: URL?) -> String? {
        switch block {
        case .text(let html):
            return inline(html, baseURL: baseURL)
        case .heading(let level, let html):
            let text = inline(html, baseURL: baseURL)
            return text.isEmpty ? nil : "\(String(repeating: "#", count: min(6, max(1, level)))) \(text)"
        case .blockquote(let blocks):
            let content = render(blocks, baseURL: baseURL)
            guard !content.isEmpty else { return nil }
            return content
                .components(separatedBy: "\n")
                .map { $0.isEmpty ? ">" : "> \($0)" }
                .joined(separator: "\n")
        case .codeBlock(let code, let language):
            return fencedCode(code, language: language)
        case .table(let table):
            return markdownTable(table, baseURL: baseURL)
        case .thematicBreak:
            return "---"
        case .list(let ordered, let items):
            return markdownList(ordered: ordered, items: items, baseURL: baseURL)
        case .image(let media):
            let alt = media.title ?? media.caption ?? "Image"
            return mediaMarkdown("![\(escapeLabel(alt))](<\(media.url.absoluteString)>)", caption: media.caption, title: media.title)
        case .video(let media):
            let label = media.title ?? media.caption ?? "Video"
            if let posterURL = media.posterURL {
                let linkedPoster = "[![\(escapeLabel(label))](<\(posterURL.absoluteString)>)](<\(media.url.absoluteString)>)"
                return mediaMarkdown(linkedPoster, caption: media.caption, title: media.title)
            }
            return mediaMarkdown("[\(escapeLabel(label))](<\(media.url.absoluteString)>)", caption: media.caption, title: media.title)
        case .audio(let media):
            let label = media.title ?? media.caption ?? "Audio"
            return mediaMarkdown("[Audio: \(escapeLabel(label))](<\(media.url.absoluteString)>)", caption: media.caption, title: media.title)
        case .embed(let media):
            let label = media.title ?? media.caption ?? "Embedded content"
            return mediaMarkdown("[\(escapeLabel(label))](<\(media.url.absoluteString)>)", caption: media.caption, title: media.title)
        case .mixedText(let parts, _):
            let text = parts.map { part in
                switch part {
                case .html(let html):
                    inlineFragment(html, baseURL: baseURL)
                case .streaming(_, let text):
                    escapePlainText(text)
                case .streamingMarkdown(_, let markdown):
                    markdown
                }
            }.joined()
            return normalizeInline(text)
        }
    }

    private static func markdownList(ordered: Bool, items: [[HTMLContentBlock]], baseURL: URL?) -> String {
        items.enumerated().compactMap { index, blocks -> String? in
            let content = render(blocks, baseURL: baseURL)
            guard !content.isEmpty else { return nil }
            let marker = ordered ? "\(index + 1). " : "- "
            let continuation = String(repeating: " ", count: marker.count)
            let lines = content.components(separatedBy: "\n")
            return lines.enumerated().map { lineIndex, line in
                if lineIndex == 0 { return marker + line }
                return line.isEmpty ? continuation : continuation + line
            }.joined(separator: "\n")
        }.joined(separator: "\n")
    }

    private static func fencedCode(_ code: String, language: String?) -> String {
        let maxBackticks = maximumBacktickRun(in: code)
        let fence = String(repeating: "`", count: max(3, maxBackticks + 1))
        let safeLanguage = language?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"[`\s]+"#, with: "", options: .regularExpression) ?? ""
        return "\(fence)\(safeLanguage)\n\(code)\n\(fence)"
    }

    private static func maximumBacktickRun(in value: String) -> Int {
        var current = 0
        var maximum = 0
        for character in value {
            if character == "`" {
                current += 1
                maximum = max(maximum, current)
            } else {
                current = 0
            }
        }
        return maximum
    }

    private static func markdownTable(_ table: HTMLTable, baseURL: URL?) -> String? {
        guard !table.rows.isEmpty else { return nil }
        let hasSpans = table.rows.contains { row in
            row.cells.contains { $0.colSpan > 1 || $0.rowSpan > 1 }
        }
        if hasSpans {
            return htmlTable(table, baseURL: baseURL)
        }

        let width = table.rows.map(\.cells.count).max() ?? 0
        guard width > 0 else { return nil }
        let firstRowIsHeader = table.rows[0].cells.contains(where: { $0.isHeader })
        let header = firstRowIsHeader
            ? paddedCells(table.rows[0], width: width, baseURL: baseURL)
            : Array(repeating: "", count: width)
        var lines = [
            "| \(header.joined(separator: " | ")) |",
            "| \(Array(repeating: "---", count: width).joined(separator: " | ")) |",
        ]
        for (index, row) in table.rows.enumerated() where !firstRowIsHeader || index != 0 {
            let cells = paddedCells(row, width: width, baseURL: baseURL)
            lines.append("| \(cells.joined(separator: " | ")) |")
        }
        return lines.joined(separator: "\n")
    }

    private static func paddedCells(_ row: HTMLTable.Row, width: Int, baseURL: URL?) -> [String] {
        var cells = row.cells.map {
            inline($0.html, baseURL: baseURL)
                .replacingOccurrences(of: "\n\n", with: "<br><br>")
                .replacingOccurrences(of: "\n", with: "<br>")
                .replacingOccurrences(of: "|", with: "\\|")
        }
        cells.append(contentsOf: repeatElement("", count: max(0, width - cells.count)))
        return cells
    }

    /// Pipe tables cannot express row/column spans. Raw HTML is valid Markdown,
    /// so span-bearing tables use it instead of silently changing their shape.
    private static func htmlTable(_ table: HTMLTable, baseURL: URL?) -> String {
        var lines = ["<table>"]
        for row in table.rows {
            lines.append("  <tr>")
            for cell in row.cells {
                let tag = cell.isHeader ? "th" : "td"
                var attributes = ""
                if cell.colSpan > 1 { attributes += " colspan=\"\(cell.colSpan)\"" }
                if cell.rowSpan > 1 { attributes += " rowspan=\"\(cell.rowSpan)\"" }
                let content = safeInlineHTML(cell.html, baseURL: baseURL)
                lines.append("    <\(tag)\(attributes)>\(content)</\(tag)>")
            }
            lines.append("  </tr>")
        }
        lines.append("</table>")
        return lines.joined(separator: "\n")
    }

    private static func mediaMarkdown(_ markdown: String, caption: String?, title: String?) -> String {
        guard let caption, !caption.isEmpty, caption != title else { return markdown }
        return "\(markdown)\n\n*\(escapeEmphasis(caption))*"
    }

    // MARK: - Inline HTML

    private indirect enum InlineNode {
        case text(String)
        case element(tag: String, attributes: [String: String], children: [InlineNode])
    }

    private final class InlineBuilder {
        let tag: String
        let attributes: [String: String]
        var children: [InlineNode] = []

        init(tag: String, attributes: [String: String] = [:]) {
            self.tag = tag
            self.attributes = attributes
        }

        var node: InlineNode {
            .element(tag: tag, attributes: attributes, children: children)
        }
    }

    private static let voidTags: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr",
    ]

    private static func inline(_ html: String, baseURL: URL?) -> String {
        normalizeInline(inlineFragment(html, baseURL: baseURL))
    }

    private static func inlineFragment(_ html: String, baseURL: URL?) -> String {
        let root = parseInlineHTML(html)
        return root.children.map { markdown($0, baseURL: baseURL) }.joined()
    }

    private static func safeInlineHTML(_ html: String, baseURL: URL?) -> String {
        let root = parseInlineHTML(html)
        return root.children.map { safeHTML($0, baseURL: baseURL) }.joined()
    }

    private static func parseInlineHTML(_ html: String) -> InlineBuilder {
        let root = InlineBuilder(tag: "root")
        var stack = [root]
        var cursor = html.startIndex

        while cursor < html.endIndex {
            guard html[cursor] == "<" else {
                let next = html[cursor...].firstIndex(of: "<") ?? html.endIndex
                stack.last?.children.append(.text(String(html[cursor..<next])))
                cursor = next
                continue
            }

            if html[cursor...].hasPrefix("<!--") {
                if let end = html[cursor...].range(of: "-->")?.upperBound {
                    cursor = end
                    continue
                }
                break
            }

            guard let tagEnd = closingAngle(in: html, from: cursor) else {
                stack.last?.children.append(.text(String(html[cursor...])))
                break
            }
            let tokenEnd = html.index(after: tagEnd)
            let token = String(html[cursor..<tokenEnd])
            cursor = tokenEnd

            if token.hasPrefix("<!") || token.hasPrefix("<?") { continue }
            if token.hasPrefix("</") {
                let name = parsedTagName(token)
                guard let match = stack.lastIndex(where: { $0.tag == name }), match > 0 else { continue }
                while stack.count - 1 >= match {
                    let completed = stack.removeLast()
                    stack.last?.children.append(completed.node)
                }
                continue
            }

            let name = parsedTagName(token)
            guard !name.isEmpty else {
                stack.last?.children.append(.text(token))
                continue
            }
            let builder = InlineBuilder(tag: name, attributes: parsedAttributes(token))
            if voidTags.contains(name) || token.dropLast().trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("/") {
                stack.last?.children.append(builder.node)
            } else {
                stack.append(builder)
            }
        }

        while stack.count > 1 {
            let completed = stack.removeLast()
            stack.last?.children.append(completed.node)
        }
        return root
    }

    private static func closingAngle(in html: String, from start: String.Index) -> String.Index? {
        var quote: Character?
        var index = html.index(after: start)
        while index < html.endIndex {
            let character = html[index]
            if let activeQuote = quote {
                if character == activeQuote { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == ">" {
                return index
            }
            index = html.index(after: index)
        }
        return nil
    }

    private static func parsedTagName(_ token: String) -> String {
        let pattern = token.hasPrefix("</") ? #"^</\s*([a-zA-Z][\w:-]*)"# : #"^<\s*([a-zA-Z][\w:-]*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: token, range: NSRange(token.startIndex..<token.endIndex, in: token)),
              let range = Range(match.range(at: 1), in: token) else { return "" }
        return token[range].lowercased()
    }

    private static func parsedAttributes(_ token: String) -> [String: String] {
        guard let regex = try? NSRegularExpression(
            pattern: #"([a-zA-Z_:][\w:.-]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+))"#
        ) else { return [:] }
        let range = NSRange(token.startIndex..<token.endIndex, in: token)
        var result: [String: String] = [:]
        for match in regex.matches(in: token, range: range) {
            guard let nameRange = Range(match.range(at: 1), in: token) else { continue }
            let name = token[nameRange].lowercased()
            for group in 2..<match.numberOfRanges where match.range(at: group).location != NSNotFound {
                if let valueRange = Range(match.range(at: group), in: token) {
                    result[name] = HTMLContentParser.decodeEntities(String(token[valueRange]))
                    break
                }
            }
        }
        return result
    }

    private static func markdown(_ node: InlineNode, baseURL: URL?) -> String {
        switch node {
        case .text(let text):
            let collapsed = HTMLContentParser.decodeEntities(text)
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            return escapePlainText(collapsed)
        case .element(let tag, let attributes, let children):
            if tag == "script" || tag == "style" || tag == "noscript" { return "" }
            let content = children.map { markdown($0, baseURL: baseURL) }.joined()
            switch tag {
            case "root", "span", "font", "small", "big", "abbr", "cite", "time":
                return content
            case "p", "div", "section", "article", "header", "footer", "main", "aside", "nav", "address", "details", "summary":
                return content + "\n\n"
            case "br":
                return "  \n"
            case "strong", "b":
                return wrapped(content, marker: "**")
            case "em", "i":
                return wrapped(content, marker: "*")
            case "del", "s", "strike":
                return wrapped(content, marker: "~~")
            case "code":
                return inlineCode(plainText(children))
            case "a":
                guard let rawURL = attributes["href"],
                      let url = resolvedURL(rawURL, baseURL: baseURL) else { return content }
                let label = content.trimmingCharacters(in: .whitespacesAndNewlines)
                let title = attributes["title"].map { " \"\(escapeTitle($0))\"" } ?? ""
                return "[\(label.isEmpty ? escapeLabel(url.absoluteString) : label)](<\(url.absoluteString)>\(title))"
            case "img":
                guard let rawURL = attributes["src"] ?? attributes["data-src"] ?? attributes["data-lazy-src"],
                      let url = resolvedURL(rawURL, baseURL: baseURL) else { return "" }
                let alt = attributes["alt"] ?? attributes["title"] ?? "Image"
                let title = attributes["title"].map { " \"\(escapeTitle($0))\"" } ?? ""
                return "![\(escapeLabel(alt))](<\(url.absoluteString)>\(title))"
            case "u", "mark", "sub", "sup", "kbd":
                return "<\(tag)>\(content)</\(tag)>"
            case "q":
                return "\"\(content)\""
            case "wbr":
                return ""
            default:
                return content
            }
        }
    }

    /// Span-bearing tables use raw HTML because Markdown pipe tables cannot
    /// represent spans. Rebuild only the safe inline subset so formatting and
    /// links survive without carrying scripts or arbitrary source attributes.
    private static func safeHTML(_ node: InlineNode, baseURL: URL?) -> String {
        switch node {
        case .text(let value):
            let collapsed = HTMLContentParser.decodeEntities(value)
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            return htmlEscaped(collapsed)
        case .element(let tag, let attributes, let children):
            if tag == "script" || tag == "style" || tag == "noscript" { return "" }
            let content = children.map { safeHTML($0, baseURL: baseURL) }.joined()
            switch tag {
            case "strong", "b":
                return "<strong>\(content)</strong>"
            case "em", "i":
                return "<em>\(content)</em>"
            case "del", "s", "strike":
                return "<del>\(content)</del>"
            case "code":
                return "<code>\(htmlEscaped(plainText(children)))</code>"
            case "a":
                guard let rawURL = attributes["href"],
                      let url = resolvedURL(rawURL, baseURL: baseURL) else { return content }
                return #"<a href="\#(htmlAttributeEscaped(url.absoluteString))">\#(content)</a>"#
            case "img":
                guard let rawURL = attributes["src"] ?? attributes["data-src"] ?? attributes["data-lazy-src"],
                      let url = resolvedURL(rawURL, baseURL: baseURL) else { return "" }
                let alt = htmlAttributeEscaped(attributes["alt"] ?? attributes["title"] ?? "Image")
                return #"<img src="\#(htmlAttributeEscaped(url.absoluteString))" alt="\#(alt)">"#
            case "br":
                return "<br>"
            case "u", "mark", "sub", "sup", "kbd":
                return "<\(tag)>\(content)</\(tag)>"
            case "p", "div", "section", "article":
                return content + "<br><br>"
            default:
                return content
            }
        }
    }

    private static func plainText(_ nodes: [InlineNode]) -> String {
        nodes.map { node in
            switch node {
            case .text(let value):
                HTMLContentParser.decodeEntities(value)
            case .element(let tag, _, let children):
                tag == "br" ? "\n" : plainText(children)
            }
        }.joined()
    }

    private static func resolvedURL(_ raw: String, baseURL: URL?) -> URL? {
        guard let url = URL(string: raw, relativeTo: baseURL)?.absoluteURL,
              let scheme = url.scheme?.lowercased(),
              ["http", "https", "mailto"].contains(scheme) else { return nil }
        return url
    }

    private static func wrapped(_ content: String, marker: String) -> String {
        let leading = content.prefix { $0.isWhitespace }
        let trailing = content.dropFirst(leading.count).reversed().prefix { $0.isWhitespace }.reversed()
        let coreStart = content.index(content.startIndex, offsetBy: leading.count)
        let coreEnd = content.index(content.endIndex, offsetBy: -trailing.count)
        let core = content[coreStart..<coreEnd]
        guard !core.isEmpty else { return content }
        return "\(leading)\(marker)\(core)\(marker)\(String(trailing))"
    }

    private static func inlineCode(_ value: String) -> String {
        let fence = String(repeating: "`", count: maximumBacktickRun(in: value) + 1)
        let padding = value.hasPrefix("`") || value.hasSuffix("`") || value.hasPrefix(" ") || value.hasSuffix(" ") ? " " : ""
        return "\(fence)\(padding)\(value)\(padding)\(fence)"
    }

    private static func normalizeInline(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"[ \t]+\n\n"#, with: "\n\n", options: .regularExpression)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func escapePlainText(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "*", with: "\\*")
            .replacingOccurrences(of: "_", with: "\\_")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
            .replacingOccurrences(of: "`", with: "\\`")
    }

    private static func escapeLabel(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
    }

    private static func escapeTitle(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func escapeEmphasis(_ value: String) -> String {
        value.replacingOccurrences(of: "*", with: "\\*").replacingOccurrences(of: "_", with: "\\_")
    }

    private static func htmlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func htmlAttributeEscaped(_ value: String) -> String {
        htmlEscaped(value)
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}

public extension ReaderStore {
    /// Markdown for the body the native reader resolves for this article. Reader
    /// extraction wins only when that surface is enabled (or explicitly saved
    /// offline); otherwise the feed-provided HTML/plain paragraphs are exported.
    func nativeReaderMarkdown(for article: Article) -> String {
        if usesReaderContentByDefault || isOfflineSaved(article.id),
           case .ready(let html) = readerContentState(for: article) {
            return ArticleMarkdown.convert(html: html, baseURL: article.url)
        }
        if let html = article.contentHTML {
            return ArticleMarkdown.convert(html: html, baseURL: article.url)
        }
        return ArticleMarkdown.convert(paragraphs: article.bodyParagraphs)
    }
}

public struct MarkdownDocument: FileDocument {
    public static var readableContentTypes: [UTType] { [.nookMarkdown] }
    public static var writableContentTypes: [UTType] { [.nookMarkdown] }

    public var text: String

    public init(text: String) {
        self.text = text
    }

    public init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.text = text
    }

    public func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

/// The reader's share control: keeps ordinary URL sharing, and adds Markdown
/// clipboard and file export actions behind the same familiar share button.
public struct ArticleShareMenu<MenuLabel: View>: View {
    private let articleURL: URL
    private let title: String
    private let markdown: () -> String
    private let label: (Bool) -> MenuLabel

    @State private var isExporting = false
    @State private var copied = false
    @State private var exportDocument: MarkdownDocument?
    @State private var exportError: String?

    public init(
        articleURL: URL,
        title: String,
        markdown: @escaping () -> String,
        @ViewBuilder label: @escaping (Bool) -> MenuLabel
    ) {
        self.articleURL = articleURL
        self.title = title
        self.markdown = markdown
        self.label = label
    }

    public var body: some View {
        Menu {
            ShareLink(item: articleURL) {
                Label(String(localized: "Share Link", bundle: .module), systemImage: "link")
            }
            Divider()
            Button(action: copyMarkdown) {
                Label(String(localized: "Copy as Markdown", bundle: .module), systemImage: "doc.on.doc")
            }
            Button(action: saveMarkdown) {
                Label(String(localized: "Save as Markdown", bundle: .module), systemImage: "square.and.arrow.down")
            }
        } label: {
            label(copied)
        }
        .fileExporter(
            isPresented: $isExporting,
            document: exportDocument,
            contentType: .nookMarkdown,
            defaultFilename: markdownFilename
        ) { result in
            if case .failure(let error) = result {
                exportError = error.localizedDescription
            }
            exportDocument = nil
        }
        .alert(String(localized: "Couldn’t Save Markdown", bundle: .module), isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("OK") { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
    }

    private var markdownFilename: String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleaned = title
            .components(separatedBy: invalid)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(cleaned.isEmpty ? "Article" : String(cleaned.prefix(120))).md"
    }

    private func copyMarkdown() {
        #if canImport(AppKit)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let value = markdown()
        pasteboard.setString(value, forType: .string)
        pasteboard.setData(Data(value.utf8), forType: NSPasteboard.PasteboardType(UTType.nookMarkdown.identifier))
        #elseif canImport(UIKit)
        let value = markdown()
        UIPasteboard.general.setItems([[
            UTType.utf8PlainText.identifier: value,
            UTType.nookMarkdown.identifier: value,
        ]])
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #endif

        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }

    private func saveMarkdown() {
        exportDocument = MarkdownDocument(text: markdown())
        isExporting = true
    }
}
