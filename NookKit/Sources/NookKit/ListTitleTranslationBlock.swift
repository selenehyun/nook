import SwiftUI

/// Shared macOS/iOS presentation for a translated article-list title. Keeping the
/// observation and styling in one leaf view ensures a progress snapshot
/// invalidates only this row, and both platforms follow the same reveal contract.
public struct ListTitleTranslationBlock: View {
    private let title: String
    private let box: ListTitleTranslator.StateBox
    private let translator: ListTitleTranslator
    private let surroundingLayoutRevision: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        title: String,
        box: ListTitleTranslator.StateBox,
        translator: ListTitleTranslator = .shared,
        surroundingLayoutRevision: Int = 0
    ) {
        self.title = title
        self.box = box
        self.translator = translator
        self.surroundingLayoutRevision = surroundingLayoutRevision
    }

    public var body: some View {
        let presentation = resolvedPresentation
        let text = presentation?.text ?? ""
        let streaming = presentation?.streaming ?? false
        let provider = presentation?.provider ?? .appleIntelligence
        let usesGemini = provider == .gemini

        HStack(alignment: .top, spacing: 5) {
            Image(systemName: usesGemini ? "sparkles" : "apple.intelligence")
                .symbolEffect(
                    .pulse,
                    options: .repeating,
                    isActive: streaming && !reduceMotion
                )
                .accessibilityLabel(
                    Text(
                        String(
                            localized: usesGemini
                                ? "Translated by Gemini"
                                : "Translated by Apple Intelligence",
                            bundle: .main
                        )
                    )
                )

            if text.isEmpty {
                Text(String(localized: "Translating…", bundle: .main))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else {
                Text(text)
                    .fontWeight(.medium)
                    .lineLimit(2)
            }
        }
        .font(.callout)
        .foregroundStyle(Color.accentColor)
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.accentColor.opacity(0.10),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .padding(.top, 4)
        // Text snapshots must not implicitly animate their intrinsic size. The
        // outer reveal owns the single intentional row expansion.
        .transaction { transaction in
            transaction.animation = nil
        }
        .expandReveal(
            isVisible: presentation != nil,
            animateAppearance: streaming && !reduceMotion,
            // Stream snapshots can change the block from one line to two, while
            // category badges can independently change the same outer row.
            // Feed both into the targeted macOS row-height invalidation.
            layoutRevision: text.hashValue ^ surroundingLayoutRevision
        )
    }

    private var resolvedPresentation: (
        text: String,
        streaming: Bool,
        provider: TranslationProvider
    )? {
        switch translator.state(for: box, title: title) {
        case .translating(let partial, let provider):
            return (partial, true, provider)
        case .translated(let final, let provider):
            return (final, false, provider)
        case nil:
            return nil
        }
    }
}
