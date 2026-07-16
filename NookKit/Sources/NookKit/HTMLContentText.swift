import AVKit
import SwiftUI

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Renders feed HTML as native SwiftUI blocks. Inline text still uses the
/// platform attributed-string importer, while block-level structure (headings,
/// code, quotes, tables, rules) and media (images, video, audio, embeds) are
/// kept in document order and rendered as dedicated native views.
public struct HTMLContentView: View {
    private let blocks: [HTMLContentBlock]
    private let selectable: Bool

    public init(html: String, baseURL: URL? = nil, selectable: Bool = true) {
        blocks = HTMLContentParser.parse(html, baseURL: baseURL)
        self.selectable = selectable
    }

    public var body: some View {
        HTMLBlockList(blocks: blocks, selectable: selectable)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Renders an ordered list of parsed blocks. Reused for nested content such as
/// blockquotes so quoted images, code, and text all render natively.
struct HTMLBlockList: View {
    let blocks: [HTMLContentBlock]
    let selectable: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: HTMLContentBlock) -> some View {
        switch block {
        case .text(let html):
            HTMLContentText(html: html, selectable: selectable)
        case .heading(let level, let html):
            NativeArticleHeading(level: level, html: html, selectable: selectable)
        case .blockquote(let inner):
            NativeArticleQuote(blocks: inner, selectable: selectable)
        case .codeBlock(let code, let language):
            NativeArticleCode(code: code, language: language, selectable: selectable)
        case .table(let table):
            NativeArticleTable(table: table, selectable: selectable)
        case .thematicBreak:
            Divider()
        case .image(let media):
            NativeArticleImage(media: media)
        case .video(let media):
            NativeArticleVideo(media: media)
        case .audio(let media):
            NativeArticleAudio(media: media)
        case .embed(let media):
            NativeArticleEmbed(media: media)
        }
    }
}

indirect enum HTMLContentBlock: Equatable {
    case text(String)
    case heading(level: Int, html: String)
    case blockquote([HTMLContentBlock])
    case codeBlock(code: String, language: String?)
    case table(HTMLTable)
    case thematicBreak
    case image(HTMLMedia)
    case video(HTMLMedia)
    case audio(HTMLMedia)
    case embed(HTMLMedia)
}

struct HTMLMedia: Equatable {
    let url: URL
    let title: String?
    let caption: String?
    let posterURL: URL?
    let aspectRatio: CGFloat?
}

struct HTMLTable: Equatable {
    struct Row: Equatable {
        let cells: [String]
        let isHeader: Bool
    }
    let rows: [Row]
}

enum HTMLContentParser {
    /// Top-level block constructs, matched in document order. Each fragment is
    /// then classified by its tag name and turned into the matching block.
    private static let blockPattern = [
        #"<figure\b[^>]*>.*?</figure\s*>"#,
        #"<pre\b[^>]*>.*?</pre\s*>"#,
        #"<blockquote\b[^>]*>.*?</blockquote\s*>"#,
        #"<table\b[^>]*>.*?</table\s*>"#,
        #"<h([1-6])\b[^>]*>.*?</h\1\s*>"#,
        #"<iframe\b[^>]*>.*?</iframe\s*>"#,
        #"<video\b[^>]*>.*?</video\s*>"#,
        #"<audio\b[^>]*>.*?</audio\s*>"#,
        #"<hr\b[^>]*/?>"#,
        #"<img\b[^>]*>"#,
    ].joined(separator: "|")

