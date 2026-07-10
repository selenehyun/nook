import Foundation

enum RSSFeedError: LocalizedError {
    case invalidURL(String)
    case emptyFeed(URL)
    case badStatus(Int)
    case noDiscoveredFeeds(URL)
    case parserFailure(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let value):
            String(localized: "'\(value)' is not a valid URL.")
        case .emptyFeed(let url):
            String(localized: "No RSS or Atom entries were found at \(url.absoluteString).")
        case .badStatus(let statusCode):
            String(localized: "The feed request failed with HTTP \(statusCode).")
        case .noDiscoveredFeeds(let url):
            String(localized: "No RSS or Atom feed link was found at \(url.absoluteString).")
        case .parserFailure(let message):
            String(localized: "The feed could not be parsed: \(message)")
        }
    }
}

struct RSSFeedService {
    func normalizedFeedURL(from value: String) throws -> URL {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw RSSFeedError.invalidURL(value)
        }

        let valueWithScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: valueWithScheme), let scheme = url.scheme, !scheme.isEmpty else {
            throw RSSFeedError.invalidURL(value)
        }

        return url
    }

    func fetch(url: URL) async throws -> ParsedFeed {
        do {
            return try await fetchFeed(url: url)
        } catch RSSFeedError.emptyFeed, RSSFeedError.parserFailure {
            let discoveredURL = try await discoverFeedURL(from: url)
            return try await fetchFeed(url: discoveredURL)
        }
    }

    private func fetchFeed(url: URL) async throws -> ParsedFeed {
        let data = try await fetchData(url: url)
        let parser = FeedXMLParser(feedURL: url)
        let parsedFeed = try parser.parse(data: data)
        guard !parsedFeed.articles.isEmpty else {
            throw RSSFeedError.emptyFeed(url)
        }

        return parsedFeed
    }

    private func fetchData(url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("Nook RSS Reader", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        if let httpResponse = response as? HTTPURLResponse,
           !(200...299).contains(httpResponse.statusCode) {
            throw RSSFeedError.badStatus(httpResponse.statusCode)
        }

        return data
    }

    private func discoverFeedURL(from pageURL: URL) async throws -> URL {
        let data = try await fetchData(url: pageURL)
        let html = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
        let links = FeedLinkDiscovery.feedLinks(in: html, baseURL: pageURL)
        guard let firstLink = links.first else {
            throw RSSFeedError.noDiscoveredFeeds(pageURL)
        }

        return firstLink
    }
}

private enum FeedLinkDiscovery {
    static func feedLinks(in html: String, baseURL: URL) -> [URL] {
        linkTags(in: html).compactMap { tag -> URL? in
            let attributes = attributes(in: tag)
            let rel = attributes["rel"]?.lowercased() ?? ""
            let type = attributes["type"]?.lowercased() ?? ""

            guard rel.contains("alternate"),
                  type.contains("rss") || type.contains("atom") || type.contains("xml"),
                  let href = attributes["href"],
                  !href.isEmpty else {
                return nil
            }

            return URL(string: href, relativeTo: baseURL)?.absoluteURL
        }
    }

    private static func linkTags(in html: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"<link\s+[^>]*>"#, options: [.caseInsensitive]) else {
            return []
        }

        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        return regex.matches(in: html, range: range).compactMap { match in
            guard let range = Range(match.range, in: html) else { return nil }
            return String(html[range])
        }
    }

    private static func attributes(in tag: String) -> [String: String] {
        guard let regex = try? NSRegularExpression(
            pattern: #"([A-Za-z_:][-A-Za-z0-9_:.]*)\s*=\s*["']([^"']+)["']"#,
            options: []
        ) else {
            return [:]
        }

        let range = NSRange(tag.startIndex..<tag.endIndex, in: tag)
        return regex.matches(in: tag, range: range).reduce(into: [:]) { result, match in
            guard match.numberOfRanges == 3,
                  let keyRange = Range(match.range(at: 1), in: tag),
                  let valueRange = Range(match.range(at: 2), in: tag) else {
                return
            }

            result[String(tag[keyRange]).lowercased()] = String(tag[valueRange])
        }
    }
}

