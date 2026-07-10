import Foundation

/// Extracts the main readable content from an article's web page using
/// semantic HTML cues (`<article>`, `<main>`, `role="main"`). When a page
/// lacks those signals or yields too little text, extraction returns `nil` so
/// the caller can fall back to the RSS content.
struct ArticleReaderService {
    private let userAgent = "Nook RSS Reader"
    private let requestTimeout: TimeInterval = 15
    private let minimumContentLength = 250

    func loadMainContent(from url: URL) async -> [String]? {
        guard url.scheme == "http" || url.scheme == "https" else { return nil }

        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        request.timeoutInterval = requestTimeout

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        else {
            return nil
        }

        let paragraphs = Self.extractMainContent(from: html)
        guard let paragraphs else { return nil }

        let totalLength = paragraphs.reduce(0) { $0 + $1.count }
        guard paragraphs.isEmpty == false, totalLength >= minimumContentLength else { return nil }
        return paragraphs
    }

    static func extractMainContent(from html: String) -> [String]? {
        let body = firstGroup(in: html, pattern: "<body[^>]*>(.*)</body>") ?? html

        guard let container = mainContainer(in: body) else { return nil }

        let cleaned = removingNoise(from: container)
        let paragraphs = paragraphs(from: cleaned)
        return paragraphs.isEmpty ? nil : paragraphs
    }

    // MARK: - Semantic container

    /// Finds the best semantic main-content container. Prefers the longest
    /// `<article>`, then `<main>`, then an element with `role="main"`.
    private static func mainContainer(in html: String) -> String? {
        if let article = longestGroup(in: html, pattern: "<article[^>]*>(.*?)</article>") {
            return article
        }
        if let main = longestGroup(in: html, pattern: "<main[^>]*>(.*?)</main>") {
            return main
        }
        if let roleMain = firstGroup(in: html, pattern: "<[a-z0-9]+[^>]*role\\s*=\\s*[\"']main[\"'][^>]*>(.*?)</[a-z0-9]+>") {
            return roleMain
        }
        return nil
    }

    // MARK: - Cleaning

    private static let noiseTags = [
        "script", "style", "noscript", "svg", "nav", "aside",
        "header", "footer", "form", "figure", "button", "iframe"
    ]

    private static func removingNoise(from html: String) -> String {
        var result = html
        result = replacing(in: result, pattern: "<!--.*?-->", with: " ")
        for tag in noiseTags {
            result = replacing(in: result, pattern: "<\(tag)[^>]*>.*?</\(tag)>", with: " ")
        }
        return result
    }

    // MARK: - Paragraphs

    private static let paragraphBreak = "\u{2029}" // paragraph separator, unlikely to appear in content

    private static func paragraphs(from html: String) -> [String] {
        var text = html
        // Turn block-level boundaries into explicit paragraph breaks.
        text = replacing(in: text, pattern: "<br\\s*/?>", with: paragraphBreak)
        text = replacing(in: text, pattern: "</(p|div|li|h[1-6]|blockquote|section|pre|tr|ul|ol)>", with: paragraphBreak)
        // Drop every remaining tag.
        text = replacing(in: text, pattern: "<[^>]+>", with: " ")
        text = decodeEntities(text)

        return text
            .components(separatedBy: paragraphBreak)
            .map { $0.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 2 }
    }

    // MARK: - HTML entities

    private static let namedEntities: [String: String] = [
        "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&apos;": "'",
        "&#39;": "'", "&nbsp;": " ", "&hellip;": "…", "&mdash;": "—", "&ndash;": "–",
        "&ldquo;": "\u{201C}", "&rdquo;": "\u{201D}", "&lsquo;": "\u{2018}", "&rsquo;": "\u{2019}",
        "&middot;": "·", "&copy;": "©", "&reg;": "®", "&trade;": "™"
    ]

    private static func decodeEntities(_ text: String) -> String {
        var result = text
        for (entity, value) in namedEntities {
            result = result.replacingOccurrences(of: entity, with: value)
        }
        result = replacingByMatch(in: result, pattern: "&#(\\d+);") { digits in
            UInt32(digits).flatMap(UnicodeScalar.init).map(String.init)
        }
        result = replacingByMatch(in: result, pattern: "&#[xX]([0-9a-fA-F]+);") { hex in
            UInt32(hex, radix: 16).flatMap(UnicodeScalar.init).map(String.init)
        }
        return result
    }

    // MARK: - Regex helpers

    private static let regexOptions: NSRegularExpression.Options = [.caseInsensitive, .dotMatchesLineSeparators]

    private static func firstGroup(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: regexOptions) else { return nil }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges > 1 else { return nil }
        return ns.substring(with: match.range(at: 1))
    }

    private static func longestGroup(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: regexOptions) else { return nil }
        let ns = text as NSString
        var best: String?
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) where match.numberOfRanges > 1 {
            let candidate = ns.substring(with: match.range(at: 1))
            if candidate.count > (best?.count ?? 0) {
                best = candidate
            }
        }
        return best
    }

    private static func replacing(in text: String, pattern: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: regexOptions) else { return text }
        let ns = text as NSString
        return regex.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: ns.length), withTemplate: replacement)
    }

    private static func replacingByMatch(in text: String, pattern: String, transform: (String) -> String?) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: regexOptions) else { return text }
        let ns = text as NSString
        var result = text
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() where match.numberOfRanges > 1 {
            let captured = (text as NSString).substring(with: match.range(at: 1))
            guard let replacement = transform(captured) else { continue }
            let resultNS = result as NSString
            if match.range.location + match.range.length <= resultNS.length {
                result = resultNS.replacingCharacters(in: match.range, with: replacement)
            }
        }
        _ = ns
        return result
    }
}
