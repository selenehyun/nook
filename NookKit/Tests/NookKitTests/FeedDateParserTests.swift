import Foundation
import Testing
@testable import NookKit

@Suite("Feed date parsing")
struct FeedDateParserTests {
    private func utc(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0, _ s: Int = 0) -> Date {
        var c = DateComponents()
        c.year = y; c.month = mo; c.day = d; c.hour = h; c.minute = mi; c.second = s
        c.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: c)!
    }

    @Test("RFC 3339 / ISO 8601 variants")
    func iso() throws {
        #expect(FeedDateParser.date(from: "2026-07-16T00:33:18+00:00") == utc(2026, 7, 16, 0, 33, 18))
        #expect(FeedDateParser.date(from: "2026-07-16T00:33:18Z") == utc(2026, 7, 16, 0, 33, 18))
        #expect(FeedDateParser.date(from: "2026-07-16T09:33:18+09:00") == utc(2026, 7, 16, 0, 33, 18))
        let fractional = try #require(FeedDateParser.date(from: "2026-07-16T00:33:18.500Z"))
        #expect(abs(fractional.timeIntervalSince(utc(2026, 7, 16, 0, 33, 18)) - 0.5) < 0.01)
    }

    @Test("ISO stamps missing a timezone are read as UTC")
    func noTimezone() {
        #expect(FeedDateParser.date(from: "2026-07-16T00:33:18") == utc(2026, 7, 16, 0, 33, 18))
        #expect(FeedDateParser.date(from: "2026-07-16 00:33:18") == utc(2026, 7, 16, 0, 33, 18))
    }

    @Test("ISO stamps missing seconds, and date-only")
    func partial() {
        #expect(FeedDateParser.date(from: "2026-07-16T00:33Z") == utc(2026, 7, 16, 0, 33, 0))
        #expect(FeedDateParser.date(from: "2026-07-16") == utc(2026, 7, 16))
    }

    @Test("RFC 822 (RSS pubDate) variants")
    func rfc822() {
        #expect(FeedDateParser.date(from: "Thu, 16 Jul 2026 00:33:18 +0000") == utc(2026, 7, 16, 0, 33, 18))
        #expect(FeedDateParser.date(from: "Thu, 16 Jul 2026 00:33:18 GMT") == utc(2026, 7, 16, 0, 33, 18))
        #expect(FeedDateParser.date(from: "16 Jul 2026 00:33:18 +0000") == utc(2026, 7, 16, 0, 33, 18))
    }

    @Test("Blank or unparseable input returns nil")
    func invalid() {
        #expect(FeedDateParser.date(from: "") == nil)
        #expect(FeedDateParser.date(from: "not a date") == nil)
    }
}