    static func parse(_ html: String, baseURL: URL?) -> [HTMLContentBlock] {
        guard let regex = try? NSRegularExpression(
            pattern: blockPattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else {
            return [.text(html)]
        }

        let fullRange = NSRange(html.startIndex..<html.endIndex, in: html)
        let matches = regex.matches(in: html, range: fullRange)
        var blocks: [HTMLContentBlock] = []
        var cursor = html.startIndex

        for match in matches {
            guard let range = Range(match.range, in: html) else { continue }
            // Skip matches that overlap content already consumed (e.g. an <img>
            // that lives inside a <figure> we already emitted).
            guard range.lowerBound >= cursor else { continue }
            appendText(String(html[cursor..<range.lowerBound]), to: &blocks)
            let fragment = String(html[range])
            if let block = classify(fragment, baseURL: baseURL) {
                blocks.append(block)
            } else {
                appendText(fragment, to: &blocks)
            }
            cursor = range.upperBound
        }

        appendText(String(html[cursor...]), to: &blocks)
        return blocks.isEmpty ? [.text(html)] : blocks
    }

    private static func classify(_ fragment: String, baseURL: URL?) -> HTMLContentBlock? {
        switch tagName(of: fragment) {
        case "figure", "img", "video", "iframe", "audio":
            return mediaBlock(from: fragment, baseURL: baseURL)
        case "pre":
            let (code, language) = codeBlock(from: fragment)
            return code.isEmpty ? nil : .codeBlock(code: code, language: language)
        case "blockquote":
            let inner = firstTagContent(named: "blockquote", in: fragment) ?? ""
            let nested = parse(inner, baseURL: baseURL)
            return nested.isEmpty ? nil : .blockquote(nested)
        case "table":
            let table = tableBlock(from: fragment, baseURL: baseURL)
            return table.rows.isEmpty ? nil : .table(table)
        case "h1", "h2", "h3", "h4", "h5", "h6":
            return headingBlock(from: fragment)
        case "hr":
            return .thematicBreak
        default:
            return nil
        }
    }

    // MARK: Media

    private static func mediaBlock(from fragment: String, baseURL: URL?) -> HTMLContentBlock? {
        let caption = firstTagContent(named: "figcaption", in: fragment).flatMap(plainText)

        if let tag = firstTag(named: "img", in: fragment),
           let url = mediaURL(in: tag, names: ["src", "data-src", "data-lazy-src", "data-original"], baseURL: baseURL) {
            let title = attribute("alt", in: tag).flatMap(decodedText)
            return .image(HTMLMedia(
                url: url,
                title: title,
                caption: caption,
                posterURL: nil,
                aspectRatio: aspectRatio(in: tag)
            ))
        }

        if let tag = firstTag(named: "video", in: fragment),
           let url = mediaURL(in: tag, names: ["src"], baseURL: baseURL)
                ?? firstTag(named: "source", in: fragment).flatMap({ mediaURL(in: $0, names: ["src"], baseURL: baseURL) }) {
            return .video(HTMLMedia(
                url: url,
                title: attribute("title", in: tag).flatMap(decodedText),
                caption: caption,
                posterURL: mediaURL(in: tag, names: ["poster"], baseURL: baseURL),
                aspectRatio: aspectRatio(in: tag)
            ))
        }

        if let tag = firstTag(named: "audio", in: fragment),
           let url = mediaURL(in: tag, names: ["src"], baseURL: baseURL)
                ?? firstTag(named: "source", in: fragment).flatMap({ mediaURL(in: $0, names: ["src"], baseURL: baseURL) }) {
            return .audio(HTMLMedia(
                url: url,
                title: attribute("title", in: tag).flatMap(decodedText),
                caption: caption,
                posterURL: nil,
                aspectRatio: nil
            ))
        }

        if let tag = firstTag(named: "iframe", in: fragment),
           let url = mediaURL(in: tag, names: ["src", "data-src"], baseURL: baseURL) {
            return .embed(HTMLMedia(
                url: url,
                title: attribute("title", in: tag).flatMap(decodedText),
                caption: caption,
                posterURL: nil,
                aspectRatio: aspectRatio(in: tag)
            ))
        }

        return nil
    }

    // MARK: Heading

    private static func headingBlock(from fragment: String) -> HTMLContentBlock? {
        let name = tagName(of: fragment)
        guard name.count == 2, let level = Int(String(name.dropFirst())) else { return nil }
        let inner = firstTagContent(named: name, in: fragment) ?? fragment
        guard !plainText(inner).isEmpty else { return nil }
        return .heading(level: level, html: inner)
    }

    // MARK: Code

    private static func codeBlock(from fragment: String) -> (String, String?) {
        var language = firstTag(named: "pre", in: fragment).flatMap(codeLanguage)
        var inner = firstTagContent(named: "pre", in: fragment) ?? fragment

        if let codeTag = firstTag(named: "code", in: inner) {
            language = language ?? codeLanguage(in: codeTag)
        }
        if let codeInner = firstTagContent(named: "code", in: inner) {
            inner = codeInner
        }

        inner = inner.replacingOccurrences(of: #"(?i)<br\s*/?>"#, with: "\n", options: .regularExpression)
        inner = inner.replacingOccurrences(of: #"(?is)</(p|div|li|tr)\s*>"#, with: "\n", options: .regularExpression)
        inner = inner.replacingOccurrences(of: #"(?is)<[^>]+>"#, with: "", options: .regularExpression)
        inner = decodeEntities(inner)
        // Trim only surrounding blank lines; keep internal indentation intact.
        inner = inner.trimmingCharacters(in: .whitespacesAndNewlines)
        return (inner, language)
    }

    private static func codeLanguage(in tag: String) -> String? {
        guard let cssClass = attribute("class", in: tag) else { return nil }
        guard let match = firstMatch(pattern: #"(?:language|lang)-([\w+#.-]+)"#, in: cssClass, group: 1) else {
            return nil
        }
        return match
    }

    // MARK: Table

    private static func tableBlock(from fragment: String, baseURL: URL?) -> HTMLTable {
        guard let rowRegex = try? NSRegularExpression(
            pattern: #"<tr\b[^>]*>(.*?)</tr\s*>"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else {
            return HTMLTable(rows: [])
        }

        let range = NSRange(fragment.startIndex..<fragment.endIndex, in: fragment)
        var rows: [HTMLTable.Row] = []

        for match in rowRegex.matches(in: fragment, range: range) {
            guard match.numberOfRanges > 1, let r = Range(match.range(at: 1), in: fragment) else { continue }
            let rowHTML = String(fragment[r])
            let (cells, isHeader) = tableCells(from: rowHTML)
            if !cells.isEmpty {
                rows.append(HTMLTable.Row(cells: cells, isHeader: isHeader))
            }
        }
        return HTMLTable(rows: rows)
    }

    private static func tableCells(from rowHTML: String) -> (cells: [String], isHeader: Bool) {
        guard let cellRegex = try? NSRegularExpression(
            pattern: #"<(t[dh])\b[^>]*>(.*?)</\1\s*>"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else {
            return ([], false)
        }

        let range = NSRange(rowHTML.startIndex..<rowHTML.endIndex, in: rowHTML)
        var cells: [String] = []
        var headerCount = 0

        for match in cellRegex.matches(in: rowHTML, range: range) {
            guard match.numberOfRanges > 2,
                  let tagRange = Range(match.range(at: 1), in: rowHTML),
                  let contentRange = Range(match.range(at: 2), in: rowHTML) else { continue }
            if rowHTML[tagRange].lowercased() == "th" { headerCount += 1 }
            cells.append(String(rowHTML[contentRange]))
        }
        // A row is a header row when every cell is a <th>.
        return (cells, !cells.isEmpty && headerCount == cells.count)
    }

    // MARK: Text collection

    private static func appendText(_ html: String, to blocks: inout [HTMLContentBlock]) {
        guard !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !plainText(html).isEmpty else { return }
        blocks.append(.text(html))
    }

    // MARK: Tag helpers

    private static func tagName(of fragment: String) -> String {
        firstMatch(pattern: #"^\s*<\s*([a-zA-Z][a-zA-Z0-9]*)"#, in: fragment, group: 1)?.lowercased() ?? ""
    }

    private static func firstTag(named name: String, in html: String) -> String? {
        firstMatch(pattern: "(?is)<\\s*\(name)\\b[^>]*>", in: html)
    }

    private static func firstTagContent(named name: String, in html: String) -> String? {
        guard let match = firstMatch(pattern: "(?is)<\\s*\(name)\\b[^>]*>(.*)</\\s*\(name)\\s*>", in: html, group: 1) else {
            return nil
        }
        return match
    }

    private static func firstMatch(pattern: String, in value: String, group: Int = 0) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..<value.endIndex, in: value)),
              match.numberOfRanges > group,
              let range = Range(match.range(at: group), in: value) else { return nil }
        return String(value[range])
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        let pattern = #"(?is)(?:^|\s)"# + escaped + #"\s*=\s*(?:\"([^\"]*)\"|'([^']*)'|([^\s>]+))"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..<tag.endIndex, in: tag)) else {
            return nil
        }
        for group in 1..<match.numberOfRanges where match.range(at: group).location != NSNotFound {
            if let range = Range(match.range(at: group), in: tag) { return String(tag[range]) }
        }
        return nil
    }

    private static func mediaURL(in tag: String, names: [String], baseURL: URL?) -> URL? {
        for name in names {
            guard let raw = attribute(name, in: tag).flatMap(decodedText), !raw.isEmpty else { continue }
            if let url = URL(string: raw, relativeTo: baseURL)?.absoluteURL,
               ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                return url
            }
        }
        return nil
    }

