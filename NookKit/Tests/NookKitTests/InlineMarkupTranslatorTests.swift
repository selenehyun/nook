import Testing
@testable import NookKit

@Suite("Inline markup translation")
struct InlineMarkupTranslatorTests {
    private typealias Engine = InlineMarkupTranslator

    @Test("Plain text round-trips unchanged")
    func plainText() {
        let (template, entries) = Engine.markify("Hello world")
        #expect(template == "Hello world")
        #expect(entries.isEmpty)
        #expect(Engine.rebuild(template, entries: entries) == "Hello world")
    }

    @Test("A link becomes a marker and is restored with its attributes")
    func linkPreserved() {
        let (template, entries) = Engine.markify("Read <a href=\"/x\">more</a> now")
        #expect(template == "Read \u{27E6}0\u{27E7}more\u{27E6}/0\u{27E7} now")
        #expect(entries == [Engine.Entry(raw: "<a href=\"/x\">", name: "a", opaque: false)])

        // Simulate a translation that kept the markers around the moved words.
        let translated = "\u{27E6}0\u{27E7}더\u{27E6}/0\u{27E7} 지금 읽기"
        #expect(Engine.rebuild(translated, entries: entries) == "<a href=\"/x\">더</a> 지금 읽기")
    }

    @Test("Nested inline markup is preserved")
    func nestedPreserved() {
        let (template, entries) = Engine.markify("<a href=\"/x\"><strong>bold</strong></a>")
        #expect(template == "\u{27E6}0\u{27E7}\u{27E6}1\u{27E7}bold\u{27E6}/1\u{27E7}\u{27E6}/0\u{27E7}")
        let translated = "\u{27E6}0\u{27E7}\u{27E6}1\u{27E7}굵게\u{27E6}/1\u{27E7}\u{27E6}/0\u{27E7}"
        #expect(Engine.rebuild(translated, entries: entries) == "<a href=\"/x\"><strong>굵게</strong></a>")
    }

    @Test("Void tags are preserved verbatim and never translated into")
    func voidPreserved() {
        let (template, entries) = Engine.markify("line<br>break")
        #expect(template == "line\u{27E6}=0\u{27E7}break")
        #expect(entries == [Engine.Entry(raw: "<br>", name: "br", opaque: true)])
        #expect(Engine.rebuild("줄\u{27E6}=0\u{27E7}바꿈", entries: entries) == "줄<br>바꿈")
    }

    @Test("A dropped marker fails validation so the caller can fall back")
    func droppedMarkerRejected() {
        let (_, entries) = Engine.markify("Read <a href=\"/x\">more</a>")
        // The model dropped the markers entirely.
        #expect(Engine.rebuild("더 읽기", entries: entries) == nil)
        // …and the fallback yields safe plain text.
        #expect(Engine.plainFallback("더 읽기") == "더 읽기")
    }

    @Test("Mis-nested or duplicated markers are rejected")
    func malformedRejected() {
        let (_, entries) = Engine.markify("<em>a</em><strong>b</strong>")
        // Swapped closes (mis-nested).
        #expect(Engine.rebuild("\u{27E6}0\u{27E7}\u{27E6}1\u{27E7}가나\u{27E6}/0\u{27E7}\u{27E6}/1\u{27E7}", entries: entries) == nil)
    }

    @Test("Translated text is HTML-escaped on rebuild")
    func escapesText() {
        let (_, entries) = Engine.markify("<em>x</em>")
        // Text around a valid marker containing angle brackets must be escaped.
        let out = Engine.rebuild("1 < 2 \u{27E6}0\u{27E7}참\u{27E6}/0\u{27E7}", entries: entries)
        #expect(out == "1 &lt; 2 <em>참</em>")
    }

    @Test("Entities in the source are decoded for the model input")
    func decodesEntities() {
        let (template, _) = Engine.markify("a &amp; b &lt; c")
        #expect(template == "a & b < c")
    }
}