private final class FeedXMLParser: NSObject, XMLParserDelegate {
    private enum FeedFormat {
        case unknown
        case rss
        case atom
    }

    private struct ArticleDraft {
        var title = ""
        var link = ""
        var guid = ""
        var summary = ""
        var content = ""
        var published = ""
        var updated = ""
    }

    private let feedURL: URL
    private var parserError: Error?
    private var format = FeedFormat.unknown
    private var elementStack: [String] = []
    private var currentText = ""
    private var feedTitle = ""
    private var feedDescription = ""
    private var feedSiteLink = ""
    private var currentArticle: ArticleDraft?
    private var articleDrafts: [ArticleDraft] = []

    init(feedURL: URL) {
        self.feedURL = feedURL
    }

    func parse(data: Data) throws -> ParsedFeed {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false

        guard parser.parse() else {
            let message = parser.parserError?.localizedDescription ?? parserError?.localizedDescription ?? String(localized: "Unknown parser error")
            throw RSSFeedError.parserFailure(message)
        }

        let normalizedFeedTitle = feedTitle.cleanedFeedText(fallback: feedURL.host(percentEncoded: false) ?? feedURL.absoluteString)
        let siteURL = resolvedURL(from: feedSiteLink, fallback: feedURL)
        let feed = Feed(
            id: feedURL.absoluteString,
            title: normalizedFeedTitle,
            siteDescription: feedDescription.cleanedFeedText(),
            category: "Feeds",
            systemImage: "dot.radiowaves.left.and.right",
            feedURL: feedURL,
            siteURL: siteURL,
            healthScore: 1,
            lastFetchedAt: Date.now
        )

        let articles = articleDrafts.compactMap { draft -> Article? in
            let title = draft.title.cleanedFeedText(fallback: "Untitled")
            let linkURL = resolvedURL(from: draft.link, fallback: siteURL)
            let publishedAt = FeedDateParser.date(from: draft.published) ?? FeedDateParser.date(from: draft.updated) ?? Date.now
            let summary = draft.summary.cleanedFeedText()
            let contentText = draft.content.cleanedFeedText(fallback: summary.isEmpty ? title : summary)
            let paragraphs = contentText.paragraphsForReader()
            let idSeed = draft.guid.cleanedFeedText(fallback: linkURL.absoluteString)
            let articleID = "\(feed.id)#\(idSeed)"

            return Article(
                id: articleID,
                feedID: feed.id,
                title: title,
                summary: summary.isEmpty ? contentText.prefixText(maxLength: 240) : summary.prefixText(maxLength: 240),
                bodyParagraphs: paragraphs.isEmpty ? [summary.isEmpty ? title : summary] : paragraphs,
                publishedAt: publishedAt,
                url: linkURL,
                estimatedReadMinutes: Article.readingMinutes(for: paragraphs),
                isRead: false,
                isStarred: false
            )
        }

        return ParsedFeed(feed: feed, articles: articles)
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let key = elementName.lowercased()
        elementStack.append(key)
        currentText = ""

        if key == "rss" {
            format = .rss
        } else if key == "feed" {
            format = .atom
        } else if key == "item" {
            currentArticle = ArticleDraft()
        } else if key == "entry" {
            currentArticle = ArticleDraft()
        } else if format == .atom, key == "link" {
            handleAtomLink(attributeDict)
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let string = String(data: CDATABlock, encoding: .utf8) {
            currentText += string
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let key = elementName.lowercased()
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

        switch format {
        case .rss:
            handleRSSEndElement(key: key, text: text)
        case .atom:
            handleAtomEndElement(key: key, text: text)
        case .unknown:
            break
        }

        if key == "item" || key == "entry" {
            if let currentArticle {
                articleDrafts.append(currentArticle)
            }
            currentArticle = nil
        }

        if !elementStack.isEmpty {
            elementStack.removeLast()
        }
        currentText = ""
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        parserError = parseError
    }

    private func handleRSSEndElement(key: String, text: String) {
        if currentArticle != nil {
            switch key {
            case "title":
                currentArticle?.title += text
            case "link":
                currentArticle?.link += text
            case "guid":
                currentArticle?.guid += text
            case "description":
                currentArticle?.summary += text
            case "content:encoded", "encoded":
                currentArticle?.content += text
            case "pubdate", "published":
                currentArticle?.published += text
            case "updated", "dc:date":
                currentArticle?.updated += text
            default:
                break
            }
        } else if elementStack.contains("channel") {
            switch key {
            case "title":
                feedTitle += text
            case "description":
                feedDescription += text
            case "link":
                feedSiteLink += text
            default:
                break
            }
        }
    }

    private func handleAtomEndElement(key: String, text: String) {
        if currentArticle != nil {
            switch key {
            case "title":
                currentArticle?.title += text
            case "id":
                currentArticle?.guid += text
            case "summary":
                currentArticle?.summary += text
            case "content":
                currentArticle?.content += text
            case "published":
                currentArticle?.published += text
            case "updated":
                currentArticle?.updated += text
            default:
                break
            }
        } else {
            switch key {
            case "title":
                feedTitle += text
            case "subtitle":
                feedDescription += text
            default:
                break
            }
        }
    }

    private func handleAtomLink(_ attributes: [String: String]) {
        guard let href = attributes["href"] else { return }
        let rel = attributes["rel"] ?? "alternate"

        if currentArticle != nil {
            if currentArticle?.link.isEmpty == true, rel == "alternate" || rel.isEmpty {
                currentArticle?.link = href
            }
        } else if feedSiteLink.isEmpty, rel == "alternate" || rel.isEmpty {
            feedSiteLink = href
        }
    }

    private func resolvedURL(from value: String, fallback: URL) -> URL {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return fallback
        }

        return URL(string: trimmed, relativeTo: feedURL)?.absoluteURL ?? fallback
    }
}

private enum FeedDateParser {
    static func date(from value: String) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let isoFormatter = ISO8601DateFormatter()
        if let date = isoFormatter.date(from: trimmed) {
            return date
        }

        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalFormatter.date(from: trimmed) {
            return date
        }

