import AVKit
import SwiftUI

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Renders feed HTML as native SwiftUI blocks. Text still uses the platform
/// attributed-string importer, while media that importer cannot represent is
/// kept in document order and rendered as native images, video, or link cards.
public struct HTMLContentView: View {
    private let blocks: [HTMLContentBlock]
    private let selectable: Bool

    public init(html: String, baseURL: URL? = nil, selectable: Bool = true) {
        blocks = HTMLContentParser.parse(html, baseURL: baseURL)
        self.selectable = selectable
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .text(let html):
                    HTMLContentText(html: html, selectable: selectable)
                case .image(let media):
                    NativeArticleImage(media: media)
                case .video(let media):
                    NativeArticleVideo(media: media)
                case .embed(let media):
                    NativeArticleEmbed(media: media)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

enum HTMLContentBlock: Equatable {
    case text(String)
    case image(HTMLMedia)
    case video(HTMLMedia)
    case embed(HTMLMedia)
}

struct HTMLMedia: Equatable {
    let url: URL
    let title: String?
    let caption: String?
    let posterURL: URL?
    let aspectRatio: CGFloat?
}

enum HTMLContentParser {
    private static let mediaPattern = #"(?is)<figure\b[^>]*>.*?</figure\s*>|<iframe\b[^>]*>.*?</iframe\s*>|<video\b[^>]*>.*?</video\s*>|<img\b[^>]*>"#

    static func parse(_ html: String, baseURL: URL?) -> [HTMLContentBlock] {
        guard let regex = try? NSRegularExpression(pattern: mediaPattern) else {
            return [.text(html)]
        }

        let fullRange = NSRange(html.startIndex..<html.endIndex, in: html)
        let matches = regex.matches(in: html, range: fullRange)
        var blocks: [HTMLContentBlock] = []
        var cursor = html.startIndex

        for match in matches {
            guard let range = Range(match.range, in: html) else { continue }
            appendText(String(html[cursor..<range.lowerBound]), to: &blocks)
            let fragment = String(html[range])
            if let media = mediaBlock(from: fragment, baseURL: baseURL) {
                blocks.append(media)
            } else {
                appendText(fragment, to: &blocks)
            }
            cursor = range.upperBound
        }

        appendText(String(html[cursor...]), to: &blocks)
        return blocks.isEmpty ? [.text(html)] : blocks
    }

    private static func mediaBlock(from fragment: String, baseURL: URL?) -> HTMLContentBlock? {
        let caption = firstTagContent(named: "figcaption", in: fragment).flatMap(plainText)

        if let tag = firstTag(named: "img", in: fragment),
           let url = mediaURL(in: tag, names: ["src", "data-src", "data-lazy-src"], baseURL: baseURL) {
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

    private static func appendText(_ html: String, to blocks: inout [HTMLContentBlock]) {
        guard !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !plainText(html).isEmpty else { return }
        blocks.append(.text(html))
    }

    private static func firstTag(named name: String, in html: String) -> String? {
        firstMatch(pattern: "(?is)<\\s*\(name)\\b[^>]*>", in: html)
    }

    private static func firstTagContent(named name: String, in html: String) -> String? {
        guard let match = firstMatch(pattern: "(?is)<\\s*\(name)\\b[^>]*>(.*?)</\\s*\(name)\\s*>", in: html, group: 1) else {
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
}

private struct NativeArticleImage: View {
    let media: HTMLMedia

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AsyncImage(url: media.url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFit()
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

private struct NativeArticleEmbed: View {
    let media: HTMLMedia

    var body: some View {
        NativeMediaLink(
            media: media,
            systemImage: media.url.host()?.contains("youtube") == true ? "play.rectangle" : "rectangle.on.rectangle",
            label: media.title ?? String(localized: "Open Embedded Content", bundle: .module)
        )
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

/// Renders a text-only HTML fragment as native, selectable text.
public struct HTMLContentText: View {
    let html: String
    let selectable: Bool
    @State private var attributed: AttributedString?

    public init(html: String, selectable: Bool = true) {
        self.html = html
        self.selectable = selectable
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
        .task(id: html) { attributed = Self.render(html) }
    }

    private static func render(_ html: String) -> AttributedString? {
        guard let data = html.data(using: .utf8) else { return nil }
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue
        ]
        guard let mutable = try? NSMutableAttributedString(data: data, options: options, documentAttributes: nil) else { return nil }
        let fullRange = NSRange(location: 0, length: mutable.length)

        #if canImport(AppKit)
        let baseSize = NSFont.preferredFont(forTextStyle: .body).pointSize
        mutable.enumerateAttribute(.font, in: fullRange) { value, range, _ in
            let existingTraits = (value as? NSFont)?.fontDescriptor.symbolicTraits ?? []
            var traits: NSFontDescriptor.SymbolicTraits = []
            if existingTraits.contains(.bold) { traits.insert(.bold) }
            if existingTraits.contains(.italic) { traits.insert(.italic) }
            let descriptor = NSFont.systemFont(ofSize: baseSize).fontDescriptor.withSymbolicTraits(traits)
            mutable.addAttribute(.font, value: NSFont(descriptor: descriptor, size: baseSize) ?? NSFont.systemFont(ofSize: baseSize), range: range)
        }
        mutable.enumerateAttribute(.link, in: fullRange) { link, range, _ in
            if link == nil { mutable.addAttribute(.foregroundColor, value: NSColor.labelColor, range: range) }
        }
        return try? AttributedString(mutable, including: \.appKit)
        #else
        let baseSize = UIFont.preferredFont(forTextStyle: .body).pointSize
        mutable.enumerateAttribute(.font, in: fullRange) { value, range, _ in
            let existingTraits = (value as? UIFont)?.fontDescriptor.symbolicTraits ?? []
            var traits: UIFontDescriptor.SymbolicTraits = []
            if existingTraits.contains(.traitBold) { traits.insert(.traitBold) }
            if existingTraits.contains(.traitItalic) { traits.insert(.traitItalic) }
            let base = UIFont.systemFont(ofSize: baseSize)
            mutable.addAttribute(.font, value: UIFont(descriptor: base.fontDescriptor.withSymbolicTraits(traits) ?? base.fontDescriptor, size: baseSize), range: range)
        }
        mutable.enumerateAttribute(.link, in: fullRange) { link, range, _ in
            if link == nil { mutable.addAttribute(.foregroundColor, value: UIColor.label, range: range) }
        }
        return try? AttributedString(mutable, including: \.uiKit)
        #endif
    }
}
