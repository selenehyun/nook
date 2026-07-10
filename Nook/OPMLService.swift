import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// A feed entry parsed from an OPML outline, with its declared folder as the
/// category so the import preview can group and label it.
struct OPMLFeed: Identifiable, Hashable {
    var id: String { feedURL.absoluteString }
    var title: String
    var feedURL: URL
    var siteURL: URL?
    var category: String?
}

struct OPMLService {
    func importFeeds(from fileURL: URL) throws -> [OPMLFeed] {
        let data = try Data(contentsOf: fileURL)
        let parser = OPMLOutlineParser()
        return try parser.parse(data: data)
    }

    func exportData(for feeds: [Feed]) -> Data {
        let outlines = feeds
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            .map { feed in
                """
                    <outline text="\(feed.title.xmlEscaped)" title="\(feed.title.xmlEscaped)" type="rss" xmlUrl="\(feed.feedURL.absoluteString.xmlEscaped)" htmlUrl="\(feed.siteURL.absoluteString.xmlEscaped)" />
                """
            }
            .joined(separator: "\n")

        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <opml version="2.0">
          <head>
            <title>Nook Subscriptions</title>
          </head>
          <body>
        \(outlines)
          </body>
        </opml>
        """

        return Data(xml.utf8)
    }
}

struct OPMLDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.opml, .xml] }
    static var writableContentTypes: [UTType] { [.opml] }

    var feeds: [Feed]

    init(feeds: [Feed]) {
        self.feeds = feeds
    }

    init(configuration: ReadConfiguration) throws {
        feeds = []
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: OPMLService().exportData(for: feeds))
    }
}

extension UTType {
    /// The `.opml` extension usually has no registered UTI, so macOS types the
    /// file as a dynamic type derived from the extension. Deriving our type the
    /// same way (no forced `conformingTo:`) makes those files selectable in the
    /// open panel; `.xml` still covers files typed as XML.
    static var opml: UTType {
        UTType(filenameExtension: "opml") ?? .xml
    }
}

private final class OPMLOutlineParser: NSObject, XMLParserDelegate {
    private var parserError: Error?
    private var feeds: [OPMLFeed] = []
    private var seenFeedURLs: Set<String> = []
    private var folderStack: [String] = []
    private var outlineIsFolder: [Bool] = []

    func parse(data: Data) throws -> [OPMLFeed] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false

        guard parser.parse() else {
            throw parser.parserError ?? parserError ?? CocoaError(.fileReadCorruptFile)
        }

        return feeds
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard elementName.lowercased() == "outline" else { return }

        let rawFeedURL = (attributeDict["xmlUrl"] ?? attributeDict["xmlurl"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let title = (attributeDict["title"] ?? attributeDict["text"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let rawFeedURL, !rawFeedURL.isEmpty, let feedURL = URL(string: rawFeedURL) {
            outlineIsFolder.append(false)
            guard seenFeedURLs.insert(feedURL.absoluteString).inserted else { return }
            let siteURL = (attributeDict["htmlUrl"] ?? attributeDict["htmlurl"]).flatMap(URL.init(string:))
            feeds.append(
                OPMLFeed(
                    title: title.isEmpty ? (feedURL.host ?? feedURL.absoluteString) : title,
                    feedURL: feedURL,
                    siteURL: siteURL,
                    category: folderStack.last
                )
            )
        } else {
            // A folder outline: remember its title as the category for children.
            outlineIsFolder.append(true)
            folderStack.append(title.isEmpty ? String(localized: "Ungrouped") : title)
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard elementName.lowercased() == "outline", let wasFolder = outlineIsFolder.popLast() else { return }
        if wasFolder, !folderStack.isEmpty {
            folderStack.removeLast()
        }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        parserError = parseError
    }
}

private extension String {
    var xmlEscaped: String {
        replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