        let rssFormats = [
            "EEE, d MMM yyyy HH:mm:ss Z",
            "EEE, dd MMM yyyy HH:mm:ss Z",
            "EEE, d MMM yyyy HH:mm:ss zzz",
            "EEE, dd MMM yyyy HH:mm:ss zzz",
            "d MMM yyyy HH:mm:ss Z",
            "dd MMM yyyy HH:mm:ss Z"
        ]

        return rssFormats.lazy
            .map(makeFormatter)
            .compactMap { $0.date(from: trimmed) }
            .first
    }

    private static func makeFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter
    }
}

private extension String {
    func cleanedFeedText(fallback: String = "") -> String {
        let withoutTags = replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let decoded = withoutTags
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
        let normalized = decoded
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return normalized.isEmpty ? fallback : normalized
    }

    func paragraphsForReader() -> [String] {
        let normalized = cleanedFeedText()
        guard !normalized.isEmpty else { return [] }

        let sentenceBreaks = normalized
            .replacingOccurrences(of: ". ", with: ".\n")
            .replacingOccurrences(of: "? ", with: "?\n")
            .replacingOccurrences(of: "! ", with: "!\n")

        let sentences = sentenceBreaks
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.isEmpty }

        var paragraphs: [String] = []
        var current = ""

        for sentence in sentences {
            if current.count + sentence.count > 520, !current.isEmpty {
                paragraphs.append(current)
                current = sentence
            } else {
                current = current.isEmpty ? sentence : "\(current) \(sentence)"
            }
        }

        if !current.isEmpty {
            paragraphs.append(current)
        }

        return paragraphs
    }

    func prefixText(maxLength: Int) -> String {
        if count <= maxLength {
            return self
        }

        return "\(prefix(maxLength).trimmingCharacters(in: .whitespacesAndNewlines))..."
    }
}
