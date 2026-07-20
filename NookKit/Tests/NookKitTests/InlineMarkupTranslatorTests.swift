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

    @Test("A multi-paragraph block splits into per-paragraph segments")
    func paragraphSegments() {
        let segments = Engine.segments("<p>First</p><p>Second</p>")
        #expect(segments.count == 2)
        #expect(segments.map(\.translatable) == [true, true])
        #expect(segments[0].open == "<p>" && segments[0].inner == "First" && segments[0].close == "</p>")
        #expect(segments[1].inner == "Second")
    }

    @Test("List wrappers pass through untranslated; items are segments")
    func listSegments() {
        let segments = Engine.segments("<ul><li>one</li><li>two</li></ul>")
        let translatable = segments.filter(\.translatable)
        #expect(translatable.map(\.inner) == ["one", "two"])
        // The <ul>/</ul> wrappers are tag-only gaps, preserved verbatim.
        #expect(segments.contains { !$0.translatable && $0.raw.contains("<ul>") })
    }

    @Test("A fragment with no paragraph structure is one segment")
    func looseTextSegment() {
        let segments = Engine.segments("just some text")
        #expect(segments == [Engine.Segment(raw: "just some text", translatable: true, open: "", inner: "just some text", close: "")])
    }

    @Test("A chunk localizes to self-contained 0-based markers and rebuilds alone")
    func localizesChunk() {
        let (_, entries) = Engine.markify("<a href=\"/1\">one</a> and <em>two</em> and <a href=\"/3\">three</a>")
        // entries: 0 = a(/1), 1 = em, 2 = a(/3). Second chunk holds globals 1 and 2.
        let chunk = "\u{27E6}1\u{27E7}two\u{27E6}/1\u{27E7} and \u{27E6}2\u{27E7}three\u{27E6}/2\u{27E7}"
        let (local, localEntries) = Engine.localize(chunk, entries: entries)
        #expect(local == "\u{27E6}0\u{27E7}two\u{27E6}/0\u{27E7} and \u{27E6}1\u{27E7}three\u{27E6}/1\u{27E7}")
        #expect(localEntries == [entries[1], entries[2]])
        // The localized chunk rebuilds independently, restoring the right tags.
        let translated = "\u{27E6}0\u{27E7}둘\u{27E6}/0\u{27E7} 그리고 \u{27E6}1\u{27E7}셋\u{27E6}/1\u{27E7}"
        #expect(Engine.rebuild(translated, entries: localEntries) == "<em>둘</em> 그리고 <a href=\"/3\">셋</a>")
    }

    @Test("A marker-free chunk localizes to itself with no entries")
    func localizesPlainChunk() {
        let (local, localEntries) = Engine.localize("just some words", entries: [])
        #expect(local == "just some words")
        #expect(localEntries.isEmpty)
    }

    @Test("Corrupted markers are stripped, not leaked into the text")
    func stripsCorruptedMarkers() {
        // The model mangled a footnote marker into "⟦5⟦3" at the end of a sentence.
        let mangled = "…를 얻는 것'을 의미합니다\u{27E6}5\u{27E6}3."
        #expect(Engine.stripMarkers(mangled) == "…를 얻는 것'을 의미합니다.")
        // A lone opener or closer is removed too.
        #expect(Engine.stripMarkers("좋아요\u{27E6}") == "좋아요")
        #expect(Engine.stripMarkers("좋아요\u{27E7}") == "좋아요")
        // Well-formed markers still strip exactly as before.
        #expect(Engine.stripMarkers("\u{27E6}0\u{27E7}가\u{27E6}/0\u{27E7}") == "가")
    }

    @Test("A short template is a single chunk left unchanged")
    func chunkShort() {
        let t = "Hello world. This stays whole."
        #expect(Engine.chunk(t, maxChars: 600) == [t])
    }

    @Test("A long template splits at sentence boundaries, losslessly")
    func chunkLongSplits() {
        let t = "First sentence here. Second sentence here. Third sentence here. Fourth here."
        let chunks = Engine.chunk(t, maxChars: 30)
        #expect(chunks.count > 1)
        // Cuts only partition the string; nothing is dropped or duplicated.
        #expect(chunks.joined() == t)
        // Every chunk but the last ends at a sentence boundary.
        for c in chunks.dropLast() {
            #expect(c.trimmingCharacters(in: .whitespaces).hasSuffix("."))
        }
        // No chunk exceeds a reasonable multiple of the budget.
        #expect(chunks.allSatisfy { $0.count <= 60 })
    }

    @Test("Chunks never split an inline marker pair")
    func chunkKeepsMarkersBalanced() {
        let t = "See \u{27E6}0\u{27E7}one\u{27E6}/0\u{27E7} right now. See \u{27E6}1\u{27E7}two\u{27E6}/1\u{27E7} much later."
        let chunks = Engine.chunk(t, maxChars: 25)
        #expect(chunks.joined() == t)
        for c in chunks {
            let balance = markerBalance(c)
            #expect(balance.open == balance.close)
        }
    }

    @Test("A single over-long sentence falls back to word breaks")
    func chunkOverLongSentence() {
        let t = "one two three four five six seven eight nine ten eleven twelve thirteen"
        let chunks = Engine.chunk(t, maxChars: 20)
        #expect(chunks.count > 1)
        #expect(chunks.joined() == t)
    }

    /// Counts opening vs closing inline markers so a test can assert a chunk's
    /// markers are balanced (no pair straddles a cut).
    private func markerBalance(_ s: String) -> (open: Int, close: Int) {
        var open = 0, close = 0
        let chars = Array(s)
        for (i, ch) in chars.enumerated() where ch == "\u{27E6}" {
            let next = i + 1 < chars.count ? chars[i + 1] : " "
            if next == "/" { close += 1 }
            else if next == "=" { /* opaque void marker: self-balanced */ }
            else if next.isNumber { open += 1 }
        }
        return (open, close)
    }
}