    private static func aspectRatio(in tag: String) -> CGFloat? {
        guard let widthString = attribute("width", in: tag),
              let heightString = attribute("height", in: tag),
              let width = Double(widthString), let height = Double(heightString), height > 0 else { return nil }
        return CGFloat(width / height)
    }

    private static func plainText(_ html: String) -> String {
        let withoutTags = html.replacingOccurrences(of: #"(?is)<[^>]+>"#, with: " ", options: .regularExpression)
        return decodedText(withoutTags)?
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+([.,;:!?])"#, with: "$1", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func decodedText(_ value: String) -> String? {
        guard !value.isEmpty, let data = value.data(using: .utf8),
              let decoded = try? NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue],
                documentAttributes: nil
              ).string else { return value.isEmpty ? nil : value }
        let trimmed = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Decodes HTML entities while preserving whitespace and line breaks, so
    /// code blocks keep their original formatting.
    private static func decodeEntities(_ value: String) -> String {
        var result = value

        if let regex = try? NSRegularExpression(pattern: #"&#(x?[0-9a-fA-F]+);"#) {
            let matches = regex.matches(in: result, range: NSRange(result.startIndex..<result.endIndex, in: result))
            for match in matches.reversed() {
                guard let full = Range(match.range, in: result),
                      let body = Range(match.range(at: 1), in: result) else { continue }
                let token = String(result[body])
                let scalarValue: UInt32?
                if token.first == "x" || token.first == "X" {
                    scalarValue = UInt32(token.dropFirst(), radix: 16)
                } else {
                    scalarValue = UInt32(token, radix: 10)
                }
                if let scalarValue, let scalar = Unicode.Scalar(scalarValue) {
                    result.replaceSubrange(full, with: String(scalar))
                }
            }
        }

        let named = ["&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&nbsp;": " "]
        for (entity, replacement) in named {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }
        // Decode &amp; last so sequences like &amp;lt; resolve correctly.
        return result.replacingOccurrences(of: "&amp;", with: "&")
    }
}

// MARK: - Media views

private struct NativeArticleImage: View {
    let media: HTMLMedia
    @Environment(\.articleImagePresenter) private var presenter

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AsyncImage(url: media.url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFit()
                        .contentShape(Rectangle())
                        .onTapGesture { presenter?.present(url: media.url, caption: media.caption) }
                        .help(String(localized: "Click to zoom", bundle: .module))
                        #if canImport(AppKit)
                        .pointerStyle(.zoomIn)
                        #endif
                case .failure:
                    NativeMediaLink(media: media, systemImage: "photo", label: String(localized: "Open Image", bundle: .module))
                default:
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 160)
                }
            }
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            if let caption = media.caption {
                Text(caption).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct NativeArticleVideo: View {
    let media: HTMLMedia
    @State private var player: AVPlayer

    init(media: HTMLMedia) {
        self.media = media
        _player = State(initialValue: AVPlayer(url: media.url))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VideoPlayer(player: player)
                .aspectRatio(media.aspectRatio ?? (16 / 9), contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            if let caption = media.caption {
                Text(caption).font(.caption).foregroundStyle(.secondary)
            }
        }
        .onDisappear { player.pause() }
    }
}

/// A compact, native audio player: play/pause plus a source label. Avoids the
/// empty video surface that `VideoPlayer` would show for audio-only media.
private struct NativeArticleAudio: View {
    let media: HTMLMedia
    @State private var player: AVPlayer
    @State private var isPlaying = false

    init(media: HTMLMedia) {
        self.media = media
        _player = State(initialValue: AVPlayer(url: media.url))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Button(action: toggle) {
                    Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 30))
                        .symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 2) {
                    Text(media.title ?? String(localized: "Audio", bundle: .module))
                        .fontWeight(.medium)
                        .lineLimit(1)
                    if let host = media.url.host() {
                        Text(host).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "waveform").foregroundStyle(.secondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            if let caption = media.caption {
                Text(caption).font(.caption).foregroundStyle(.secondary)
            }
        }
        .onDisappear {
            player.pause()
            isPlaying = false
        }
    }

    private func toggle() {
        if isPlaying { player.pause() } else { player.play() }
        isPlaying.toggle()
    }
}

