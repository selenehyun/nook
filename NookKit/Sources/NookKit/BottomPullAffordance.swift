import SwiftUI

/// A floating indicator revealed at the bottom of the in-app browser when the
/// user keeps pulling up past the end of the page. It rises in as a glass pill
/// (never pushing the page content) and escalates through two thresholds.
///
/// In the next-article stage, over-pulling doesn't smoothly morph into close —
/// instead the pill *resists*, nudging against the scroll with diminishing give
/// while a faint little "✕" hint waits above. Only when the pull crosses the
/// close threshold does it snap — with a haptic — to the close indicator, the ✕
/// dropping in from above and shouldering the next-article pill out.
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
    /// at it), used to cross-fade the hint out.
    private var nextIn: CGFloat {
        clamp01((pull - (Self.nextThreshold - 22)) / 22)
    }

    /// How far into the next→close over-pull the scroll is (0 at the next
    /// threshold, 1 at the close threshold). Drives the *resistance* nudge only —
    /// not a morph — so the ✕ never tracks the scroll into place.
    private var overPull: CGFloat {
        let span = Self.closeThreshold - Self.nextThreshold
        guard span > 0 else { return 0 }
        return clamp01((pull - Self.nextThreshold) / span)
    }

    /// A stepped value that climbs as the pull grows through the "hint" zone, so
    /// a very light haptic can tick in response to the scroll before either
    /// threshold is reached. Zero outside the hint stage.
    private var hintTick: Int {
        guard stage == .hint, pull > 6 else { return 0 }
        return Int(pull / 10)
    }

    public var body: some View {
        ZStack {
            // "Keep pulling" hint, cross-fading out as the next card takes over.
            hintCard
                .opacity(1 - nextIn)

            // A faint little ✕ waiting above during the next stage. It stays a
            // hint — barely brightening with the over-pull, never descending.
            closeHint
                .scaleEffect(0.7)
                .offset(y: -52)
                .opacity(stage == .next ? 0.14 + 0.22 * overPull : 0)

            // The active pill: next OR close, swapped discretely at the
            // threshold. Explicit vertical offsets keep the motion straight down
            // / down-from-above (a plain `.move(edge:)` drifts diagonally as the
            // pills' widths differ).
            if stage == .close {
                closeCard
                    // Drops in from above, where the ✕ hint was.
                    .transition(.offset(y: -46).combined(with: .opacity))
            } else {
                nextCard
                    // Resist the over-pull: a small downward nudge and slight
                    // compression that plateau, foreshadowing the pill being
                    // pushed straight down and out when close takes over.
                    .offset(y: 14 * overPull)
                    .scaleEffect(1 - 0.04 * overPull, anchor: .center)
                    .opacity(nextIn)
                    // Slides straight down and out.
                    .transition(.offset(y: 46).combined(with: .opacity))
            }
        }
        // Overall rise-in from the bottom edge.
        .scaleEffect(0.86 + 0.14 * reveal, anchor: .bottom)
        .offset(y: (1 - reveal) * 44)
        .opacity(pull > 6 ? 1 : 0)
        .padding(.bottom, 22)
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, alignment: .center)
        // The resistance nudge tracks the scroll with a light elastic spring…
        .animation(.spring(response: 0.24, dampingFraction: 0.72), value: pull)
        // …while crossing a threshold snaps with a bouncier one.
        .animation(.spring(response: 0.34, dampingFraction: 0.62), value: stage)
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
            Text("Release to close", bundle: .module)
                .font(.subheadline.weight(.semibold))
        }
        .foregroundStyle(.primary)
    }

    /// The faint standalone ✕ badge shown above during the next stage.
    private var closeHint: some View {
        pill {
            Image(systemName: "xmark").font(.subheadline.weight(.bold))
        }
        .foregroundStyle(.secondary)
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
