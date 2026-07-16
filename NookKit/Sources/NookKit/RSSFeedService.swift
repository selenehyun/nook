import Foundation

public enum RSSFeedError: LocalizedError {
    case invalidURL(String)
    case emptyFeed(URL)
    case badStatus(Int)
    case noDiscoveredFeeds(URL)
    case parserFailure(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let value):
            String(localized: "'\(value)' is not a valid URL.", bundle: Bundle.module)
        case .emptyFeed(let url):
            String(localized: "No RSS or Atom entries were found at \(url.absoluteString).", bundle: Bundle.module)
        case .badStatus(let statusCode):
            String(localized: "The feed request failed with HTTP \(statusCode).", bundle: Bundle.module)
        case .noDiscoveredFeeds(let url):
            String(localized: "No RSS or Atom feed link was found at \(url.absoluteString).", bundle: Bundle.module)
        case .parserFailure(let message):
            String(localized: "The feed could not be parsed: \(message)", bundle: Bundle.module)
        }
    }
}

public struct RSSFeedService: Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func normalizedFeedURL(from value: String) throws -> URL {
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

    public func fetch(url: URL) async throws -> ParsedFeed {
        do {
            return try await fetchFeed(url: url)
        } catch RSSFeedError.emptyFeed, RSSFeedError.parserFailure {
            return try await discoverFeed(from: url)
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

    /// Rejects clearly malformed URLs (e.g. a doubled scheme like
    /// "https://site.comhttps://site.com") so we never fire a request that is
    /// guaranteed to fail DNS. Prevents a storm of failing requests when the
    /// stored library contains corrupt feed/site URLs.
    public static func isFetchableWebURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return false
        }
        guard let host = url.host(percentEncoded: false), host.contains(".") else {
            return false
        }
        // A valid host never contains a scheme fragment or slashes.
        if host.lowercased().contains("http") || host.contains("/") {
            return false
        }
        // A well-formed absolute URL has exactly one scheme separator.
        return url.absoluteString.components(separatedBy: "://").count == 2
    }

    /// Repairs a URL whose scheme was accidentally doubled
    /// ("https://site.comhttps://site.com" -> "https://site.com"). Returns the
    /// original when it is already well-formed or cannot be repaired.
    public static func repairedWebURL(_ url: URL) -> URL {
        guard !isFetchableWebURL(url) else { return url }

        let string = url.absoluteString
        var lastSchemeStart: String.Index?
        for marker in ["https://", "http://"] {
            var range = string.startIndex..<string.endIndex
            while let found = string.range(of: marker, options: .caseInsensitive, range: range) {
                if found.lowerBound != string.startIndex { lastSchemeStart = found.lowerBound }
                range = found.upperBound..<string.endIndex
            }
        }

        if let lastSchemeStart,
           let repaired = URL(string: String(string[lastSchemeStart...])),
           isFetchableWebURL(repaired) {
            return repaired
        }
        return url
    }

    private func fetchData(url: URL) async throws -> Data {
        guard RSSFeedService.isFetchableWebURL(url) else {
            throw RSSFeedError.invalidURL(url.absoluteString)
        }

        var request = URLRequest(url: url)
        request.setValue("Nook RSS Reader", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        let (data, response) = try await session.data(for: request)
        if let httpResponse = response as? HTTPURLResponse,
           !(200...299).contains(httpResponse.statusCode) {
            throw RSSFeedError.badStatus(httpResponse.statusCode)
        }

        return data
    }

    private func discoverFeed(from pageURL: URL) async throws -> ParsedFeed {
        let data = try await fetchData(url: pageURL)
        let html = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
        let candidates = FeedLinkDiscovery.feedDiscoveryCandidates(in: html, baseURL: pageURL)
        for candidate in candidates {
            do {
                return try await fetchFeed(url: candidate)
            } catch RSSFeedError.emptyFeed,
                    RSSFeedError.badStatus,
                    RSSFeedError.noDiscoveredFeeds,
                    RSSFeedError.parserFailure,
                    RSSFeedError.invalidURL {
                continue
            } catch {
                continue
            }
        }

        throw RSSFeedError.noDiscoveredFeeds(pageURL)
    }
}

private enum FeedLinkDiscovery {
    static func feedDiscoveryCandidates(in html: String, baseURL: URL) -> [URL] {
        let discovered = feedLinks(in: html, baseURL: baseURL)
        let probes = fallbackFeedURLs(for: baseURL)
        return orderedUniqueURLs(discovered + probes)
    }

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