/// An `<iframe>` embed. Arbitrary web embeds cannot render in a native view
/// without a `WKWebView`, which the reader deliberately avoids on its default
/// surface. For well-known video hosts we show a rich thumbnail card that opens
/// the source; everything else falls back to a labelled link card.
private struct NativeArticleEmbed: View {
    let media: HTMLMedia

    var body: some View {
        if let embed = VideoEmbed(url: media.url) {
            EmbedThumbnailCard(embed: embed, media: media)
        } else {
            NativeMediaLink(
                media: media,
                systemImage: "rectangle.on.rectangle",
                label: media.title ?? String(localized: "Open Embedded Content", bundle: .module)
            )
        }
    }
}

/// A recognised video embed with a thumbnail and a canonical watch URL.
private struct VideoEmbed {
    let thumbnailURL: URL?
    let watchURL: URL
    let hostLabel: String

    init?(url: URL) {
        let host = url.host()?.lowercased() ?? ""
        if host.contains("youtube") || host.contains("youtu.be") {
            guard let id = VideoEmbed.youTubeID(from: url) else { return nil }
            thumbnailURL = URL(string: "https://img.youtube.com/vi/\(id)/hqdefault.jpg")
            watchURL = URL(string: "https://www.youtube.com/watch?v=\(id)") ?? url
            hostLabel = "YouTube"
        } else if host.contains("vimeo") {
            // Vimeo needs an API call for thumbnails; still offer a rich card.
            thumbnailURL = nil
            watchURL = url
            hostLabel = "Vimeo"
        } else {
            return nil
        }
    }

    private static func youTubeID(from url: URL) -> String? {
        if url.host()?.contains("youtu.be") == true {
            let id = url.lastPathComponent
            return id.isEmpty ? nil : id
        }
        // .../embed/<id> or .../v/<id>
        let parts = url.pathComponents
        if let anchor = parts.firstIndex(where: { $0 == "embed" || $0 == "v" }),
           anchor + 1 < parts.count {
            return parts[anchor + 1]
        }
        // watch?v=<id>
        if let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
           let v = items.first(where: { $0.name == "v" })?.value {
            return v
        }
        return nil
    }
}

