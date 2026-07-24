import Testing
@testable import NookKit

@Suite("Natural translator helpers")
struct NaturalTranslatorTests {
    @Test("A chatty preamble before a colon is stripped")
    func stripsPreamble() {
        let leaked = "물론입니다. 다음은 요청하신 내용을 한국어로 번역한 것입니다: 그리고 지금까지 제가 알 수 있는 한, 이것은 사실입니다."
        #expect(NaturalTranslator.stripTranslationPreamble(leaked) == "그리고 지금까지 제가 알 수 있는 한, 이것은 사실입니다.")

        let english = "Sure, here is the translation: 안녕하세요 여러분."
        #expect(NaturalTranslator.stripTranslationPreamble(english) == "안녕하세요 여러분.")
    }

    @Test("Keep-verbatim tokens are extracted; ordinary words are not")
    func extractsKeepTokens() {
        let text = "Outside of OpenAI, Gwern discussed ChatGPT and GPT-4 and the role of the GPU in scaling AI. But most words are ordinary."
        let tokens = Set(NaturalTranslator.heuristicKeepTokens(text))
        // Internal-capital names, acronyms, and alphanumerics-with-digit are kept.
        #expect(tokens.contains("OpenAI"))
        #expect(tokens.contains("ChatGPT"))
        #expect(tokens.contains("GPT-4"))
        #expect(tokens.contains("GPU"))
        #expect(tokens.contains("AI"))
        // Ordinary capitalized/lowercase words are not.
        #expect(!tokens.contains("Outside"))
        #expect(!tokens.contains("But"))
        #expect(!tokens.contains("ordinary"))
        #expect(!tokens.contains("Gwern"))   // plain name — left to the model pass, not the heuristic
    }

    @Test("Untranslated output is detected by target script")
    func detectsUntranslatedByScript() {
        let english = "The anonymous blogger Gwern recently completed a very long post about neural networks."
        // Echoed English while translating to Korean: almost no Hangul → untranslated.
        #expect(NaturalTranslator.isUntranslated(source: english, output: english, languageName: "Korean"))
        // A real Korean translation (with some kept English names) is accepted.
        let korean = "익명의 블로거 Gwern은 최근 신경망에 대한 아주 긴 글을 완성했습니다."
        #expect(!NaturalTranslator.isUntranslated(source: english, output: korean, languageName: "Korean"))
    }

    @Test("A runaway repetition loop is detected")
    func detectsRunaway() {
        // A single word repeated forever.
        #expect(NaturalTranslator.looksRunaway(String(repeating: "메아리 ", count: 20)))
        // A single character repeated.
        #expect(NaturalTranslator.looksRunaway("정상적인 시작 " + String(repeating: "가", count: 40)))
    }

    @Test("Ordinary text is not flagged as runaway")
    func normalTextNotRunaway() {
        #expect(!NaturalTranslator.looksRunaway("이것은 완전히 평범한 번역된 문장이며 반복이 없습니다."))
        #expect(!NaturalTranslator.looksRunaway("짧은 글"))
        // A couple of legitimate repeats (e.g. "매우 매우 좋다") must not trip it.
        #expect(!NaturalTranslator.looksRunaway("그것은 매우 매우 좋은 결과였습니다."))
    }

    @Test("Ordinary prose with a colon is left intact")
    func keepsRealColon() {
        let real = "그가 말했다: 나는 준비되었다."
        #expect(NaturalTranslator.stripTranslationPreamble(real) == real)

        let noColon = "이것은 그냥 번역된 문장입니다."
        #expect(NaturalTranslator.stripTranslationPreamble(noColon) == noColon)

        // A preamble-looking lead but nothing after the colon: keep the original.
        let empty = "다음은 번역입니다:"
        #expect(NaturalTranslator.stripTranslationPreamble(empty) == empty)
    }

    @Test("Category classification requires a primary subject, not incidental overlap")
    func categoryClassificationIsConservative() {
        let instructions = NaturalTranslator.categoryClassificationInstructions(
            for: ["정치", "IT"]
        )

        #expect(instructions.contains("PRIMARY SUBJECT"))
        #expect(instructions.contains("Prefer the single best category"))
        #expect(instructions.contains("software PR"))
        #expect(instructions.contains("not evidence of politics"))
        #expect(instructions.contains("government, elections, parties"))
        #expect(instructions.contains("- 정치\n- IT"))
    }

    @Test("Category response parsing accepts only exact listed category lines")
    func parsesCategoryClassificationResponse() {
        let parsed = NaturalTranslator.parseCategoryClassification(
            """
            - IT
            Technology
            설명: 정치도 관련 있음
            """,
            allowedNames: ["정치", "IT", "AI, ML"]
        )

        #expect(parsed == ["IT"])
    }
}
