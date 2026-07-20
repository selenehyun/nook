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
}