private struct EmbedThumbnailCard: View {
    let embed: VideoEmbed
    let media: HTMLMedia

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Link(destination: embed.watchURL) {
                ZStack {
                    if let thumb = embed.thumbnailURL {
                        AsyncImage(url: thumb) { phase in
                            switch phase {
                            case .success(let image): image.resizable().scaledToFill()
                            default: Color.black.opacity(0.85)
                            }
                        }
                    } else {
                        Color.black.opacity(0.85)
                    }

                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 52))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.white)
                        .shadow(radius: 8)

                    VStack {
                        Spacer()
                        HStack {
                            Text(embed.hostLabel)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(.black.opacity(0.55), in: Capsule())
                            Spacer()
                        }
                        .padding(10)
                    }
                }
                .frame(maxWidth: .infinity)
                .aspectRatio(media.aspectRatio ?? (16 / 9), contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let caption = media.caption ?? media.title {
                Text(caption).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct NativeMediaLink: View {
    let media: HTMLMedia
    let systemImage: String
    let label: String

    var body: some View {
        Link(destination: media.url) {
            HStack(spacing: 12) {
                Image(systemName: systemImage).font(.title2)
                VStack(alignment: .leading, spacing: 3) {
                    Text(label).fontWeight(.medium)
                    if let host = media.url.host() {
                        Text(host).font(.caption).foregroundStyle(.secondary)
                    }
                    if let caption = media.caption {
                        Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Image viewer (in-window overlay)

/// The image currently being viewed in the lightbox overlay.
public struct ArticleImageItem: Equatable, Identifiable {
    public let url: URL
    public let caption: String?
    public var id: URL { url }
}

/// Drives the in-window photo overlay. Inject it with `.articleImageOverlay(_:)`
/// on a top-level container; article images then present into that overlay
/// instead of opening a separate window.
@MainActor
@Observable
public final class ArticleImagePresenter {
    public var item: ArticleImageItem?
    public init() {}

    public func present(url: URL, caption: String?) {
        item = ArticleImageItem(url: url, caption: caption)
    }

    public func dismiss() { item = nil }
}

extension EnvironmentValues {
    @Entry var articleImagePresenter: ArticleImagePresenter?
}

public extension View {
    /// Hosts the article image lightbox as an in-window overlay and makes the
    /// presenter available to any `HTMLContentView` below in the hierarchy.
    func articleImageOverlay(_ presenter: ArticleImagePresenter) -> some View {
        environment(\.articleImagePresenter, presenter)
            .overlay { ArticleImageOverlay(presenter: presenter) }
    }
}

private struct ArticleImageOverlay: View {
    let presenter: ArticleImagePresenter

    var body: some View {
        ZStack {
            if let item = presenter.item {
                ImageViewer(item: item) { presenter.dismiss() }
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .animation(.easeInOut(duration: 0.22), value: presenter.item)
    }
}

/// A full-surface photo viewer. Zoom and pan are handled by a native scroll
/// view (`NSScrollView`/`UIScrollView`) so pinch and double-tap zoom are
/// centered on the pointer/touch and a zoomed image pans with the trackpad,
/// mouse wheel, or a drag. Rendered inline as an overlay.
private struct ImageViewer: View {
    let item: ArticleImageItem
    let onClose: () -> Void

    var body: some View {
        ZStack {
            // Dim scrim; a click anywhere outside the image dismisses.
            Rectangle()
                .fill(.black.opacity(0.9))
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onClose() }

            ZoomableImageView(url: item.url)
                .padding(24)

            VStack {
                HStack {
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 26))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.white)
                            .padding(12)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                    .help(String(localized: "Close", bundle: .module))
                }
                Spacer()
                if let caption = item.caption {
                    Text(caption)
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.black.opacity(0.4), in: Capsule())
                        .padding(.bottom, 20)
                }
            }
        }
    }
}

#if canImport(AppKit)
/// Wraps an `NSScrollView` whose magnification is centered on the cursor, so a
/// trackpad pinch zooms toward the pointer and the wheel/trackpad pans.
private struct ZoomableImageView: NSViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> FittingScrollView {
        let scrollView = FittingScrollView()
        scrollView.contentView = CenteringClipView()
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.01
        scrollView.maxMagnification = 6

        let imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        scrollView.documentView = imageView

        let doubleClick = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleClick(_:)))
        doubleClick.numberOfClicksRequired = 2
        imageView.addGestureRecognizer(doubleClick)

        context.coordinator.scrollView = scrollView
        context.coordinator.imageView = imageView
        context.coordinator.load(url: url)
        return scrollView
    }

    func updateNSView(_ nsView: FittingScrollView, context: Context) {
        if context.coordinator.url != url { context.coordinator.load(url: url) }
    }

    @MainActor
    final class Coordinator: NSObject {
        weak var scrollView: FittingScrollView?
        weak var imageView: NSImageView?
        private(set) var url: URL?
        private var task: URLSessionDataTask?

        func load(url: URL) {
            self.url = url
            task?.cancel()
            task = URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
                guard let data, let image = NSImage(data: data) else { return }
                Task { @MainActor in self?.apply(image) }
            }
            task?.resume()
        }

        private func apply(_ image: NSImage) {
            guard let scrollView, let imageView else { return }
            imageView.image = image
            imageView.frame = NSRect(origin: .zero, size: image.size)
            // Defer the fit to layout, when the scroll view actually has its
            // final size; fitting here (bounds may still be zero) is what made
            // the image open zoomed-in and impossible to zoom back out.
            scrollView.fitContent(imageView.bounds)
        }

        @objc func handleDoubleClick(_ gesture: NSClickGestureRecognizer) {
            guard let scrollView, let imageView else { return }
            let fit = scrollView.minMagnification
            if scrollView.magnification > fit + 0.001 {
                scrollView.animator().magnify(toFit: imageView.bounds)
            } else {
                let point = gesture.location(in: imageView)
                let target = min(fit * 2.5, scrollView.maxMagnification)
                scrollView.animator().setMagnification(target, centeredAt: point)
            }
        }
    }
}

/// An `NSScrollView` that fits its document once it has a real size, and keeps
/// it fitted across viewport resizes while the user is fully zoomed out. The
/// fitted magnification becomes the minimum, so the whole image is always
/// reachable.
private final class FittingScrollView: NSScrollView {
    private var fitRect: NSRect?
    private var hasFitted = false
    private var lastViewportSize: NSSize = .zero

    func fitContent(_ rect: NSRect) {
        fitRect = rect
        hasFitted = false
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard let rect = fitRect, bounds.width > 1, bounds.height > 1 else { return }
        if !hasFitted {
            applyFit(rect)
            hasFitted = true
            lastViewportSize = bounds.size
        } else if bounds.size != lastViewportSize {
            lastViewportSize = bounds.size
            // Only re-fit when the user hasn't zoomed in past the fit level.
            if magnification <= minMagnification + 0.0001 { applyFit(rect) }
        }
    }

    private func applyFit(_ rect: NSRect) {
        magnify(toFit: rect)
        minMagnification = magnification
    }
}

/// Keeps the document centered when it is smaller than the viewport (which the
/// fitted image always is in one dimension).
private final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let documentView else { return rect }
        let doc = documentView.frame
        if rect.width > doc.width { rect.origin.x = (doc.width - rect.width) / 2 }
        if rect.height > doc.height { rect.origin.y = (doc.height - rect.height) / 2 }
        return rect
    }
}
#else
/// Wraps a `UIScrollView` so pinch and double-tap zoom are centered on the
/// touch point and a zoomed image pans with a drag.
private struct ZoomableImageView: UIViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 6
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.backgroundColor = .clear
        scrollView.contentInsetAdjustmentBehavior = .never

        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFit
        scrollView.addSubview(imageView)

        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        context.coordinator.scrollView = scrollView
        context.coordinator.imageView = imageView
        context.coordinator.load(url: url)
        return scrollView
    }

    func updateUIView(_ uiView: UIScrollView, context: Context) {
        if context.coordinator.url != url { context.coordinator.load(url: url) }
        context.coordinator.layoutImage()
    }

    @MainActor
    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var scrollView: UIScrollView?
        weak var imageView: UIImageView?
        private(set) var url: URL?
        private var task: URLSessionDataTask?

        func load(url: URL) {
            self.url = url
            task?.cancel()
            task = URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
                guard let data, let image = UIImage(data: data) else { return }
                Task { @MainActor in
                    self?.imageView?.image = image
                    self?.layoutImage()
                }
            }
            task?.resume()
        }

        func layoutImage() {
            guard let scrollView, let imageView, imageView.image != nil else { return }
            imageView.frame = scrollView.bounds
            scrollView.contentSize = scrollView.bounds.size
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            // Keep the image centered while zoomed out.
            guard let imageView else { return }
            let offsetX = max((scrollView.bounds.width - scrollView.contentSize.width) / 2, 0)
            let offsetY = max((scrollView.bounds.height - scrollView.contentSize.height) / 2, 0)
            imageView.center = CGPoint(
                x: scrollView.contentSize.width / 2 + offsetX,
                y: scrollView.contentSize.height / 2 + offsetY
            )
        }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scrollView else { return }
            if scrollView.zoomScale > scrollView.minimumZoomScale + 0.001 {
                scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
            } else {
                let point = gesture.location(in: imageView)
                let target = min(scrollView.minimumZoomScale * 2.5, scrollView.maximumZoomScale)
                let size = CGSize(width: scrollView.bounds.width / target, height: scrollView.bounds.height / target)
                let rect = CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height)
                scrollView.zoom(to: rect, animated: true)
            }
        }
    }
}
#endif