    static func fallbackFeedURLs(for pageURL: URL) -> [URL] {
        let bases = fallbackBases(for: pageURL)
        var urls: [URL] = []
        for base in bases {
            urls.append(contentsOf: feedURLVariants(for: base))
        }
        return orderedUniqueURLs(urls)
    }

    private static func fallbackBases(for pageURL: URL) -> [URL] {
        var bases: [URL] = [pageURL]
        if let parent = pageURL.deletingLastPathComponentIfUseful() {
            bases.append(parent)
        }
        if let root = pageURL.rootWebURL() {
            bases.append(root)
        }
        return orderedUniqueURLs(bases)
    }

    private static func feedURLVariants(for baseURL: URL) -> [URL] {
        var variants: [URL] = []
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return variants
        }

        let path = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        let lastPathComponent = path.split(separator: "/").last.map(String.init) ?? ""
        let feedishNames = ["feed", "rss", "atom", "feed.xml", "rss.xml", "atom.xml", "index.xml"]

        func appendVariant(path: String, query: String? = nil) {
            components.percentEncodedPath = path
            components.percentEncodedQuery = query
            if let url = components.url, RSSFeedService.isFetchableWebURL(url) {
                variants.append(url)
            }
        }

        let currentBase = path.hasSuffix("/") ? String(path.dropLast()) : path
        let parentBase = (path as NSString).deletingLastPathComponent
        let bases = orderedUniqueStrings([
            currentBase,
            parentBase == currentBase ? nil : parentBase,
            "/"
        ].compactMap { $0 })

        func joined(_ base: String, _ tail: String) -> String {
            if base.isEmpty || base == "/" { return "/\(tail)" }
            return base.hasSuffix("/") ? base + tail : base + "/" + tail
        }

        for basePath in bases {
            let normalizedBase = basePath == "/" ? "" : basePath

            if !normalizedBase.isEmpty, !feedishNames.contains(lastPathComponent.lowercased()) {
                appendVariant(path: normalizedBase + ".rss")
                appendVariant(path: normalizedBase + ".xml")
                appendVariant(path: normalizedBase + ".atom")
            }

            appendVariant(path: joined(normalizedBase, "feed"))
            appendVariant(path: joined(normalizedBase, "rss"))
            appendVariant(path: joined(normalizedBase, "atom"))
            appendVariant(path: joined(normalizedBase, "feed.xml"))
            appendVariant(path: joined(normalizedBase, "rss.xml"))
            appendVariant(path: joined(normalizedBase, "atom.xml"))
            appendVariant(path: joined(normalizedBase, "index.xml"))
        }

        return variants
    }

