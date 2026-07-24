import Foundation
import Testing
@testable import NookKit

@Suite("Native reader Markdown export")
struct ArticleMarkdownTests {
    private let baseURL = URL(string: "https://example.com/articles/story")!

    @Test("Inline formatting, links, entities, and hard line breaks survive")
    func inlineFormatting() {
        let html = """
        <p>Hello &amp; <strong>bold</strong>, <em>italics</em>, <del>gone</del>,
        <code>a`b</code>, and <a href="/guide" title="Guide">a link</a>.<br>Next line.</p>
        """

        let markdown = ArticleMarkdown.convert(html: html, baseURL: baseURL)

        let expected = "Hello & **bold**, *italics*, ~~gone~~, ``a`b``, and "
            + "[a link](<https://example.com/guide> \"Guide\").  \nNext line."
        #expect(markdown == expected)
    }

    @Test("Headings, quotes, nested lists, and rules keep document structure")
    func structuralBlocks() {
        let html = """
        <h2>Section</h2>
        <blockquote><p>Quoted text</p><ul><li>One</li><li>Two</li></ul></blockquote>
        <ol><li>First<ul><li>Nested</li></ul></li><li>Second</li></ol>
        <hr>
        """

        let markdown = ArticleMarkdown.convert(html: html, baseURL: baseURL)

        let expected = """
        ## Section

        > Quoted text
        >
        > - One
        > - Two

        """
            + "\n1. First\n   \n   - Nested\n2. Second\n\n---"
        #expect(markdown == expected)
    }

    @Test("Code blocks preserve language, indentation, and embedded fences")
    func codeBlocks() {
        let html = """
        <pre><code class="language-swift">let value = ```


          print(value)</code></pre>
        """

        let markdown = ArticleMarkdown.convert(html: html, baseURL: baseURL)

        #expect(markdown == """
        ````swift
        let value = ```


          print(value)
        ````
        """)
    }

    @Test("Simple tables become GFM pipe tables")
    func simpleTable() {
        let html = """
        <table>
          <tr><th>Name</th><th>Value</th></tr>
          <tr><td><strong>A</strong></td><td>1 | 2</td></tr>
        </table>
        """

        let markdown = ArticleMarkdown.convert(html: html, baseURL: baseURL)

        #expect(markdown == """
        | Name | Value |
        | --- | --- |
        | **A** | 1 \\| 2 |
        """)
    }

    @Test("Tables without a header keep every data row")
    func headerlessTable() {
        let html = """
        <table>
          <tr><td>A</td><td>1</td></tr>
          <tr><td>B</td><td>2</td></tr>
        </table>
        """

        let markdown = ArticleMarkdown.convert(html: html, baseURL: baseURL)

        #expect(markdown == """
        |  |  |
        | --- | --- |
        | A | 1 |
        | B | 2 |
        """)
    }

    @Test("Span-bearing tables remain valid Markdown with raw HTML")
    func spanningTable() {
        let html = """
        <table>
          <tr><th colspan="2"><strong>Heading</strong></th></tr>
          <tr><td rowspan="2">A</td><td>B</td></tr>
        </table>
        """

        let markdown = ArticleMarkdown.convert(html: html, baseURL: baseURL)

        #expect(markdown.contains("<table>"))
        #expect(markdown.contains(#"<th colspan="2"><strong>Heading</strong></th>"#))
        #expect(markdown.contains(#"<td rowspan="2">A</td>"#))
    }

    @Test("Images, video, audio, and embeds retain their destinations and captions")
    func media() {
        let html = """
        <figure><img src="/image.png" alt="Diagram"><figcaption>Figure one</figcaption></figure>
        <video src="/movie.mp4" poster="/poster.jpg" title="Demo"></video>
        <audio><source src="/audio.mp3"></audio>
        <iframe src="https://video.example/embed/7" title="Interview"></iframe>
        """

        let markdown = ArticleMarkdown.convert(html: html, baseURL: baseURL)

        #expect(markdown == """
        ![Diagram](<https://example.com/image.png>)

        *Figure one*

        [![Demo](<https://example.com/poster.jpg>)](<https://example.com/movie.mp4>)

        [Audio: Audio](<https://example.com/audio.mp3>)

        [Interview](<https://video.example/embed/7>)
        """)
    }

    @Test("Plain article paragraphs are escaped and separated")
    func plainParagraphs() {
        let markdown = ArticleMarkdown.convert(paragraphs: [
            "A *literal* marker",
            "A [bracket] and_under_score",
        ])

        #expect(markdown == """
        A \\*literal\\* marker

        A \\[bracket\\] and\\_under\\_score
        """)
    }

    @Test("Streaming mixed text exports the visible replacement")
    func mixedText() {
        let blocks: [HTMLContentBlock] = [
            .mixedText(parts: [
                .html("<strong>Done</strong> "),
                .streaming(original: "original", text: "translated"),
            ], headingLevel: nil),
        ]

        #expect(ArticleMarkdown.render(blocks, baseURL: baseURL) == "**Done** translated")
    }
}
