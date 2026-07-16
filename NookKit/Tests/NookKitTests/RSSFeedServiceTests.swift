import Foundation
import Testing
@testable import NookKit

@Suite("RSS feed discovery")
struct RSSFeedServiceTests {
    @Test("HTML alternate links still win when a website advertises a feed")
    func discoversAlternateLink() async throws {
        let pageURL = URL(string: "https://example.com/posts")!
        let feedURL = URL(string: "https://example.com/posts.atom")!
        final class MockURLProtocol: URLProtocol {
            nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

            override class func canInit(with request: URLRequest) -> Bool { true }
            override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

            override func startLoading() {
                guard let handler = Self.handler else {
                    client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                    return
                }
                do {
                    let (response, data) = try handler(request)
                    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                    client?.urlProtocol(self, didLoad: data)
                    client?.urlProtocolDidFinishLoading(self)
                } catch {
                    client?.urlProtocol(self, didFailWithError: error)
                }
            }

            override func stopLoading() {}
        }

        MockURLProtocol.handler = { request in
            switch request.url {
            case let url where matches(url, pageURL):
                return response(url: pageURL, status: 200, body: htmlPage(alternateHref: "/posts.atom"))
            case let url where matches(url, feedURL):
                return response(url: feedURL, status: 200, body: atomFeedXML(feedURL: feedURL))
            default:
                return response(url: request.url ?? pageURL, status: 200, body: htmlPage())
            }
        }

        let service = makeService(using: MockURLProtocol.self)

        let parsed = try await service.fetch(url: pageURL)
        #expect(parsed.feed.feedURL == feedURL)
        #expect(parsed.articles.map(\.title) == ["Hello"])
    }

    @Test("Items without a date keep feed order via distinct fallback timestamps")
    func datelessItemsPreserveOrder() async throws {
        let feedURL = URL(string: "https://example.com/feed")!
        final class MockURLProtocol: URLProtocol {
            nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
            override class func canInit(with request: URLRequest) -> Bool { true }
            override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
            override func startLoading() {
                guard let handler = Self.handler else {
                    client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                    return
                }
                do {
                    let (response, data) = try handler(request)
                    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                    client?.urlProtocol(self, didLoad: data)
                    client?.urlProtocolDidFinishLoading(self)
                } catch {
                    client?.urlProtocol(self, didFailWithError: error)
                }
            }
            override func stopLoading() {}
        }

        MockURLProtocol.handler = { _ in
            response(url: feedURL, status: 200, body: datelessRSSXML(feedURL: feedURL))
        }

        let service = makeService(using: MockURLProtocol.self)
        let parsed = try await service.fetch(url: feedURL)

        // Feed order is preserved (top item first)…
        #expect(parsed.articles.map(\.title) == ["First", "Second", "Third"])
        // …and each gets a distinct, strictly-decreasing timestamp so the list
        // sorts newest-first instead of collapsing to one instant or reshuffling.
        let dates = parsed.articles.map(\.publishedAt)
        #expect(dates[0] > dates[1])
        #expect(dates[1] > dates[2])
    }

