import SwiftUI

/// A floating indicator revealed at the bottom of the in-app browser when the
/// user keeps pulling up past the end of the page. It rises in as a glass pill
/// (never pushing the page content) and its label/icon escalate through two
/// thresholds: pull a little to open the next article (previewing its title),
/// pull further to close.
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

    /// A stepped value that climbs as the pull grows through the "hint" zone, so
    /// a very light haptic can tick in response to the scroll before either
    /// threshold is reached. Zero outside the hint stage, so the ticking stops
    /// once the stronger stage-crossing feedback takes over.
    private var hintTick: Int {
        guard stage == .hint, pull > 6 else { return 0 }
        return Int(pull / 10)
    }

    public var body: some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.headline)
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, value: stage)
            Text(label)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 260)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .modifier(GlassPill())
        .scaleEffect(0.86 + 0.14 * reveal, anchor: .bottom)
        .opacity(reveal)
        .offset(y: (1 - reveal) * 44)
        .padding(.bottom, 22)
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, alignment: .center)
        .animation(.snappy(duration: 0.22), value: stage)
        // Native haptic tick each time the pull crosses into a new stage. iOS
        // uses impact weights; macOS's Taptic Engine only supports the
        // alignment/level-change patterns (and only on Force Touch trackpads),
        // so map to those there. A no-op on hardware without a haptic engine.
        // iOS haptics. macOS ones are performed in the web view coordinator
        // (ArticleWebView), off the scroll, because SwiftUI's `.sensoryFeedback`
        // doesn't reliably re-fire the trackpad patterns on a repeated pull.
        #if !os(macOS)
        // A firm tick each time the pull crosses into a new stage.
        .sensoryFeedback(trigger: stage) { _, newStage in
            switch newStage {
            case .hint: nil
            case .next: .impact(weight: .light)
            case .close: .impact(weight: .medium)
            }
        }
        // A very light ratchet that follows the scroll while "Keep pulling"
        // shows, only as the pull grows (never on release).
        .sensoryFeedback(trigger: hintTick) { oldTick, newTick in
            newTick > oldTick ? .selection : nil
        }
        #endif
        .allowsHitTesting(false)
    }

    private var foreground: AnyShapeStyle {
        switch stage {
        case .hint: AnyShapeStyle(.secondary)
        case .next: AnyShapeStyle(.tint)
        case .close: AnyShapeStyle(.primary)
        }
    }

    private var icon: String {
        switch stage {
        case .hint: "chevron.up"
        case .next: nextTitle == nil ? "checkmark.circle" : "arrow.right"
        case .close: "xmark"
        }
    }

    private var label: String {
        switch stage {
        case .hint:
            String(localized: "Keep pulling", bundle: .module)
        case .next:
            nextTitle ?? String(localized: "You're all caught up", bundle: .module)
        case .close:
            String(localized: "Release to close", bundle: .module)
        }
    }
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
