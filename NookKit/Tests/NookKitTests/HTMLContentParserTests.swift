import Foundation
import Testing
@testable import NookKit

@Suite("Native article HTML blocks")
struct HTMLContentParserTests {
    @Test("Preserves CSS-Tricks-style media in article order")
    func preservesRichMedia() throws {
        let html = """
        <p>Before the examples.</p>
        <div><iframe src="//codepen.io/anon/embed/demo" height="450" title="CodePen Demo">Fallback</iframe></div>
        <figure><img width="1200" height="800" src="https://images.example.com/hero.png?a=1&#038;b=2"><figcaption>Image <strong>caption</strong>.</figcaption></figure>
        <figure><video width="1358" height="940" controls src="/media/demo.mp4"></video><figcaption>Video source.</figcaption></figure>
        <p>After the examples.</p>
        """

        let blocks = HTMLContentParser.parse(html, baseURL: URL(string: "https://example.com/article")!)

        #expect(blocks.count == 5)
        guard case .text(let before) = blocks[0],
              case .embed(let embed) = blocks[1],
              case .image(let image) = blocks[2],
              case .video(let video) = blocks[3],
              case .text(let after) = blocks[4] else {
            Issue.record("Unexpected block order: \(blocks)")
            return
        }
        #expect(before.contains("Before the examples"))
        #expect(embed.url.absoluteString == "https://codepen.io/anon/embed/demo")
        #expect(embed.title == "CodePen Demo")
        #expect(image.url.absoluteString == "https://images.example.com/hero.png?a=1&b=2")
        #expect(image.caption == "Image caption.")
        #expect(image.aspectRatio == 1.5)
        #expect(video.url.absoluteString == "https://example.com/media/demo.mp4")
        #expect(video.caption == "Video source.")
        #expect(after.contains("After the examples"))
    }

    @Test("Uses lazy image and nested video source URLs")
    func supportsAlternateMediaSources() {
        let html = """
        <img data-lazy-src="/lazy.png" alt="Lazy image">
        <video poster="/poster.jpg"><source src="/movie.mp4"></video>
        """

        let blocks = HTMLContentParser.parse(html, baseURL: URL(string: "https://example.com/posts/1")!)

        guard case .image(let image) = blocks[0], case .video(let video) = blocks[1] else {
            Issue.record("Expected an image followed by a video")
            return
        }
        #expect(image.url.absoluteString == "https://example.com/lazy.png")
        #expect(image.title == "Lazy image")
        #expect(video.url.absoluteString == "https://example.com/movie.mp4")
        #expect(video.posterURL?.absoluteString == "https://example.com/poster.jpg")
    }

    @Test("Reader script retains interactive embeds and has a semantic fallback")
    func readerScriptRichContentFallbacks() {
        let script = ArticleWebView(
            url: URL(string: "https://example.com/article")!,
            useReaderMode: true,
            style: ReaderStyle(),
            linkOpensInApp: true
        ).readerScript(style: ReaderStyle())

        #expect(script.contains("codepen"))
        #expect(script.contains("article .article-content"))
        #expect(script.contains("normalizeMedia"))
        #expect(script.contains("attempts < 3"))
    }
}