    @Test("Atom published/updated dates are parsed (RFC 3339 with offset)")
    func atomDatesParsed() async throws {
        let feedURL = URL(string: "https://example.com/atom")!
        final class MockURLProtocol: URLProtocol {
            nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
            override class func canInit(with request: URLRequest) -> Bool { true }
            override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
            override func startLoading() {
                guard let handler = Self.handler else {
                    client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
                }
                do {
                    let (response, data) = try handler(request)
                    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                    client?.urlProtocol(self, didLoad: data)
                    client?.urlProtocolDidFinishLoading(self)
                } catch { client?.urlProtocol(self, didFailWithError: error) }
            }
            override func stopLoading() {}
        }
        // Mirrors simonwillison.net/atom/everything: default Atom namespace, a
        // feed-level <updated> before entries, RFC 3339 dates with +00:00 offset.
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <feed xml:lang="en-us" xmlns="http://www.w3.org/2005/Atom">
          <title>Example</title>
          <updated>2026-07-16T00:33:18+00:00</updated>
          <entry>
            <title>Post</title>
            <link href="https://example.com/p" rel="alternate"/>
            <published>2026-07-15T14:21:54+00:00</published>
            <updated>2026-07-16T00:33:18+00:00</updated>
            <id>https://example.com/p</id>
            <summary type="html">hi</summary>
          </entry>
        </feed>
        """
        MockURLProtocol.handler = { _ in response(url: feedURL, status: 200, body: xml) }

        let service = makeService(using: MockURLProtocol.self)
        let parsed = try await service.fetch(url: feedURL)
        let published = try #require(parsed.articles.first?.publishedAt)
        let expected = try #require(ISO8601DateFormatter().date(from: "2026-07-15T14:21:54+00:00"))
        #expect(published == expected)
    }

    @Test("Common RSS path variants are probed when the page itself is not a feed")
    func discoversCommonFeedVariants() async throws {
        let scenarios: [(page: URL, feed: URL)] = [
            (URL(string: "https://example.com/article")!, URL(string: "https://example.com/article.rss")!),
            (URL(string: "https://example.com/blog/post")!, URL(string: "https://example.com/blog/post.atom")!),
            (URL(string: "https://example.com/press/story")!, URL(string: "https://example.com/press/story.rss")!),
            (URL(string: "https://example.com/news")!, URL(string: "https://example.com/news/feed.xml")!)
        ]

        for scenario in scenarios {
            final class MockURLProtocol: URLProtocol {
                nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

                override class func canInit(with request: URLRequest) -> Bool { true }
                override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

                override func startLoading() {
                    guard let handler = Self.handler else {
                        client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                        return
                    }
                    do {
                        let (response, data) = try handler(request)
                        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                        client?.urlProtocol(self, didLoad: data)
                        client?.urlProtocolDidFinishLoading(self)
                    } catch {
                        client?.urlProtocol(self, didFailWithError: error)
                    }
                }

                override func stopLoading() {}
            }

            MockURLProtocol.handler = { request in
                switch request.url {
                case let url where matches(url, scenario.page):
                    return response(url: scenario.page, status: 200, body: htmlPage())
                case let url where matches(url, scenario.feed):
                    return response(url: scenario.feed, status: 200, body: rssFeedXML(feedURL: scenario.feed))
                default:
                    return response(url: request.url ?? scenario.page, status: 200, body: htmlPage())
                }
            }

            let service = makeService(using: MockURLProtocol.self)
            let parsed = try await service.fetch(url: scenario.page)
            #expect(parsed.feed.feedURL == scenario.feed)
            #expect(parsed.articles.count == 1)
        }
    }
}

private extension RSSFeedServiceTests {
    func makeService(using protocolClass: URLProtocol.Type) -> RSSFeedService {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [protocolClass]
        return RSSFeedService(session: URLSession(configuration: config))
    }

    func response(url: URL, status: Int, body: String) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": contentType(for: body)]
        )!
        return (response, Data(body.utf8))
    }

    func htmlPage(alternateHref: String? = nil) -> String {
        let alternate = alternateHref.map {
            #"<link rel="alternate" type="application/rss+xml" href="\#($0)">"#
        } ?? ""
        return """
        <html>
          <head>
            \(alternate)
          </head>
          <body>Example</body>
        </html>
        """
    }

    func rssFeedXML(feedURL: URL) -> String {
        """
        <?xml version="1.0" encoding="utf-8"?>
        <rss version="2.0">
          <channel>
            <title>Example RSS</title>
            <link>\(feedURL.deletingLastPathComponent().absoluteString)</link>
            <description>Example RSS feed</description>
            <item>
              <title>Hello</title>
              <link>\(feedURL.deletingLastPathComponent().appendingPathComponent("hello").absoluteString)</link>
              <guid>\(feedURL.absoluteString)#hello</guid>
              <description>Hi</description>
              <pubDate>Tue, 11 Jul 2023 10:00:00 GMT</pubDate>
            </item>
          </channel>
        </rss>
        """
    }

    func datelessRSSXML(feedURL: URL) -> String {
        // Mirrors feeds like developers.googleblog.com: items carry no pubDate.
        """
        <?xml version="1.0" encoding="utf-8"?>
        <rss version="2.0">
          <channel>
            <title>Dateless</title>
            <link>\(feedURL.absoluteString)</link>
            <description>No item dates</description>
            <item><title>First</title><link>https://example.com/1</link><guid>g1</guid><description>a</description></item>
            <item><title>Second</title><link>https://example.com/2</link><guid>g2</guid><description>b</description></item>
            <item><title>Third</title><link>https://example.com/3</link><guid>g3</guid><description>c</description></item>
          </channel>
        </rss>
        """
    }

    func atomFeedXML(feedURL: URL) -> String {
        """
        <?xml version="1.0" encoding="utf-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom">
          <title>Example Atom</title>
          <subtitle>Example Atom feed</subtitle>
          <link rel="alternate" href="\(feedURL.deletingLastPathComponent().absoluteString)" />
          <entry>
            <title>Hello</title>
            <id>\(feedURL.absoluteString)#hello</id>
            <link rel="alternate" href="\(feedURL.deletingLastPathComponent().appendingPathComponent("hello").absoluteString)" />
            <summary>Hi</summary>
            <updated>2023-07-11T10:00:00Z</updated>
          </entry>
        </feed>
        """
    }

    func contentType(for body: String) -> String {
        body.contains("<html") ? "text/html; charset=utf-8" : "application/rss+xml; charset=utf-8"
    }

    func matches(_ actual: URL?, _ expected: URL) -> Bool {
        guard let actual else { return false }
        let normalizedActual = normalizePath(actual.path)
        let normalizedExpected = normalizePath(expected.path)
        let expectedLeaf = (expected.path as NSString).lastPathComponent
        return actual.scheme == expected.scheme
            && actual.host == expected.host
            && actual.port == expected.port
            && (normalizedActual == normalizedExpected
                || normalizedActual.hasSuffix("/\(expectedLeaf)")
                || normalizedActual.hasSuffix(expectedLeaf)
                || actual.lastPathComponent == expectedLeaf)
            && actual.query == expected.query
    }

    func normalizePath(_ path: String) -> String {
        guard path != "/" else { return "/" }
        let pieces = path.split(separator: "/", omittingEmptySubsequences: true)
        return "/" + pieces.joined(separator: "/")
    }
}
