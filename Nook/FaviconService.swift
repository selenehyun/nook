import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Fetches a website's favicon based on a feed's site link. It first tries to
/// discover an icon declared in the page `<head>` (preferring the higher-res
/// `apple-touch-icon`), then falls back to `/favicon.ico` at the host root.
struct FaviconService {
    private let userAgent = "Nook RSS Reader"
    private let requestTimeout: TimeInterval = 10
    private let maxIconBytes = 2_000_000

    func fetchFavicon(for siteURL: URL) async -> Data? {
        for candidate in await iconCandidates(for: siteURL) {
            if let data = await downloadIcon(from: candidate) {
                return data
            }
        }
        return nil
    }

    private func iconCandidates(for siteURL: URL) async -> [URL] {
        var candidates = await discoverIconURLs(from: siteURL)

        if let scheme = siteURL.scheme,
           let host = siteURL.host(percentEncoded: false),
           let root = URL(string: "\(scheme)://\(host)/favicon.ico") {
            candidates.append(root)
        }

        var seen = Set<URL>()
        return candidates.filter { seen.insert($0).inserted }
    }

    private func discoverIconURLs(from siteURL: URL) async -> [URL] {
        var request = URLRequest(url: siteURL)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = requestTimeout

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        else {
            return []
        }

        let base = http.url ?? siteURL
        return Self.iconHrefs(in: html).compactMap { href in
            URL(string: href, relativeTo: base)?.absoluteURL
        }
    }

    private func downloadIcon(from url: URL) async -> Data? {
        guard url.scheme == "http" || url.scheme == "https" else { return nil }

        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = requestTimeout

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              !data.isEmpty,
              data.count <= maxIconBytes
        else {
            return nil
        }

        #if canImport(AppKit)
        guard let image = NSImage(data: data), image.size.width > 0, image.size.height > 0 else {
            return nil
        }
        #endif

        return data
    }

    /// Extracts `href` values from `<link rel="…icon…">` tags, ordered so that
    /// an `apple-touch-icon` (typically a crisp PNG) comes first.
    static func iconHrefs(in html: String) -> [String] {
        guard let linkRegex = try? NSRegularExpression(
            pattern: "<link\\b[^>]*>",
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else {
            return []
        }

        let ns = html as NSString
        var found: [(rank: Int, href: String)] = []

        for match in linkRegex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let tag = ns.substring(with: match.range)
            guard tag.range(of: "rel", options: .caseInsensitive) != nil,
                  let rel = attribute("rel", in: tag), rel.range(of: "icon", options: .caseInsensitive) != nil,
                  let href = attribute("href", in: tag), !href.isEmpty
            else {
                continue
            }
            found.append((rel.range(of: "apple-touch", options: .caseInsensitive) != nil ? 0 : 1, href))
        }

        return found.sorted { $0.rank < $1.rank }.map(\.href)
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: "\(name)\\s*=\\s*[\"']([^\"']+)[\"']",
            options: [.caseInsensitive]
        ) else {
            return nil
        }

        let ns = tag as NSString
        guard let match = regex.firstMatch(in: tag, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges > 1 else {
            return nil
        }
        return ns.substring(with: match.range(at: 1))
    }
}

#if canImport(AppKit)
extension NSImage {
    /// A normalized PNG representation, used to cache favicons in a consistent
    /// format regardless of the source (ICO, PNG, …).
    func pngData() -> Data? {
        guard let tiff = tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else {
            return nil
        }
        return bitmap.representation(using: .png, properties: [:])
    }
}
#endif
