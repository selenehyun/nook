import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Natural, context-aware translation via Apple Intelligence's on-device model
/// (Foundation Models). Produces fluent, idiomatic output rather than a literal
/// machine translation. Availability is gated on the device supporting Apple
/// Intelligence and the user having it enabled; callers should fall back to the
/// system Translation overlay when `isAvailable` is false.
public enum NaturalTranslator {
    public struct Unavailable: Error {}

    /// Whether Apple Intelligence translation can run right now.
    public static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26, macOS 26, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
    }

    /// Translates `text` into the given language (e.g. "Korean") naturally,
    /// preserving blank-line paragraph breaks. Throws `Unavailable` when Apple
    /// Intelligence isn't usable.
    public static func translate(_ text: String, into languageName: String) async throws -> String {
        #if canImport(FoundationModels)
        if #available(iOS 26, macOS 26, *), case .available = SystemLanguageModel.default.availability {
            return try await llmTranslate(text, into: languageName)
        }
        #endif
        throw Unavailable()
    }

    #if canImport(FoundationModels)
    @available(iOS 26, macOS 26, *)
    private static func llmTranslate(_ text: String, into languageName: String) async throws -> String {
        let instructions = """
        You are an expert literary translator. Translate the user's text into \(languageName). \
        Produce a natural, fluent, idiomatic translation that reads as if it were originally \
        written in \(languageName) — never a literal, word-for-word rendering. Preserve the \
        meaning, tone, proper nouns, and the blank-line breaks between paragraphs. \
        Output only the translation, with no preamble, notes, or quotation marks.
        """
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(to: text)
        return response.content
    }
    #endif
}
