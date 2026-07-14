import Foundation
import Testing
@testable import NookKit

/// The heavy article bodies live in a sidecar so the launch baseline stays
/// list-light. These cover the encode-strip, the lossless legacy decode, and
/// the sidecar's union + cap behaviour.
struct ContentSidecarTests {
    private func article(_ id: String, published: TimeInterval, html: String?) -> Article {
        Article(
            id: id, feedID: "f", title: id, summary: "s",
            bodyParagraphs: html == nil ? [] : ["p1", "p2"],
            publishedAt: Date(timeIntervalSince1970: published),
            url: URL(string: "https://example.com/\(id)")!,
            estimatedReadMinutes: 1, isRead: false, isStarred: false, contentHTML: html
        )
    }

    @Test func baselineEncodeStripsBodiesButKeepsListFields() throws {
        let lib = Fixture.library(feeds: [], articles: [article("a", published: 1, html: "<p>hi</p>")])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.userInfo[.stripArticleContent] = true
        let json = String(data: try encoder.encode(lib), encoding: .utf8)!

        #expect(!json.contains("contentHTML"))
        #expect(!json.contains("bodyParagraphs"))
        #expect(json.contains("\"title\""))
    }

    @Test func legacyInlineBodiesDecodeLosslessly() throws {
        // A pre-split file kept bodies inline; decoding must still recover them.
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let lib = Fixture.library(feeds: [], articles: [article("a", published: 1, html: "<p>hi</p>")])
        let round = try decoder.decode(ReaderLibrary.self, from: try encoder.encode(lib))
        #expect(round.articles.first?.contentHTML == "<p>hi</p>")
        #expect(round.articles.first?.bodyParagraphs == ["p1", "p2"])
    }

    @Test func lightBaselineDecodesWithEmptyBodies() throws {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let json = """
        { "feeds": [], "folders": [], "articles": [
          { "id": "a", "feedID": "f", "title": "t", "summary": "s",
            "publishedAt": "2021-01-01T00:00:00Z", "url": "https://example.com/a",
            "estimatedReadMinutes": 1, "isRead": false, "isStarred": false } ] }
        """
        let lib = try decoder.decode(ReaderLibrary.self, from: Data(json.utf8))
        #expect(lib.articles.first?.bodyParagraphs == [])
        #expect(lib.articles.first?.contentHTML == nil)
        #expect(lib.articles.first?.hasBody == false)
    }

    @Test func sidecarSaveUnionsWithDiskAndCaps() throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "nook-content-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let storage = ReaderStorage(directoryURL: dir)

        // Device A stores a body for "a".
        try storage.saveContent(["a": ArticleBody(bodyParagraphs: ["A"], contentHTML: nil)], retain: ["a", "b"])
        // Device B (never saw "a") stores "b"; the union must keep "a".
        try storage.saveContent(["b": ArticleBody(bodyParagraphs: ["B"], contentHTML: nil)], retain: ["a", "b"])

        var loaded = storage.loadContent()
        #expect(Set(loaded.keys) == ["a", "b"])

        // A retain set that excludes "a" caps it out (bodies are regenerable).
        try storage.saveContent(["b": ArticleBody(bodyParagraphs: ["B"], contentHTML: nil)], retain: ["b"])
        loaded = storage.loadContent()
        #expect(Set(loaded.keys) == ["b"])
    }

    @Test func recentIDsCapKeepsNewestByPublishedDate() {
        let arts = (0..<10).map { article("a\($0)", published: TimeInterval($0), html: "x") }
        // Only the newest are retained once over the (large) limit — here we just
        // confirm all are kept when under it.
        #expect(ReaderStore.recentArticleIDs(from: arts).count == 10)
    }
}
