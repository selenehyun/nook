import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct OPMLService {
    func importFeedURLs(from fileURL: URL) throws -> [String] {
        let data = try Data(contentsOf: fileURL)
        let parser = OPMLFeedURLParser()
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
    static var opml: UTType {
        UTType(filenameExtension: "opml", conformingTo: .xml) ?? .xml
    }
}

private final class OPMLFeedURLParser: NSObject, XMLParserDelegate {
    private var parserError: Error?
    private var feedURLs: [String] = []

    func parse(data: Data) throws -> [String] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false

        guard parser.parse() else {
            throw parser.parserError ?? parserError ?? CocoaError(.fileReadCorruptFile)
        }

        return Array(Set(feedURLs)).sorted()
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard elementName.lowercased() == "outline",
              let feedURL = attributeDict["xmlUrl"] ?? attributeDict["xmlurl"],
              !feedURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        feedURLs.append(feedURL)
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