    private static func orderedUniqueURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { seen.insert($0.absoluteString).inserted }
    }

    private static func orderedUniqueStrings(_ strings: [String]) -> [String] {
        var seen = Set<String>()
        return strings.filter { seen.insert($0).inserted }
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

private extension URL {
    func deletingLastPathComponentIfUseful() -> URL? {
        let parent = deletingLastPathComponent()
        guard parent.absoluteString != absoluteString else { return nil }
        return parent
    }

    func rootWebURL() -> URL? {
        guard let scheme, let host else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = port
        components.percentEncodedPath = "/"
        return components.url
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
        var contentType = ""
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
            let message = parser.parserError?.localizedDescription ?? parserError?.localizedDescription ?? String(localized: "Unknown parser error", bundle: Bundle.module)
            throw RSSFeedError.parserFailure(message)
        }

        let normalizedFeedTitle = feedTitle.cleanedFeedText(fallback: feedURL.host(percentEncoded: false) ?? feedURL.absoluteString)
        let siteURL = resolvedURL(from: feedSiteLink, fallback: feedURL)
        let feed = Feed(
            id: feedURL.absoluteString,
            title: normalizedFeedTitle,
            siteDescription: feedDescription.cleanedFeedText(),
            category: "",
            systemImage: "dot.radiowaves.left.and.right",
            feedURL: feedURL,
            siteURL: siteURL,
            healthScore: 1,
            lastFetchedAt: Date.now
        )

        // Base time for items that ship no parseable date. Offsetting by feed
        // position keeps the feed's own newest-first order on first fetch (item 0
        // newest); the store then pins each such article's timestamp on first
        // sight so later refreshes don't restamp and reshuffle it.
        let fallbackBase = Date.now
        let articles = articleDrafts.enumerated().compactMap { index, draft -> Article? in
            let title = draft.title.cleanedFeedText(fallback: "Untitled")
            let linkURL = resolvedURL(from: draft.link, fallback: siteURL)
            let publishedAt = FeedDateParser.date(from: draft.published)
                ?? FeedDateParser.date(from: draft.updated)
                ?? fallbackBase.addingTimeInterval(-Double(index))
            let summary = draft.summary.cleanedFeedText()
            let contentText = draft.content.cleanedFeedText(fallback: summary.isEmpty ? title : summary)
            let paragraphs = contentText.paragraphsForReader()
            let idSeed = draft.guid.cleanedFeedText(fallback: linkURL.absoluteString)
            let articleID = "\(feed.id)#\(idSeed)"

            let rawContent = draft.content.isEmpty ? draft.summary : draft.content
            let contentHTML = Self.htmlContent(raw: rawContent, declaredType: draft.contentType)

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
                isStarred: false,
                contentHTML: contentHTML
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
        } else if key == "content", currentArticle != nil, let type = attributeDict["type"] {
            // Atom declares the content type explicitly (e.g. "html", "xhtml", "text").
            currentArticle?.contentType = type
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

        // If the value is already an absolute URL (has its own scheme), use it
        // directly. Resolving an absolute string against a base can otherwise
        // concatenate the two into a malformed URL such as
        // "https://site.comhttps://site.com".
        if let absolute = URL(string: trimmed), absolute.scheme?.isEmpty == false {
            return absolute
        }

        let resolved = URL(string: trimmed, relativeTo: feedURL)?.absoluteURL ?? fallback
        return RSSFeedService.isFetchableWebURL(resolved) ? resolved : fallback
    }

    /// Returns the raw content as HTML when the feed declares an HTML type
    /// (Atom `type="html"`/`"xhtml"`) or, when unspecified (RSS), when the
    /// content actually contains markup. Returns `nil` for plain text.
    private static func htmlContent(raw: String, declaredType: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let type = declaredType.lowercased()
        let isHTML: Bool
        if type.contains("html") {
            isHTML = true
        } else if type == "text" {
            isHTML = false
        } else {
            isHTML = trimmed.containsHTMLMarkup
        }

        return isHTML ? trimmed : nil
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
        let decoded = withoutTags.decodingHTMLEntities()
        let normalized = decoded
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return normalized.isEmpty ? fallback : normalized
    }

    /// Decodes HTML entities in feed text. Named entities are decoded first so a
    /// double-encoded reference (e.g. "&amp;#039;", common in RSS titles)
    /// collapses to "&#039;" and is then caught by the numeric pass — turning
    /// "&#039;" into "'". Handles decimal and hex numeric references.
    func decodingHTMLEntities() -> String {
        let named: [String: String] = [
            "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
            "&apos;": "'", "&nbsp;": " ", "&hellip;": "…", "&mdash;": "—",
            "&ndash;": "–", "&rsquo;": "\u{2019}", "&lsquo;": "\u{2018}",
            "&ldquo;": "\u{201C}", "&rdquo;": "\u{201D}", "&middot;": "·",
        ]
        var text = self
        for (entity, replacement) in named {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }

        guard text.contains("&#"),
              let regex = try? NSRegularExpression(pattern: "&#([xX])?([0-9a-fA-F]+);") else {
            return text
        }
        let ns = text as NSString
        var result = ""
        var cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let isHex = match.range(at: 1).location != NSNotFound
            let digits = ns.substring(with: match.range(at: 2))
            if let code = UInt32(digits, radix: isHex ? 16 : 10), let scalar = Unicode.Scalar(code) {
                result.append(Character(scalar))
            } else {
                result += ns.substring(with: match.range)
            }
            cursor = match.range.location + match.range.length
        }
        result += ns.substring(from: cursor)
        return result
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

    var containsHTMLMarkup: Bool {
        range(of: "<[a-zA-Z/][^>]*>", options: .regularExpression) != nil
    }
}
