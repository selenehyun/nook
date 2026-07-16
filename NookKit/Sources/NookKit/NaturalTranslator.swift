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

    /// One paragraph's translation plus a refreshed running summary of the
    /// article so far, so the caller can feed context forward to the next block.
    public struct BlockResult: Sendable {
        public let translation: String
        public let context: String
    }

    /// Translates a single block, preserving any `⟦Tn⟧…⟦/Tn⟧` inline markers, and
    /// returns an updated running-context summary. `context` is the summary from
    /// the previous blocks (empty for the first). Lets a page be translated
    /// paragraph-by-paragraph, in order, while staying contextually consistent.
    public static func translateBlock(
        _ text: String, into languageName: String, context: String
    ) async throws -> BlockResult {
        #if canImport(FoundationModels)
        if #available(iOS 26, macOS 26, *), case .available = SystemLanguageModel.default.availability {
            return try await llmTranslateBlock(text, into: languageName, context: context)
        }
        #endif
        throw Unavailable()
    }

    #if canImport(FoundationModels)
    @available(iOS 26, macOS 26, *)
    @Generable
    fileprivate struct BlockTranslation {
        @Guide(description: "The natural, idiomatic translation of the paragraph. Every marker of the form ⟦Tn⟧ and ⟦/Tn⟧ from the source MUST be kept verbatim, wrapping the same words they wrapped in the source. Do not add, remove, renumber, or translate the markers.")
        var translation: String
        @Guide(description: "An updated running summary (English, at most 50 words) of what the article is about so far, so later paragraphs stay consistent in terminology and tone.")
        var runningContext: String
    }

    @available(iOS 26, macOS 26, *)
    private static func llmTranslateBlock(
        _ text: String, into languageName: String, context: String
    ) async throws -> BlockResult {
        let instructions = """
        You are an expert literary translator. Translate each paragraph the user \
        sends into \(languageName): natural, fluent, idiomatic — never literal or \
        word-for-word — preserving meaning, tone, and proper nouns. The source may \
        contain inline markers like ⟦T0⟧…⟦/T0⟧ marking links or emphasis; keep every \
        marker exactly, around the translation of the same words, and never translate \
        or renumber them. Also maintain a short running summary of the article for \
        your own consistency across paragraphs.
        """
        let session = LanguageModelSession(instructions: instructions)
        let prompt = """
        Article context so far (for consistency only — do not translate or repeat it):
        \(context.isEmpty ? "(none yet)" : context)

        Paragraph to translate:
        \(text)
        """
        let response = try await session.respond(to: prompt, generating: BlockTranslation.self)
        return BlockResult(translation: response.content.translation, context: response.content.runningContext)
    }
    #endif

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
