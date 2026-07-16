import Foundation
import ImageIO
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Fetches a website's favicon based on a feed's site link. It first tries to
/// discover an icon declared in the page `<head>` (preferring the higher-res
/// `apple-touch-icon`), then falls back to `/favicon.ico` at the host root.
public struct FaviconService: Sendable {
    private let userAgent = "Nook RSS Reader"
    private let maxIconBytes = 2_000_000

    public init() {}

    /// A dedicated session with a short timeout and a small per-host connection
    /// cap so favicon fetches can't saturate the network stack.
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 12
        config.httpMaximumConnectionsPerHost = 2
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    private enum IconResult {
        case success(Data)
        case notFound
        case hostUnreachable
    }

    public func fetchFavicon(for siteURL: URL) async -> Data? {
        // Skip malformed site URLs (e.g. a doubled scheme) so we don't fire a
        // request that is guaranteed to fail.
        guard RSSFeedService.isFetchableWebURL(siteURL) else { return nil }

        // Try the well-known icon paths first — this avoids downloading and
        // parsing the full HTML page for the common case where a site has a
        // standard favicon, which matters a lot across a large library.
        for candidate in wellKnownIconURLs(for: siteURL) {
            switch await downloadIcon(from: candidate) {
            case .success(let data):
                return data
            case .hostUnreachable:
                // The host is down/slow; further requests to it would also fail.
                return nil
            case .notFound:
                continue
            }
        }

        // Fall back to icons declared in a page's <head>. Check the site homepage
        // first — that's where icons are usually declared, and a feed's own
        // site URL is often a non-HTML endpoint (e.g. `/rss/`) with no <head>.
        for page in discoveryPages(for: siteURL) {
            for candidate in await discoverIconURLs(from: page) {
                if case .success(let data) = await downloadIcon(from: candidate) {
                    return data
                }
            }
        }
        return nil
    }

    /// Pages to scan for `<link rel="icon">`, homepage first, deduplicated.
    private func discoveryPages(for siteURL: URL) -> [URL] {
        var pages: [URL] = []
        if let scheme = siteURL.scheme, let host = siteURL.host(percentEncoded: false),
           let root = URL(string: "\(scheme)://\(host)/") {
            pages.append(root)
        }
        if !pages.contains(where: { $0 == siteURL }) {
            pages.append(siteURL)
        }
        return pages
    }

    private func wellKnownIconURLs(for siteURL: URL) -> [URL] {
        guard let scheme = siteURL.scheme, let host = siteURL.host(percentEncoded: false) else {
            return []
        }
        return ["/apple-touch-icon.png", "/favicon.ico"].compactMap {
            URL(string: "\(scheme)://\(host)\($0)")
        }
    }

    private func discoverIconURLs(from siteURL: URL) async -> [URL] {
        var request = URLRequest(url: siteURL)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        guard let (data, response) = try? await session.data(for: request),
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

    private func downloadIcon(from url: URL) async -> IconResult {
        guard url.scheme == "http" || url.scheme == "https" else { return .notFound }

        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  !data.isEmpty,
                  data.count <= maxIconBytes else {
                return .notFound
            }

            guard let usable = Self.decodableIconData(data) else { return .notFound }
            return .success(usable)
        } catch let error as URLError {
            switch error.code {
            case .timedOut, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
                 .networkConnectionLost, .notConnectedToInternet:
                return .hostUnreachable
            default:
                return .notFound
            }
        } catch {
            return .notFound
        }
    }

    /// Returns icon bytes the app can actually render. If the platform image
    /// type already decodes them (e.g. PNG/JPEG anywhere, ICO on macOS), the
    /// original bytes are kept. Otherwise ImageIO decodes them (it handles ICO on
    /// iOS, which `UIImage` does not) and they're re-encoded as PNG so both the
    /// validation here and later display succeed. `nil` when nothing can decode
    /// it (e.g. SVG).
    static func decodableIconData(_ data: Data) -> Data? {
        if let image = PlatformImage(data: data), image.size.width > 0, image.size.height > 0 {
            return data
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
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
