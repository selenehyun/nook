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

    @Test("Splits structural block tags into native blocks")
    func parsesStructuralBlocks() {
        let html = """
        <h2>Section <em>Title</em></h2>
        <p>Intro paragraph.</p>
        <blockquote><p>Quoted line.</p></blockquote>
        <pre><code class="language-swift">let x = 1\nlet y = 2</code></pre>
        <hr>
        <table>
        <thead><tr><th>Name</th><th>Value</th></tr></thead>
        <tbody><tr><td>Alpha</td><td>1</td></tr></tbody>
        </table>
        <audio src="/clip.mp3" title="Clip"></audio>
        """

        let blocks = HTMLContentParser.parse(html, baseURL: URL(string: "https://example.com/post")!)

        guard case .heading(let level, let headingHTML) = blocks[0] else {
            Issue.record("Expected a heading first: \(blocks)")
            return
        }
        #expect(level == 2)
        #expect(headingHTML.contains("Title"))

        guard case .text(let intro) = blocks[1] else {
            Issue.record("Expected intro text")
            return
        }
        #expect(intro.contains("Intro paragraph"))

        guard case .blockquote(let quoted) = blocks[2], case .text(let quotedText) = quoted[0] else {
            Issue.record("Expected a blockquote with nested text")
            return
        }
        #expect(quotedText.contains("Quoted line"))

        guard case .codeBlock(let code, let language) = blocks[3] else {
            Issue.record("Expected a code block")
            return
        }
        #expect(language == "swift")
        #expect(code == "let x = 1\nlet y = 2")

        guard case .thematicBreak = blocks[4] else {
            Issue.record("Expected a thematic break")
            return
        }

        guard case .table(let table) = blocks[5] else {
            Issue.record("Expected a table")
            return
        }
        #expect(table.rows.count == 2)
        #expect(table.rows[0].isHeader)
        #expect(table.rows[0].cells == ["Name", "Value"])
        #expect(!table.rows[1].isHeader)
        #expect(table.rows[1].cells.contains("Alpha"))

        guard case .audio(let audio) = blocks[6] else {
            Issue.record("Expected an audio block")
            return
        }
        #expect(audio.url.absoluteString == "https://example.com/clip.mp3")
        #expect(audio.title == "Clip")
    }

    @Test("Decodes entities in code blocks without collapsing whitespace")
    func preservesCodeFormatting() {
        let html = "<pre><code>if (a &lt; b) {\n    return &amp;value;\n}</code></pre>"

        let blocks = HTMLContentParser.parse(html, baseURL: nil)

        guard case .codeBlock(let code, _) = blocks[0] else {
            Issue.record("Expected a code block: \(blocks)")
            return
        }
        #expect(code == "if (a < b) {\n    return &value;\n}")
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
