import Foundation

/// Recovers a publish date for feeds that ship none by reading it from the
/// article's own page — JSON-LD `datePublished`, an OpenGraph/article meta tag,
/// or a `<time datetime>` element. Used only for dateless items, once per
/// article, so the cost stays bounded.
enum ArticleDateResolver {
    /// Fetches `url` and extracts a publish date. Throws on a network/HTTP
    /// failure (so the caller can retry later); returns `nil` when the page
    /// loaded but carries no recognizable date (so the caller can stop trying).
    static func publishedDate(for url: URL, session: URLSession) async throws -> Date? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        guard let html = String(data: data, encoding: .utf8) else { return nil }
        return extractDate(from: html)
    }

    /// Pulls the first recognizable publish date out of a page's HTML, trying the
    /// most reliable sources first. Pure and testable.
    static func extractDate(from html: String) -> Date? {
        for candidate in candidates(in: html) {
            if let date = FeedDateParser.date(from: candidate) { return date }
        }
        return nil
    }

    private static func candidates(in html: String) -> [String] {
        var results: [String] = []
        func appendMatches(_ pattern: String, group: Int = 1) {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return }
            let ns = html as NSString
            for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
                guard match.numberOfRanges > group, match.range(at: group).location != NSNotFound else { continue }
                let value = ns.substring(with: match.range(at: group)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { results.append(value) }
            }
        }

        // JSON-LD (schema.org Article) — the most common and reliable source.
        appendMatches(#""datePublished"\s*:\s*"([^"]+)""#)
        // <meta property="article:published_time" content="…"> (either attribute order)
        appendMatches(#"<meta[^>]+(?:property|name)=["']article:published_time["'][^>]*content=["']([^"']+)["']"#)
        appendMatches(#"<meta[^>]+content=["']([^"']+)["'][^>]*(?:property|name)=["']article:published_time["']"#)
        // Other common meta names.
        appendMatches(#"<meta[^>]+(?:property|name)=["'](?:og:published_time|datePublished|publishdate|date|dc\.date|dc\.date\.issued|sailthru\.date)["'][^>]*content=["']([^"']+)["']"#)
        // <time datetime="…"> (often the visible byline date).
        appendMatches(#"<time[^>]+datetime=["']([^"']+)["']"#)
        return results
    }
}
