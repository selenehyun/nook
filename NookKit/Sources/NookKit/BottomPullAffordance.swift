import SwiftUI

/// A floating indicator revealed at the bottom of the in-app browser when the
/// user keeps pulling up past the end of the page. It rises in as a glass pill
/// (never pushing the page content) and escalates through two thresholds: pull
/// a little to open the next article (previewing its title), and — hinted by a
/// faint little "✕" that floats above — pull further to close, at which point
/// the ✕ grows in and shoulders the next-article pill out of the way.
///
/// Everything is a continuous function of `pull`, so it tracks the scroll, and a
/// retargeting spring gives it an elastic, tactile feel.
///
/// The thresholds are shared so the browser's release handler decides the same
/// way the indicator reads.
public struct BottomPullAffordance: View {
    /// The primary action: pull a little past this to open the next article.
    public static let nextThreshold: CGFloat = 80
    /// Pull further, past this, to close the browser instead.
    public static let closeThreshold: CGFloat = 130

    private let pull: CGFloat
    private let nextTitle: String?

    public init(pull: CGFloat, nextTitle: String?) {
        self.pull = pull
        self.nextTitle = nextTitle
    }

    private enum Stage: Equatable { case hint, next, close }

    private var stage: Stage {
        if pull >= Self.closeThreshold { return .close }
        if pull >= Self.nextThreshold { return .next }
        return .hint
    }

    /// The pill rises in over the first stretch of the pull, then holds.
    private var reveal: CGFloat { min(1, pull / 64) }

    /// How far the next-article card has faded in (0 below the next threshold, 1
    /// at it), used to cross-fade the hint out and the escalation cards in.
    private var nextIn: CGFloat {
        clamp01((pull - (Self.nextThreshold - 22)) / 22)
    }

    /// Progress from the next threshold (0) to the close threshold (1) — drives
    /// the ✕ growing in and the next card being pushed out.
    private var closeProgress: CGFloat {
        let span = Self.closeThreshold - Self.nextThreshold
        guard span > 0 else { return pull >= Self.closeThreshold ? 1 : 0 }
        return clamp01((pull - Self.nextThreshold) / span)
    }

    /// The ✕ only reads its label once it has grown enough to be the focus.
    private var showCloseLabel: Bool { closeProgress > 0.55 }

    /// A stepped value that climbs as the pull grows through the "hint" zone, so
    /// a very light haptic can tick in response to the scroll before either
    /// threshold is reached. Zero outside the hint stage.
    private var hintTick: Int {
        guard stage == .hint, pull > 6 else { return 0 }
        return Int(pull / 10)
    }

    public var body: some View {
        ZStack {
            // "Keep pulling" — the initial hint, cross-fading out into the next card.
            hintCard
                .opacity(1 - nextIn)

            // Next article — primary once you cross into it, then scaled down,
            // blurred, and shouldered downward as the ✕ takes over.
            nextCard
                .scaleEffect(1 - 0.15 * closeProgress, anchor: .center)
                .offset(y: 48 * closeProgress)
                .blur(radius: 2.5 * closeProgress)
                .opacity(nextIn * (1 - closeProgress))

            // Close — a faint little ✕ floating above, growing and descending
            // into the anchor position as the pull nears the close threshold.
            closeCard
                .scaleEffect(0.56 + 0.44 * closeProgress, anchor: .center)
                .offset(y: -58 * (1 - closeProgress))
                .opacity(nextIn * (0.24 + 0.76 * closeProgress))
        }
        // Overall rise-in from the bottom edge.
        .scaleEffect(0.86 + 0.14 * reveal, anchor: .bottom)
        .offset(y: (1 - reveal) * 44)
        .opacity(pull > 6 ? 1 : 0)
        .padding(.bottom, 22)
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, alignment: .center)
        // A retargeting spring makes the whole thing chase the scroll elastically.
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: pull)
        .animation(.spring(response: 0.34, dampingFraction: 0.68), value: showCloseLabel)
        // iOS haptics. macOS ones are performed in the web view coordinator
        // (ArticleWebView), off the scroll, because SwiftUI's `.sensoryFeedback`
        // doesn't reliably re-fire the trackpad patterns on a repeated pull.
        #if !os(macOS)
        .sensoryFeedback(trigger: stage) { _, newStage in
            switch newStage {
            case .hint: nil
            case .next: .impact(weight: .light)
            case .close: .impact(weight: .medium)
            }
        }
        .sensoryFeedback(trigger: hintTick) { oldTick, newTick in
            newTick > oldTick ? .selection : nil
        }
        #endif
        .allowsHitTesting(false)
    }

    private var hintCard: some View {
        pill {
            Image(systemName: "chevron.up").font(.headline)
            Text("Keep pulling", bundle: .module)
                .font(.subheadline.weight(.semibold))
        }
        .foregroundStyle(.secondary)
    }

    private var nextCard: some View {
        pill {
            Image(systemName: nextTitle == nil ? "checkmark.circle" : "arrow.right")
                .font(.headline)
            Text(nextTitle ?? String(localized: "You're all caught up", bundle: .module))
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 260)
        }
        .foregroundStyle(.tint)
    }

    private var closeCard: some View {
        pill {
            Image(systemName: "xmark").font(.headline)
            if showCloseLabel {
                Text("Release to close", bundle: .module)
                    .font(.subheadline.weight(.semibold))
                    .transition(.opacity)
            }
        }
        .foregroundStyle(.primary)
    }

    private func pill<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 9) { content() }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .modifier(GlassPill())
    }

    private func clamp01(_ value: CGFloat) -> CGFloat { max(0, min(1, value)) }
}

/// A capsule background using the system Liquid Glass material where available,
/// falling back to a regular material on earlier OSes.
private struct GlassPill: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            content.glassEffect(.regular, in: Capsule())
        } else {
            content
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
        }
    }
}