// MARK: - Block-level text views

/// A heading rendered natively at a scaled, bold size while keeping inline
/// formatting (links, emphasis, code) from the source markup.
private struct NativeArticleHeading: View {
    let level: Int
    let html: String
    let selectable: Bool

    var body: some View {
        HTMLContentText(html: html, selectable: selectable, baseSize: size, bold: true)
            .padding(.top, level <= 2 ? 6 : 2)
    }

    private var size: CGFloat {
        let base = HTMLContentText.platformBodySize
        let scale: CGFloat
        switch level {
        case 1: scale = 1.7
        case 2: scale = 1.45
        case 3: scale = 1.25
        case 4: scale = 1.1
        case 5: scale = 1.0
        default: scale = 0.9
        }
        return base * scale
    }
}

/// A blockquote: nested native content indented behind an accent bar.
private struct NativeArticleQuote: View {
    let blocks: [HTMLContentBlock]
    let selectable: Bool

    var body: some View {
        HTMLBlockList(blocks: blocks, selectable: selectable)
            .padding(.leading, 16)
            .padding(.vertical, 2)
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Color.accentColor.opacity(0.55))
                    .frame(width: 4)
            }
            .foregroundStyle(.secondary)
    }
}

/// A preformatted code block: syntax-highlighted, monospaced, boxed, and
/// horizontally scrollable so long lines don't wrap.
private struct NativeArticleCode: View {
    let code: String
    let language: String?
    let selectable: Bool
    @State private var highlighted: AttributedString?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let language, !language.isEmpty {
                Text(language.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
            }
            ScrollView(.horizontal, showsIndicators: true) {
                text
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SyntaxHighlighter.blockBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 1)
        )
        .task(id: code) { highlighted = SyntaxHighlighter.attributed(code, language: language) }
    }

    @ViewBuilder
    private var text: some View {
        let rendered = Text(highlighted ?? AttributedString(code))
            .font(.system(.callout, design: .monospaced))
        if selectable {
            rendered.textSelection(.enabled)
        } else {
            rendered
        }
    }
}

