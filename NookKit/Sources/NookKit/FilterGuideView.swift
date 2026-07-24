import SwiftUI

/// A short, tutorial-style guide that explains how article filters work. Shared
/// by both apps so the copy stays identical; each app shows it once (the first
/// time Filters settings opens) and lets the user replay it from a button. A
/// single scrollable card — not a paged cover — so it renders the same on macOS
/// and iOS. Localised in NookKit (`.module`).
public struct FilterGuideView: View {
    private let onDone: () -> Void

    public init(onDone: @escaping () -> Void) {
        self.onDone = onDone
    }

    public var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header

                    GuideStep(
                        number: 1,
                        systemImage: "character.cursor.ibeam",
                        title: "Write a rule",
                        message: "A filter hides any story that matches it — usually just a word or phrase. Turn on **Regex** on a filter for pattern matching. Matches ignore case unless you turn on **Aa**.",
                        examples: [
                            .init(label: "Text", value: "cryptocurrency"),
                            .init(label: "Regex", value: #"(?i)\bads?\b"#),
                        ]
                    )

                    GuideStep(
                        number: 2,
                        systemImage: "text.magnifyingglass",
                        title: "Choose what it checks",
                        message: "Match against the story's **Title**, its **Summary**, or both — set per filter, so a noisy word can be caught only where it matters.",
                        examples: []
                    )

                    GuideStep(
                        number: 3,
                        systemImage: "line.3.horizontal.decrease.circle",
                        title: "Matches are tidied away",
                        message: "Filtered stories leave every list and unread count — they're never treated as unread. Find them anytime under **Filtered** at the bottom of the sidebar. Nothing is deleted: turn a filter off and its stories come right back.",
                        examples: []
                    )

                    GuideStep(
                        number: 4,
                        systemImage: "arrow.triangle.2.circlepath",
                        title: "The same everywhere",
                        message: "Filters sync through your folder, so the same stories stay hidden on every device.",
                        examples: []
                    )

                    regexTips
                }
                .padding(24)
            }

            Divider()

            Button(action: onDone) {
                Text("Got It", bundle: .module)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(16)
        }
        .frame(maxWidth: 460)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "line.3.horizontal.decrease.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(Color.accentColor)
                .symbolRenderingMode(.hierarchical)
                .accessibilityHidden(true)
            Text("Filter out stories you don't want", bundle: .module)
                .font(.title2.weight(.bold))
                .fixedSize(horizontal: false, vertical: true)
            Text("Filters quietly hide stories that match rules you set — so your lists stay about what you actually want to read.", bundle: .module)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var regexTips: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Regex tips", bundle: .module)
                .font(.subheadline.weight(.semibold))
            RegexTip(pattern: "a|b", explanation: "matches a or b")
            RegexTip(pattern: #"\bword\b"#, explanation: "whole word only")
            RegexTip(pattern: "(?i)", explanation: "ignore case (prefix)")
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// One numbered step: an icon, a title, a markdown message, and optional example
/// chips (e.g. a sample plain-text word and a sample regex).
private struct GuideStep: View {
    struct Example: Identifiable {
        let label: LocalizedStringKey?
        let value: String
        var id: String { value }
    }

    let number: Int
    let systemImage: String
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    let examples: [Example]

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 30, height: 30)
                .background(Color.accentColor.opacity(0.12), in: Circle())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 8) {
                Text(title, bundle: .module)
                    .font(.headline)
                Text(message, bundle: .module)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !examples.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(examples) { example in
                            HStack(spacing: 6) {
                                if let label = example.label {
                                    Text(label, bundle: .module)
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                }
                                Text(example.value)
                                    .font(.caption.monospaced())
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.secondary.opacity(0.10), in: Capsule())
                        }
                    }
                }
            }
        }
    }
}

private struct RegexTip: View {
    let pattern: String
    let explanation: LocalizedStringKey

    var body: some View {
        HStack(spacing: 10) {
            Text(pattern)
                .font(.caption.monospaced())
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            Text(explanation, bundle: .module)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
