import AppKit
import Testing
@testable import NookKit

@Suite("Native article layout")
struct HTMLContentLayoutTests {
    @Test("Adjacent block margins collapse according to document structure")
    func semanticBlockSpacing() {
        let paragraph = HTMLContentBlock.text("Body")
        let heading = HTMLContentBlock.heading(level: 2, html: "Heading")
        let list = HTMLContentBlock.list(ordered: false, items: [[paragraph]])

        #expect(HTMLBlockSpacing.gap(from: nil, to: paragraph) == 0)
        #expect(HTMLBlockSpacing.gap(from: paragraph, to: paragraph) == 10)
        #expect(HTMLBlockSpacing.gap(from: paragraph, to: heading) == 26)
        #expect(HTMLBlockSpacing.gap(from: heading, to: paragraph) == 8)
        #expect(HTMLBlockSpacing.gap(from: paragraph, to: list) == 14)
        #expect(HTMLBlockSpacing.gap(from: paragraph, to: list, compact: true) == 9.1)
    }

    @Test("HTML line breaks remain softer than paragraph breaks")
    func preservesSoftLineBreaks() {
        let prepared = HTMLTextFlow.preparedHTML("First<br class=\"soft\">Second")

        #expect(prepared == "First\u{2028}Second")
    }

    @Test("Imported text drops phantom edges and normalizes paragraph metrics")
    func normalizesImportedParagraphs() {
        let text = NSMutableAttributedString(string: "\nOne\n\nTwo\n")
        let source = NSMutableParagraphStyle()
        source.paragraphSpacingBefore = 18
        source.paragraphSpacing = 24
        source.lineSpacing = 7
        source.minimumLineHeight = 30
        source.maximumLineHeight = 34
        text.addAttribute(.paragraphStyle, value: source, range: NSRange(location: 0, length: text.length))

        HTMLTextFlow.normalize(text, baseSize: 17)

        #expect(text.string == "One\nTwo")
        let style = text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        #expect(style?.paragraphSpacingBefore == 0)
        #expect(style?.paragraphSpacing == 10.2)
        #expect(style?.lineSpacing == 0)
        #expect(style?.minimumLineHeight == 0)
        #expect(style?.maximumLineHeight == 0)
        let finalStyle = text.attribute(.paragraphStyle, at: text.length - 1, effectiveRange: nil) as? NSParagraphStyle
        #expect(finalStyle?.paragraphSpacing == 0)
    }
}