/// A table rendered as a native grid with header emphasis and cell borders.
private struct NativeArticleTable: View {
    let table: HTMLTable
    let selectable: Bool

    var body: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
            ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(Array(row.cells.enumerated()), id: \.offset) { _, cell in
                        cellView(cell, isHeader: row.isHeader)
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 1)
        )
    }

    private func cellView(_ html: String, isHeader: Bool) -> some View {
        HTMLContentText(html: html, selectable: selectable, bold: isHeader)
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isHeader ? AnyShapeStyle(.quaternary.opacity(0.5)) : AnyShapeStyle(Color.clear))
            .overlay(Rectangle().stroke(.quaternary, lineWidth: 0.5))
    }
}

// MARK: - Syntax highlighting

/// A lightweight, language-agnostic highlighter for code blocks. It colours
/// comments, strings, numbers, keywords, and capitalised type names using
/// system semantic colours so it adapts to light and dark automatically. Only
/// foreground colours are applied; the monospaced font comes from the view.
enum SyntaxHighlighter {
    #if canImport(AppKit)
    private typealias PlatformColor = NSColor
    private static var keywordColor: NSColor { .systemPink }
    private static var typeColor: NSColor { .systemTeal }
    private static var numberColor: NSColor { .systemOrange }
    private static var stringColor: NSColor { .systemGreen }
    private static var commentColor: NSColor { .secondaryLabelColor }
    #else
    private typealias PlatformColor = UIColor
    private static var keywordColor: UIColor { .systemPink }
    private static var typeColor: UIColor { .systemTeal }
    private static var numberColor: UIColor { .systemOrange }
    private static var stringColor: UIColor { .systemGreen }
    private static var commentColor: UIColor { .secondaryLabel }
    #endif

    static var blockBackground: AnyShapeStyle { AnyShapeStyle(.quaternary.opacity(0.4)) }

    private static let keywords = [
        "let", "var", "const", "func", "function", "fn", "fun", "def", "class", "struct",
        "enum", "interface", "protocol", "extension", "return", "if", "else", "elif", "for",
        "while", "do", "switch", "case", "default", "break", "continue", "import", "from",
        "export", "public", "private", "protected", "internal", "static", "final", "override",
        "new", "self", "this", "super", "true", "false", "nil", "null", "none", "void",
        "int", "float", "double", "bool", "string", "char", "async", "await", "try", "catch",
        "finally", "throw", "throws", "guard", "in", "is", "as", "where", "val", "yield",
        "with", "and", "or", "not", "typeof", "namespace", "using", "package", "module"
    ]

