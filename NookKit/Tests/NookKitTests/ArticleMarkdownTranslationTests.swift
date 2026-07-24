import Foundation
import Testing
@testable import NookKit

#if canImport(AppKit)
import AppKit
#endif

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

    @Test("Transport markers can never enter the visible streaming projection")
    func markerFragmentsAreNeverVisible() {
        let snapshots = [
            "번역된 제목<",
            "번역된 제목<!",
            "번역된 제목<!-",
            "번역된 제목<!--",
            "번역된 제목<!--NOOK",
            "번역된 제목<!--NOOK:END:title",
            "번역된 제목<!-- NOOK : END : title -->",
        ]

        for snapshot in snapshots {
            let visible = MarkdownTranslationStream.plainProjection(snapshot)
            #expect(visible == "번역된 제목")
            #expect(!visible.localizedCaseInsensitiveContains("NOOK"))
            #expect(!visible.contains("<!--"))
        }
    }

    @Test("Parser consumes harmless marker whitespace and case variations")
    func flexibleMarkerParsing() {
        let raw = """
        <!-- nook : begin : TITLE -->
        번역 제목
        <!-- NOOK : END : title -->
        """
        let snapshot = MarkdownTranslationStream.parse(raw, expectedIDs: ["title"])

        #expect(snapshot.activeID == nil)
        #expect(snapshot.completed["title"] == "번역 제목")
        #expect(snapshot.order == ["title"])
    }

    @Test("A missing END cannot merge the next content block into a heading")
    func missingEndKeepsBlockBoundary() {
        let raw = """
        <!--NOOK:BEGIN:block-0-->
        ## 번역 소제목
        <!--NOOK:BEGIN:block-1-->
        다음 본문입니다.
        <!--NOOK:END:block-1-->
        """
        let snapshot = MarkdownTranslationStream.parse(
            raw,
            expectedIDs: ["block-0", "block-1"]
        )

        #expect(snapshot.activeID == nil)
        #expect(snapshot.completed["block-0"] == nil)
        #expect(snapshot.completed["block-1"] == "다음 본문입니다.")
    }

    @Test("A malformed stream tail preserves completed translations for recovery")
    func recoveryKeepsCompletedPrefix() {
        let units = [
            MarkdownTranslationTemplate.Unit(
                id: "block-0",
                blockIndex: 0,
                source: "First paragraph."
            ),
            MarkdownTranslationTemplate.Unit(
                id: "block-1",
                blockIndex: 1,
                source: "Second paragraph."
            ),
        ]
        let snapshot = MarkdownTranslationStream.parse(
            """
            <!--NOOK:BEGIN:block-0-->
            첫 번째 문단입니다.
            <!--NOOK:END:block-0-->
            <!--NOOK:BEGIN:block-1-->
            두 번째
            """,
            expectedIDs: Set(units.map(\.id))
        )

        let partition = MarkdownTranslationRecovery.partition(
            units: units,
            snapshot: snapshot,
            language: "Korean"
        )

        #expect(partition.translations == ["block-0": "첫 번째 문단입니다."])
        #expect(partition.unresolved.map(\.id) == ["block-1"])
    }

    @Test("A live heading projection is always bounded to one heading line")
    func liveHeadingStaysHeading() {
        let live = MarkdownTranslationStream.liveProjection(
            """
            ## 번역 소제목

            다음 본문이 잘못 추가되었습니다.
            """,
            matching: "## Original heading"
        )

        #expect(live == "번역 소제목")
        #expect(!live.contains("다음 본문"))
    }

    @Test("Streaming Markdown hides syntax and applies completed inline styles")
    func streamingInlineFormatting() throws {
        let rendered = StreamingMarkdownFormatter.attributed(
            "**굵게**와 <u>밑줄</u>, [링크](https://example.com)를 표시합니다.",
            baseSize: 17
        )
        #expect(String(rendered.characters) == "굵게와 밑줄, 링크를 표시합니다.")

        #if canImport(AppKit)
        let native = try NSAttributedString(rendered, including: \.appKit)
        let full = native.string as NSString
        let boldRange = full.range(of: "굵게")
        let underlineRange = full.range(of: "밑줄")
        let linkRange = full.range(of: "링크")
        let boldFont = native.attribute(
            .font,
            at: boldRange.location,
            effectiveRange: nil
        ) as? NSFont
        #expect(
            boldFont.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) }
                == true
        )
        #expect(
            (native.attribute(.underlineStyle, at: underlineRange.location, effectiveRange: nil) as? Int)
                == NSUnderlineStyle.single.rawValue
        )
        #expect(
            (native.attribute(.link, at: linkRange.location, effectiveRange: nil) as? URL)?
                .absoluteString
                == "https://example.com"
        )
        #endif
    }

    @Test("Incomplete Markdown delimiters never appear while typing")
    func incompleteStreamingSyntaxIsHidden() {
        let bold = StreamingMarkdownFormatter.attributed(
            "**아직 번역 중",
            baseSize: 17
        )
        let html = StreamingMarkdownFormatter.attributed(
            "문장 끝의 <u",
            baseSize: 17
        )

        #expect(String(bold.characters) == "아직 번역 중")
        #expect(String(html.characters) == "문장 끝의 ")
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
