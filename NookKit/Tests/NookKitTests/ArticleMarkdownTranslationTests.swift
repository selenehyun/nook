import Foundation
import Testing
@testable import NookKit

@Suite("Gemini Markdown article translation")
struct ArticleMarkdownTranslationTests {
    private let baseURL = URL(string: "https://example.com/articles/story")!

    @Test("Template protects non-translatable media and keeps block identity")
    func templateProtection() {
        let image = HTMLMedia(
            url: URL(string: "https://example.com/diagram.png")!,
            title: "Diagram",
            caption: nil,
            posterURL: nil,
            aspectRatio: nil
        )
        let blocks: [HTMLContentBlock] = [
            .heading(level: 2, html: "Introduction"),
            .text("<p>Hello <a href=\"/guide\">reader</a>.</p>"),
            .codeBlock(code: "let value = 1", language: "swift"),
            .image(image),
        ]

        let template = MarkdownTranslationTemplate(
            title: "A story",
            blocks: blocks,
            baseURL: baseURL
        )

        #expect(template.units.map(\.id) == ["title", "block-0", "block-1"])
        #expect(template.protectedBlocks[2] == blocks[2])
        #expect(template.protectedBlocks[3] == blocks[3])
        #expect(template.sourceMarkdown.contains("<!--NOOK:PROTECTED:2-->"))
        #expect(template.sourceMarkdown.contains("<!--NOOK:PROTECTED:3-->"))
        #expect(template.batches().first?.prompt.contains("<!--NOOK:BEGIN:title-->") == true)

        let assembled = template.assembledMarkdown(translations: [
            "block-0": "## 소개",
            "block-1": "안녕하세요, [독자](https://example.com/guide)님.",
        ])
        let parsed = template.parsedBlocks(markdown: assembled)
        #expect(parsed?.count == blocks.count)
        #expect(parsed?[2] == blocks[2])
        #expect(parsed?[3] == blocks[3])
    }

    @Test("Cumulative stream exposes complete blocks and the active typing block")
    func streamProjection() {
        let raw = """
        <!--NOOK:BEGIN:title-->
        번역 제목
        <!--NOOK:END:title-->

        <!--NOOK:BEGIN:block-0-->
        ## 번역 중
        """

        let snapshot = MarkdownTranslationStream.parse(
            raw,
            expectedIDs: ["title", "block-0"]
        )

        #expect(snapshot.completed["title"] == "번역 제목")
        #expect(snapshot.activeID == "block-0")
        #expect(MarkdownTranslationStream.plainProjection(snapshot.activeText) == "번역 중")
        #expect(snapshot.order == ["title", "block-0"])
    }

    @Test("Direct parser retains native Markdown structure and destinations")
    func nativeParsing() throws {
        let markdown = """
        ## 안내

        [문서](/guide)를 읽으세요.

        - 첫째
        - **둘째**

        ```swift
        let answer = 42
        ```
        """

        let blocks = try #require(
            MarkdownNativeParser.blocks(
                from: markdown,
                baseURL: baseURL,
                protectedBlocks: [:]
            )
        )

        #expect(blocks.count == 4)
        #expect(blocks[0] == .heading(level: 2, html: "안내"))
        if case .text(let html) = blocks[1] {
            #expect(html.contains(#"href="https://example.com/guide""#))
            #expect(html.contains("문서"))
        } else {
            Issue.record("Expected a native text block")
        }
        if case .list(let ordered, let items) = blocks[2] {
            #expect(!ordered)
            #expect(items.count == 2)
        } else {
            Issue.record("Expected a native list block")
        }
        #expect(blocks[3] == .codeBlock(code: "let answer = 42\n", language: "swift"))
    }

    @Test("Validator accepts translated prose but rejects changed link targets")
    func structureValidation() {
        let source = "Read [the guide](https://example.com/guide)."
        let valid = "[안내서](https://example.com/guide)를 읽으세요."
        let changedURL = "[안내서](https://malicious.example/guide)를 읽으세요."

        #expect(MarkdownTranslationValidator.accepts(
            source: source,
            output: valid,
            language: "Korean"
        ))
        #expect(!MarkdownTranslationValidator.accepts(
            source: source,
            output: changedURL,
            language: "Korean"
        ))
    }

    @Test("Current Gemini tiers are explicit and cache-stable")
    func modelTiers() {
        #expect(GeminiTranslator.Model.flashLite.rawValue == "gemini-3.5-flash-lite")
        #expect(GeminiTranslator.Model.flash.rawValue == "gemini-3.6-flash")
    }
}