    static func attributed(_ code: String, language: String?) -> AttributedString {
        let mutable = NSMutableAttributedString(string: code)
        let keywordPattern = "\\b(?:" + keywords.joined(separator: "|") + ")\\b"

        // Applied in order; later passes override earlier colours so that
        // strings win over keywords and comments win over everything.
        apply(mutable, code, pattern: #"\b[A-Z][A-Za-z0-9_]*\b"#, color: typeColor)
        apply(mutable, code, pattern: keywordPattern, color: keywordColor)
        apply(mutable, code, pattern: #"\b\d[\d_]*(?:\.\d+)?\b"#, color: numberColor)
        apply(mutable, code, pattern: ##""(?:\\.|[^"\\])*""##, color: stringColor)
        apply(mutable, code, pattern: ##"'(?:\\.|[^'\\])*'"##, color: stringColor)
        apply(mutable, code, pattern: #"/\*[\s\S]*?\*/"#, color: commentColor)
        apply(mutable, code, pattern: #"(?m)(?<!:)(?://|#).*$"#, color: commentColor)

        let range = NSRange(location: 0, length: mutable.length)
        #if canImport(AppKit)
        return (try? AttributedString(mutable, including: \.appKit)) ?? fallback(code, mutable, range)
        #else
        return (try? AttributedString(mutable, including: \.uiKit)) ?? fallback(code, mutable, range)
        #endif
    }

    private static func fallback(_ code: String, _ mutable: NSAttributedString, _ range: NSRange) -> AttributedString {
        AttributedString(code)
    }

    private static func apply(_ target: NSMutableAttributedString, _ source: String, pattern: String, color: PlatformColor) {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        for match in regex.matches(in: source, range: range) {
            target.addAttribute(.foregroundColor, value: color, range: match.range)
        }
    }
}

/// Renders a text-only HTML fragment as native, selectable text.
public struct HTMLContentText: View {
    let html: String
    let selectable: Bool
    let baseSize: CGFloat?
    let bold: Bool
    @State private var attributed: AttributedString?

    public init(html: String, selectable: Bool = true, baseSize: CGFloat? = nil, bold: Bool = false) {
        self.html = html
        self.selectable = selectable
        self.baseSize = baseSize
        self.bold = bold
    }

    public var body: some View {
        Group {
            if let attributed {
                let text = Text(attributed).lineSpacing(4).tint(.accentColor)
                if selectable {
                    text.textSelection(.enabled)
                } else {
                    text.textSelection(.disabled)
                }
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: renderKey) { attributed = Self.render(html, baseSize: resolvedSize, bold: bold) }
    }

    private var resolvedSize: CGFloat { baseSize ?? Self.platformBodySize }
    private var renderKey: String { "\(resolvedSize)-\(bold)-\(html)" }

    static var platformBodySize: CGFloat {
        #if canImport(AppKit)
        NSFont.preferredFont(forTextStyle: .body).pointSize
        #else
        UIFont.preferredFont(forTextStyle: .body).pointSize
        #endif
    }

    private static func render(_ html: String, baseSize: CGFloat, bold: Bool) -> AttributedString? {
        guard let data = html.data(using: .utf8) else { return nil }
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue
        ]
        guard let mutable = try? NSMutableAttributedString(data: data, options: options, documentAttributes: nil) else { return nil }
        let fullRange = NSRange(location: 0, length: mutable.length)
        let codeSize = baseSize * 0.92

        #if canImport(AppKit)
        var monoRanges: [NSRange] = []
        mutable.enumerateAttribute(.font, in: fullRange) { value, range, _ in
            let existing = (value as? NSFont)?.fontDescriptor.symbolicTraits ?? []
            let isMono = existing.contains(.monoSpace)
            var traits: NSFontDescriptor.SymbolicTraits = []
            if existing.contains(.bold) || bold { traits.insert(.bold) }
            if existing.contains(.italic) { traits.insert(.italic) }

            let font: NSFont
            if isMono {
                let weight: NSFont.Weight = traits.contains(.bold) ? .semibold : .regular
                font = NSFont.monospacedSystemFont(ofSize: codeSize, weight: weight)
                monoRanges.append(range)
            } else {
                let descriptor = NSFont.systemFont(ofSize: baseSize).fontDescriptor.withSymbolicTraits(traits)
                font = NSFont(descriptor: descriptor, size: baseSize) ?? NSFont.systemFont(ofSize: baseSize)
            }
            mutable.addAttribute(.font, value: font, range: range)
        }
        styleLinks(mutable, fullRange: fullRange, linkColor: NSColor.controlAccentColor, plainColor: NSColor.labelColor)
        // Inline code: no box, just a distinct code tint (applied after link
        // styling so it wins over the plain-text colour).
        for range in monoRanges {
            mutable.addAttribute(.foregroundColor, value: NSColor.systemPink, range: range)
        }
        return try? AttributedString(mutable, including: \.appKit)
        #else
        var monoRanges: [NSRange] = []
        mutable.enumerateAttribute(.font, in: fullRange) { value, range, _ in
            let existing = (value as? UIFont)?.fontDescriptor.symbolicTraits ?? []
            let isMono = existing.contains(.traitMonoSpace)
            var traits: UIFontDescriptor.SymbolicTraits = []
            if existing.contains(.traitBold) || bold { traits.insert(.traitBold) }
            if existing.contains(.traitItalic) { traits.insert(.traitItalic) }

            let font: UIFont
            if isMono {
                let weight: UIFont.Weight = traits.contains(.traitBold) ? .semibold : .regular
                font = UIFont.monospacedSystemFont(ofSize: codeSize, weight: weight)
                monoRanges.append(range)
            } else {
                let base = UIFont.systemFont(ofSize: baseSize)
                font = UIFont(descriptor: base.fontDescriptor.withSymbolicTraits(traits) ?? base.fontDescriptor, size: baseSize)
            }
            mutable.addAttribute(.font, value: font, range: range)
        }
        styleLinks(mutable, fullRange: fullRange, linkColor: UIColor.tintColor, plainColor: UIColor.label)
        for range in monoRanges {
            mutable.addAttribute(.foregroundColor, value: UIColor.systemPink, range: range)
        }
        return try? AttributedString(mutable, including: \.uiKit)
        #endif
    }

    #if canImport(AppKit)
    private static func styleLinks(_ mutable: NSMutableAttributedString, fullRange: NSRange, linkColor: NSColor, plainColor: NSColor) {
        mutable.enumerateAttribute(.link, in: fullRange) { link, range, _ in
            if link == nil {
                mutable.addAttribute(.foregroundColor, value: plainColor, range: range)
            } else {
                // Theme-aware accent plus a soft underline so links read clearly
                // in both light and dark appearances without being harsh.
                mutable.addAttribute(.foregroundColor, value: linkColor, range: range)
                mutable.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
                mutable.addAttribute(.underlineColor, value: linkColor.withAlphaComponent(0.4), range: range)
            }
        }
    }
    #else
    private static func styleLinks(_ mutable: NSMutableAttributedString, fullRange: NSRange, linkColor: UIColor, plainColor: UIColor) {
        mutable.enumerateAttribute(.link, in: fullRange) { link, range, _ in
            if link == nil {
                mutable.addAttribute(.foregroundColor, value: plainColor, range: range)
            } else {
                mutable.addAttribute(.foregroundColor, value: linkColor, range: range)
                mutable.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
                mutable.addAttribute(.underlineColor, value: linkColor.withAlphaComponent(0.4), range: range)
            }
        }
    }
    #endif
}
