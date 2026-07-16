import Foundation
import Testing
@testable import NookKit

@Suite("Article date resolution")
struct ArticleDateResolverTests {
    private func utc(_ y: Int, _ mo: Int, _ d: Int) -> Date {
        var c = DateComponents(); c.year = y; c.month = mo; c.day = d
        c.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: c)!
    }

    @Test("Reads JSON-LD datePublished (the Google Developers Blog case)")
    func jsonLD() {
        let html = #"<html><head><script type="application/ld+json">{"@type":"BlogPosting","datePublished":"2026-07-09","headline":"x"}</script></head></html>"#
        #expect(ArticleDateResolver.extractDate(from: html) == utc(2026, 7, 9))
    }

    @Test("Reads article:published_time meta in either attribute order")
    func metaTag() {
        let a = #"<meta property="article:published_time" content="2026-07-16T00:33:18+00:00">"#
        let b = #"<meta content="2026-07-16T00:33:18Z" property="article:published_time">"#
        #expect(ArticleDateResolver.extractDate(from: a) == ISO8601DateFormatter().date(from: "2026-07-16T00:33:18Z"))
        #expect(ArticleDateResolver.extractDate(from: b) == ISO8601DateFormatter().date(from: "2026-07-16T00:33:18Z"))
    }

    @Test("Falls back to <time datetime>")
    func timeElement() {
        let html = #"<article><time datetime="2026-07-01">July 1</time></article>"#
        #expect(ArticleDateResolver.extractDate(from: html) == utc(2026, 7, 1))
    }

    @Test("JSON-LD wins over a less precise <time>")
    func priority() {
        let html = #"<time datetime="2020-01-01"></time><script type="application/ld+json">{"datePublished":"2026-07-09"}</script>"#
        #expect(ArticleDateResolver.extractDate(from: html) == utc(2026, 7, 9))
    }

    @Test("No date on the page returns nil")
    func none() {
        #expect(ArticleDateResolver.extractDate(from: "<html><body>no dates here</body></html>") == nil)
    }
}
